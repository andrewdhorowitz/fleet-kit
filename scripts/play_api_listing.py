#!/usr/bin/env python3
"""Play API store-listing title fix (read / write modes) for the play-api SA.

Built for the Routines rename (Nov 6, 2026): the Play Console listing for
com.andrewdhorowitz.routinesandstreaks still carries the old title
"Routines and Streaks" after the product was renamed "Routines Clarity".

Modes (LISTING_MODE env):
  read  — insert a disposable edit, GET edits.listings.list (all
          languages), delete the edit. Nothing is ever committed.
  write — insert an edit, GET listings; for each language whose title is
          EXACTLY LISTING_OLD_TITLE, PUT the full listing back with ONLY
          the title replaced by LISTING_NEW_TITLE (edits.listings.update
          replaces the whole resource, so every other field is resent
          verbatim); re-read inside the edit; commit; then verify with a
          FRESH edit's listings read and an in-script check that every
          non-title field is unchanged. If no listing matches the old
          title (and none already carries the new one), STOP without
          committing anything.

Findings are written as JSON under play-listing/ in the repo checkout
(results-<short>.json) because job logs / step summaries are not readable
through the fleet PAT. The SA key is never printed; output carries the SA
client_email only, like the other play-api scripts.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from play_api_probe import get_access_token, API

PACKAGE = os.environ["LISTING_PACKAGE"]
MODE = os.environ.get("LISTING_MODE", "read")
OLD_TITLE = os.environ.get("LISTING_OLD_TITLE", "Routines and Streaks")
NEW_TITLE = os.environ.get("LISTING_NEW_TITLE", "Routines Clarity")
OUT_DIR = os.environ.get("LISTING_OUT_DIR", "play-listing")
SHORT = PACKAGE.rsplit(".", 1)[-1]


def call2(method, url, token, body=None):
    headers = {"Authorization": "Bearer " + token}
    data = body
    if body is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", "replace")
            if not raw.strip():
                return resp.status, {}
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, {"raw": raw[:300]}
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace")[:500]
        return err.code, {"error_body": detail}


def open_edit(tok, result, stage_prefix):
    status, edit = call2("POST", API + "/" + PACKAGE + "/edits", tok, b"{}")
    result[stage_prefix + "_edits_insert_http"] = status
    if status != 200:
        result["errors"].append(stage_prefix + " edits.insert: " + json.dumps(edit)[:300])
        return None
    return edit["id"]


def read_listings(tok, edit_id):
    base = API + "/" + PACKAGE + "/edits/" + edit_id
    s, res = call2("GET", base + "/listings", tok)
    if s != 200:
        return s, None, res
    return s, res.get("listings") or [], res


def non_title_fields(listing):
    return {k: v for k, v in listing.items() if k != "title"}


def do_read(tok, result):
    edit_id = open_edit(tok, result, "read")
    if edit_id is None:
        return False
    base = API + "/" + PACKAGE + "/edits/" + edit_id
    try:
        s, listings, raw = read_listings(tok, edit_id)
        result["listings_list_http"] = s
        if s != 200:
            result["errors"].append("listings.list: " + json.dumps(raw)[:300])
            return False
        result["listings"] = listings
        return True
    finally:
        s, _ = call2("DELETE", base, tok)
        result["edits_delete_http"] = s


def do_write(tok, result):
    edit_id = open_edit(tok, result, "write")
    if edit_id is None:
        return False
    base = API + "/" + PACKAGE + "/edits/" + edit_id
    committed = False
    try:
        s, listings, raw = read_listings(tok, edit_id)
        result["listings_list_http"] = s
        if s != 200:
            result["errors"].append("listings.list: " + json.dumps(raw)[:300])
            return False
        result["listings_before"] = listings
        matching = [l for l in listings if l.get("title") == OLD_TITLE]
        already = [l for l in listings if l.get("title") == NEW_TITLE]
        result["matching_languages"] = [l.get("language") for l in matching]
        result["already_new_languages"] = [l.get("language") for l in already]
        result["other_titles"] = [
            {"language": l.get("language"), "title": l.get("title")}
            for l in listings
            if l.get("title") not in (OLD_TITLE, NEW_TITLE)
        ]
        if not matching:
            result["stopped"] = (
                "no listing carries the exact old title and none already "
                "carries the new title — nothing written"
                if not already else
                "old title absent; new title already present — nothing to write")
            return bool(already)
        updates = []
        for listing in matching:
            lang = listing.get("language")
            body_obj = dict(listing)
            body_obj["title"] = NEW_TITLE
            body = json.dumps(body_obj).encode()
            s, res = call2("PUT", base + "/listings/" + lang, tok, body)
            updates.append({"language": lang, "listings_update_http": s})
            if s != 200:
                result["errors"].append(
                    "listings.update[" + str(lang) + "]: " + json.dumps(res)[:300])
                result["updates"] = updates
                return False
        result["updates"] = updates
        s, staged, raw = read_listings(tok, edit_id)
        result["staged_listings_list_http"] = s
        if s != 200:
            result["errors"].append("staged listings.list: " + json.dumps(raw)[:300])
            return False
        result["listings_staged"] = staged
        staged_titles = {l.get("language"): l.get("title") for l in staged}
        bad = [lang for lang in result["matching_languages"]
               if staged_titles.get(lang) != NEW_TITLE]
        if bad:
            result["errors"].append("staged titles wrong for: " + ",".join(bad))
            return False
        s, res = call2("POST", base + ":commit", tok, b"")
        result["edits_commit_http"] = s
        if s != 200:
            result["errors"].append("edits.commit: " + json.dumps(res)[:300])
            return False
        committed = True
    finally:
        if not committed:
            s, _ = call2("DELETE", base, tok)
            result["edits_delete_http"] = s
    # Verify with a fresh edit.
    edit2 = open_edit(tok, result, "verify")
    if edit2 is None:
        return False
    base2 = API + "/" + PACKAGE + "/edits/" + edit2
    try:
        s, after, raw = read_listings(tok, edit2)
        result["verify_listings_list_http"] = s
        if s != 200:
            result["errors"].append("verify listings.list: " + json.dumps(raw)[:300])
            return False
        result["listings_after"] = after
    finally:
        s, _ = call2("DELETE", base2, tok)
        result["verify_edits_delete_http"] = s
    before_by_lang = {l.get("language"): l for l in result["listings_before"]}
    after_by_lang = {l.get("language"): l for l in after}
    preserved = True
    titles_ok = True
    checks = {}
    for lang, before in before_by_lang.items():
        aft = after_by_lang.get(lang)
        if aft is None:
            preserved = False
            checks[lang] = "missing after commit"
            continue
        fields_same = non_title_fields(before) == non_title_fields(aft)
        expected_title = NEW_TITLE if before.get("title") == OLD_TITLE else before.get("title")
        title_ok = aft.get("title") == expected_title
        checks[lang] = {"non_title_fields_preserved": fields_same, "title_ok": title_ok}
        preserved = preserved and fields_same
        titles_ok = titles_ok and title_ok
    result["verify_checks"] = checks
    result["other_fields_preserved"] = preserved
    result["titles_ok"] = titles_ok
    return preserved and titles_ok


def main() -> int:
    sa = json.loads(os.environ["PLAY_API_SERVICE_ACCOUNT_JSON"])
    result = {
        "package": PACKAGE,
        "mode": MODE,
        "old_title": OLD_TITLE,
        "new_title": NEW_TITLE,
        "errors": [],
    }
    try:
        tok = get_access_token(sa)
    except Exception as exc:
        print("stage FAILED: oauth token — " + type(exc).__name__)
        result["errors"].append("oauth token: " + type(exc).__name__)
        ok = False
        tok = None
    if tok is not None:
        ok = do_read(tok, result) if MODE == "read" else do_write(tok, result)
    result["generated_at"] = datetime.now(timezone.utc).isoformat()
    result["service_account"] = sa.get("client_email")
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "results-" + SHORT + ".json")
    with open(path, "w") as fh:
        json.dump(result, fh, indent=1, sort_keys=True)
    if MODE == "read":
        desc = "; ".join(
            str(l.get("language")) + "=" + repr(l.get("title"))
            for l in result.get("listings", []))
        print("listings: " + desc + " errors=" + str(len(result["errors"])))
    else:
        print("changed: " + ",".join(result.get("matching_languages", []))
              + " preserved=" + str(result.get("other_fields_preserved"))
              + " errors=" + str(len(result["errors"])))
    print("listing " + MODE + " done")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
