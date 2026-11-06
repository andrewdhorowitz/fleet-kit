#!/usr/bin/env python3
"""Play API verify: internal-track releases + tester membership for Routines Clarity.

Diagnostic for Andrew's "App not available" opt-in failure (Nov 6, 2026).
Read-only in effect: inserts a disposable edit, reads tracks + testers,
deletes the edit. Prints status lines plus a full membership detail line
listing which of the four checked addresses are on the internal tester
list (Andrew's own accounts + family testers; no other addresses exist
on these lists per the recorded hybrid model).
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from play_api_probe import get_access_token, API
from play_api_write import call2

PACKAGE_DEFAULT = "com.andrewdhorowitz.routinesandstreaks"
CHECK = [
    "fourpshot@gmail.com",
    "andrewhorowitz3@gmail.com",
    "baileynhorowitz@gmail.com",
    "jessicamhorowitz@gmail.com",
]


def main() -> int:
    package = os.environ.get("VERIFY_PACKAGE", PACKAGE_DEFAULT)
    sa = json.loads(os.environ["PLAY_API_SERVICE_ACCOUNT_JSON"])
    print("verify package: " + package)
    print("service account: " + str(sa.get("client_email")))
    try:
        tok = get_access_token(sa)
    except Exception as exc:
        print("stage FAILED: oauth token - " + type(exc).__name__)
        return 1
    print("oauth: token acquired")

    status, edit = call2("POST", API + "/" + package + "/edits", tok, b"{}")
    print("edits.insert: HTTP " + str(status))
    if status != 200:
        print(json.dumps(edit)[:300])
        return 1
    edit_id = edit["id"]
    try:
        s, tracks = call2("GET", API + "/" + package + "/edits/" + edit_id + "/tracks", tok)
        print("tracks.list: HTTP " + str(s))
        if s == 200:
            for t in tracks.get("tracks", []):
                rels = t.get("releases") or []
                desc = []
                for r in rels:
                    codes = ",".join(str(c) for c in (r.get("versionCodes") or []))
                    desc.append(str(r.get("status")) + " vc=" + codes + " name=" + str(r.get("name")))
                print("track " + str(t.get("track")) + ": releases=" + str(len(rels)) + " [" + "; ".join(desc) + "]")
        else:
            print(json.dumps(tracks)[:300])
        s, cur = call2("GET", API + "/" + package + "/edits/" + edit_id + "/testers/internal", tok)
        print("testers.get[internal]: HTTP " + str(s))
        if s == 200:
            groups = cur.get("googleGroups") or []
            emails = cur.get("testers") or []
            print("internal testers: googleGroups=" + str(len(groups)) + " " + json.dumps(groups)
                  + " individualTesters=" + str(len(emails)))
            present = [a for a in CHECK if a in emails]
            print("membership detail: present=" + json.dumps(present)
                  + " totalIndividual=" + str(len(emails)))
        else:
            print(json.dumps(cur)[:300])
    finally:
        s, _ = call2("DELETE", API + "/" + package + "/edits/" + edit_id, tok)
        print("edits.delete (cleanup, never committed): HTTP " + str(s))
    print("verify done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
