#!/usr/bin/env python3
"""Play Integrity API probe (read-only in effect).

Answers one question for the Bridge enrollment gate: from the play-api
service account (Play-linked Cloud project play-publisher-513614), can
playintegrity.googleapis.com decode a token for
com.andrewdhorowitz.bridge?

The probe calls decodeIntegrityToken with a deliberately dummy token:
  - HTTP 400 (invalid token)  -> API enabled AND caller authorized:
    the decode path is LIVE.
  - HTTP 403 SERVICE_DISABLED -> API not enabled in the project yet.
  - HTTP 403 PERMISSION_DENIED -> caller lacks decode permission.
Findings land in play-diag/results-integrity-probe.json (statuses and
Google error text only — never any credential material).
"""
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

PACKAGE = "com.andrewdhorowitz.bridge"
SCOPE = "https://www.googleapis.com/auth/playintegrity"
OUT_DIR = os.environ.get("DIAG_OUT_DIR", "play-diag")


def main() -> int:
    result = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "package": PACKAGE,
        "probe": "decodeIntegrityToken with a dummy token",
    }
    sa = json.loads(os.environ["PLAY_API_SERVICE_ACCOUNT_JSON"])
    result["service_account"] = sa.get("client_email")
    result["sa_project"] = sa.get("project_id")
    try:
        from google.oauth2 import service_account
        import google.auth.transport.requests

        creds = service_account.Credentials.from_service_account_info(sa, scopes=[SCOPE])
        creds.refresh(google.auth.transport.requests.Request())
        token = creds.token
        result["oauth"] = "token acquired (scope playintegrity)"
    except Exception as exc:
        result["oauth"] = "FAILED: " + type(exc).__name__ + ": " + str(exc)[:300]
        return finish(result, 1)

    url = f"https://playintegrity.googleapis.com/v1/{PACKAGE}:decodeIntegrityToken"
    req = urllib.request.Request(
        url,
        data=json.dumps({"integrity_token": "probe-dummy-token-not-a-real-token"}).encode(),
        method="POST",
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result["decode_http"] = resp.status
            result["decode_body"] = resp.read().decode("utf-8", "replace")[:500]
            result["verdict"] = "unexpected success with a dummy token"
            return finish(result, 1)
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "replace")
        result["decode_http"] = err.code
        result["decode_body"] = body[:800]
        if err.code == 400:
            result["verdict"] = "LIVE: API enabled and caller authorized (dummy token rejected as invalid, as expected)"
            return finish(result, 0)
        if err.code == 403 and ("SERVICE_DISABLED" in body or "has not been used" in body):
            result["verdict"] = "BLOCKED: Play Integrity API not enabled in the SA project"
            return finish(result, 1)
        if err.code == 403:
            result["verdict"] = "BLOCKED: caller not permitted to decode (IAM or project-link issue)"
            return finish(result, 1)
        result["verdict"] = "UNEXPECTED HTTP " + str(err.code)
        return finish(result, 1)
    except Exception as exc:
        result["decode_http"] = None
        result["verdict"] = "FAILED: " + type(exc).__name__ + ": " + str(exc)[:300]
        return finish(result, 1)


def finish(result, code):
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "results-integrity-probe.json")
    with open(path, "w") as f:
        json.dump(result, f, indent=1, sort_keys=True)
    print(json.dumps(result, indent=1, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
