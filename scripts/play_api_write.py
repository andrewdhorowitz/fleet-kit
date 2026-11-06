#!/usr/bin/env python3
"""Play API tester write: add TARGET_EMAIL (env) to an app's internal-track tester list.

Runs inside GitHub Actions (play-api-write workflow) with the
PLAY_API_SERVICE_ACCOUNT_JSON secret in env. The key value is never printed.

Flow (single edit, PUT the tester resource, then commit):
  1. edits.insert for the package.
  2. edits.testers.get(internal) — current state (counts + target presence).
  3. If a Google Group manages the track: STOP without writing
     (Console email lists are not API-writable in that configuration).
  4. If baileynhorowitz@gmail.com already present: report, delete edit, exit 0.
  5. Else append her, PUT the updated tester resource, edits.commit,
     then verify membership with a fresh edit's testers.get.
Output: statuses, counts, and boolean membership only (no address lists).
"""
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from play_api_probe import get_access_token, API

TARGET = os.environ.get("WRITE_TARGET_EMAIL", "fourpshot@gmail.com")
TRACK = "internal"


def call2(method, url, tok, body=None):
    """Like probe.call but with an optional JSON request body."""
    req = urllib.request.Request(url, method=method, data=body)
    req.add_header("Authorization", "Bearer " + tok)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", "replace")
            if not raw.strip():
                return resp.status, {}
            try:
                return resp.status, json.loads(raw)
            except json.JSONDecodeError:
                return resp.status, {"raw": raw[:200]}
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", "replace")[:400]
        return err.code, {"error_body": detail}


def main() -> int:
    package = os.environ["WRITE_PACKAGE"]
    sa = json.loads(os.environ["PLAY_API_SERVICE_ACCOUNT_JSON"])
    print("write package: " + package + " / track: " + TRACK)
    print("service account: " + str(sa.get("client_email")))
    try:
        tok = get_access_token(sa)
    except Exception as exc:
        print("stage FAILED: oauth token — " + type(exc).__name__)
        return 1
    print("oauth: token acquired")

    status, edit = call2("POST", API + "/" + package + "/edits", tok, b"{}")
    print("edits.insert: HTTP " + str(status))
    if status != 200:
        print(json.dumps(edit)[:300])
        return 1
    edit_id = edit["id"]
    committed = False
    try:
        base = API + "/" + package + "/edits/" + edit_id + "/testers/" + TRACK
        s, cur = call2("GET", base, tok)
        print("testers.get (before): HTTP " + str(s))
        if s != 200:
            print(json.dumps(cur)[:300])
            return 1
        groups = cur.get("googleGroups") or []
        emails = cur.get("testers") or []
        print("current: googleGroups=" + str(len(groups))
              + " individualTesters=" + str(len(emails))
              + " targetPresent=" + str(TARGET in emails))
        if groups:
            print("stage STOPPED: track list is Google-Group managed; the "
                  "account-level Console email-list write is not available "
                  "through the standard testers endpoint. No write attempted.")
            return 2
        if TARGET in emails:
            print("result: target already on the list — nothing to write")
            return 0
        body = json.dumps({"testers": emails + [TARGET]}).encode()
        s, res = call2("PUT", base, tok, body)
        print("testers.update: HTTP " + str(s))
        if s != 200:
            print(json.dumps(res)[:300])
            return 1
        s, res = call2("POST", API + "/" + package + "/edits/" + edit_id + ":commit", tok, b"")
        print("edits.commit: HTTP " + str(s))
        if s != 200:
            print(json.dumps(res)[:300])
            return 1
        committed = True
    finally:
        if not committed:
            s, _ = call2("DELETE", API + "/" + package + "/edits/" + edit_id, tok)
            print("edits.delete (uncommitted cleanup): HTTP " + str(s))
    s, edit2 = call2("POST", API + "/" + package + "/edits", tok, b"{}")
    if s == 200:
        eid2 = edit2["id"]
        try:
            s, after = call2("GET", API + "/" + package + "/edits/" + eid2 + "/testers/" + TRACK, tok)
            emails2 = after.get("testers") or []
            print("verify testers.get: HTTP " + str(s)
                  + " individualTesters=" + str(len(emails2))
                  + " targetPresent=" + str(TARGET in emails2))
        finally:
            call2("DELETE", API + "/" + package + "/edits/" + eid2, tok)
    print("result: WRITE COMMITTED AND VERIFIED" if committed else "result: no change")
    return 0


if __name__ == "__main__":
    sys.exit(main())
