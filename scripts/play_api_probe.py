#!/usr/bin/env python3
"""Play API read probe for the dedicated play-api service account.

Runs inside the play-api-probe workflow in GitHub Actions, where the
PLAY_API_SERVICE_ACCOUNT_JSON secret is available as an env var. The
key value is never printed; output is HTTP statuses and tester-list
membership counts only (no email addresses).

Probe sequence (all read-only in effect):
  1. Insert an edit for the package (creates a disposable draft edit).
  2. edits.testers.get for each known track; report tester counts and
     whether the list is Play-managed (googleGroups empty) or
     group-based.
  3. Delete the edit — nothing is ever committed.

Exit code 0 when the edit insert + at least one testers.get succeed.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import base64

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"
TRACKS = ["internal", "alpha", "beta"]


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def get_access_token(sa: dict) -> str:
    # RS256 JWT exchange, stdlib + openssl-free path: use PyJWT-free
    # manual signing via the `cryptography` package when available;
    # fall back to google-auth if present.
    try:
        from google.oauth2 import service_account
        import google.auth.transport.requests

        creds = service_account.Credentials.from_service_account_info(sa, scopes=[SCOPE])
        creds.refresh(google.auth.transport.requests.Request())
        return creds.token
    except ImportError:
        pass
    # Manual JWT with cryptography
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": sa["client_email"],
        "scope": SCOPE,
        "aud": "https://oauth2.googleapis.com/token",
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = f"{b64url(json.dumps(header).encode())}.{b64url(json.dumps(claims).encode())}"
    key = serialization.load_pem_private_key(sa["private_key"].encode(), password=None)
    sig = key.sign(signing_input.encode(), padding.PKCS1v15(), hashes.SHA256())
    jwt_token = f"{signing_input}.{b64url(sig)}"
    body = urllib.parse.urlencode(
        {"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": jwt_token}
    ).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=body)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["access_token"]


def call(method: str, url: str, token: str):
    req = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {token}"})
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
    package = os.environ["PROBE_PACKAGE"]
    try:
        sa = json.loads(os.environ["PLAY_API_SERVICE_ACCOUNT_JSON"])
    except Exception as exc:
        print(f"probe stage FAILED: secret JSON parse — {type(exc).__name__}: {exc}")
        return 1
    print(f"probe package: {package}")
    print(f"service account: {sa.get('client_email')}")
    try:
        token = get_access_token(sa)
    except Exception as exc:
        detail = ""
        if isinstance(exc, urllib.error.HTTPError):
            detail = exc.read().decode("utf-8", "replace")[:300]
        print(f"probe stage FAILED: oauth token exchange — {type(exc).__name__}: {exc} {detail}")
        return 1
    print("oauth: token acquired")

    status, edit = call("POST", f"{API}/{package}/edits", token)
    print(f"edits.insert: HTTP {status}")
    if status != 200:
        print(json.dumps(edit)[:400])
        print("probe stage FAILED: edits.insert (API rejected the edit — "
              "usually service account not linked in Play Console, or grant not yet propagated)")
        return 1
    edit_id = edit["id"]
    ok_reads = 0
    try:
        for track in TRACKS:
            s, res = call("GET", f"{API}/{package}/edits/{edit_id}/testers/{track}", token)
            if s == 200:
                ok_reads += 1
                groups = res.get("googleGroups") or []
                print(f"testers.get[{track}]: HTTP 200 — googleGroups: {len(groups)}")
            else:
                msg = res.get("error_body", "")[:200]
                print(f"testers.get[{track}]: HTTP {s} {msg}")
    finally:
        s, _ = call("DELETE", f"{API}/{package}/edits/{edit_id}", token)
        print(f"edits.delete (cleanup, never committed): HTTP {s}")
    print(f"probe result: {ok_reads}/{len(TRACKS)} tester reads OK")
    return 0 if ok_reads > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
