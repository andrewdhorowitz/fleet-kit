#!/usr/bin/env python3
"""Play API DIAGNOSTIC (read-only in effect) — Bridge track truth.

Built for the Bridge phone-compatibility question (Nov 6, 2026):
v1.1.0/vc2 (leanback required=false) is published on the internal track,
yet Andrew's phone still shows "device isn't compatible". This dumps the
track's exact release state so we can see whether vc2 is really the
active serving release or whether vc1 still is.

For com.andrewdhorowitz.bridge this script:
  1. inserts a disposable edit,
  2. reads tracks.list (every track, every release with status),
  3. reads testers.get for EVERY track returned,
  4. reads deviceTierConfigs.list (any API-visible device targeting),
  5. deletes the edit — nothing is ever committed to Play.

Findings are written as JSON under play-diag/ in the repo checkout
(results-bridge.json) because job logs / step summaries are not
readable through the fleet PAT. The SA key is never printed.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from play_api_probe import get_access_token, API

PACKAGES = {
    "bridge": "com.andrewdhorowitz.bridge",
}
OUT_DIR = os.environ.get("DIAG_OUT_DIR", "play-diag")


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


def release_view(r):
    return {
        "name": r.get("name"),
        "versionCodes": r.get("versionCodes"),
        "status": r.get("status"),
        "userFraction": r.get("userFraction"),
    }


def diagnose(package, tok):
    result = {"package": package, "errors": []}
    status, edit = call2("POST", API + "/" + package + "/edits", tok, b"{}")
    result["edits_insert_http"] = status
    if status != 200:
        result["errors"].append("edits.insert: " + json.dumps(edit)[:300])
        return result
    edit_id = edit["id"]
    base = API + "/" + package + "/edits/" + edit_id
    try:
        s, tracks = call2("GET", base + "/tracks", tok)
        result["tracks_list_http"] = s
        if s != 200:
            result["errors"].append("tracks.list: " + json.dumps(tracks)[:300])
            result["tracks"] = []
            return result
        track_objs = tracks.get("tracks", [])
        result["tracks"] = [
            {
                "track": t.get("track"),
                "releases": [release_view(r) for r in (t.get("releases") or [])],
            }
            for t in track_objs
        ]
        testers = {}
        for t in track_objs:
            name = t.get("track")
            s2, res = call2("GET", base + "/testers/" + name, tok)
            entry = {"http": s2}
            if s2 == 200:
                entry["googleGroups"] = res.get("googleGroups") or []
                entry["testers"] = res.get("testers") or []
            else:
                entry["error_body"] = (res.get("error_body") or "")[:300]
            testers[name] = entry
        result["testers"] = testers
        s3, dtc = call2("GET", base + "/deviceTierConfigs", tok)
        entry = {"http": s3}
        if s3 == 200:
            cfgs = dtc.get("deviceTierConfigs") or []
            entry["count"] = len(cfgs)
            entry["ids"] = [c.get("deviceTierConfigId") for c in cfgs]
        else:
            entry["error_body"] = (dtc.get("error_body") or "")[:300]
        result["deviceTierConfigs"] = entry
    finally:
        s, _ = call2("DELETE", base, tok)
        result["edits_delete_http"] = s
    return result


def main() -> int:
    sa = json.loads(os.environ["PLAY_API_SERVICE_ACCOUNT_JSON"])
    try:
        tok = get_access_token(sa)
    except Exception as exc:
        print("stage FAILED: oauth token - " + type(exc).__name__)
        return 1
    os.makedirs(OUT_DIR, exist_ok=True)
    stamp = datetime.now(timezone.utc).isoformat()
    ok = True
    for short, package in PACKAGES.items():
        res = diagnose(package, tok)
        res["generated_at"] = stamp
        res["service_account"] = sa.get("client_email")
        path = os.path.join(OUT_DIR, "results-" + short + ".json")
        with open(path, "w") as fh:
            json.dump(res, fh, indent=1, sort_keys=True)
        tracks_desc = "; ".join(
            t["track"] + "=" + ",".join(
                str(r["status"]) + "/vc" + ",".join(str(c) for c in (r["versionCodes"] or []))
                for r in t["releases"]) for t in res.get("tracks", []))
        print(short + ": tracks[" + tracks_desc + "] errors=" + str(len(res["errors"])))
        if res.get("tracks_list_http") != 200:
            ok = False
    print("diag done")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
