#!/usr/bin/env bash
# 2026-10-30-routines-secret.sh — owner-queue job (queued by Muse, 2026-10-30).
#
# PURPOSE: set the FIREBASE_API_KEY Actions secret on
# andrewdhorowitz/routines-and-streaks so its deploy workflow can
# build the Routines & Streaks app. The value is the Firebase web
# API key for project family-routines-app, fetched live from the
# Firebase Management API using the Admin SDK service-account JSON
# in ~/storage/downloads — the same credential and the same
# discovery/token approach as scripts/firebase-converge.sh.
#
# SECRECY: this repo is PUBLIC. The apiKey lives ONLY in shell
# variables on this device — never printed, never written to a
# file, never committed. API responses and the extracted private
# key stay in a private mktemp dir that is wiped on exit. This
# job's output (owner-queue/results/<this>.log) carries only step
# verdicts and timestamps.
#
# CONTRACT: non-interactive, idempotent (if the secret is already
# set it reports "✓ already" and exits 0 without fetching the
# key), fails closed — any error names the failing step and stops;
# no retries inside the job.

set -u

PROJECT="family-routines-app"
TARGET_REPO="andrewdhorowitz/routines-and-streaks"
SECRET_NAME="FIREBASE_API_KEY"
DOWNLOADS_GLOB="family-routines-app-firebase-adminsdk*.json"
TOKEN_URL="https://oauth2.googleapis.com/token"
FIREBASE_API="https://firebase.googleapis.com/v1beta1"

now_et() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S %Z'; }

echo "job: 2026-10-30-routines-secret.sh"
echo "started: $(now_et)"

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR" 2>/dev/null || true
APIKEY=""
ACCESS_TOKEN=""
cleanup() {
  APIKEY=""
  ACCESS_TOKEN=""
  unset APIKEY ACCESS_TOKEN 2>/dev/null || true
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then rm -rf "$WORKDIR"; fi
}
trap cleanup EXIT

fail() {
  echo "step $1: FAILED ($2)"
  echo "result: FAILED"
  echo "finished: $(now_et)"
  exit 1
}

# --- step 0: idempotency — already set? (names only) -------------
if gh secret list --repo "$TARGET_REPO" 2>"$WORKDIR/gh0.err" \
    | grep -q "^$SECRET_NAME[[:space:]]"; then
  echo "step secret: ✓ already ($SECRET_NAME present on $TARGET_REPO)"
  echo "result: SUCCESS"
  echo "finished: $(now_et)"
  exit 0
fi

# --- step 1: locate the service-account JSON ----------------------
# Same discovery as scripts/firebase-converge.sh: the newest match
# in ~/storage/downloads.
KEYFILE=""
newest=""
for f in "$HOME"/storage/downloads/$DOWNLOADS_GLOB; do
  [[ -e "$f" ]] || continue
  if [[ -z "$newest" || "$f" -nt "$newest" ]]; then newest="$f"; fi
done
[[ -n "$newest" ]] \
  || fail "keyfile" "no service-account JSON matching $DOWNLOADS_GLOB in ~/storage/downloads"
KEYFILE="$newest"
echo "step keyfile: ✓ found (newest service-account JSON in ~/storage/downloads)"

# --- step 2: service-account OAuth access token -------------------
# RS256 JWT signed with openssl (node fallback), exchanged at
# Google's OAuth2 endpoint — the firebase-converge.sh approach.
command -v python3 >/dev/null 2>&1 || fail "token" "python3 missing"
command -v curl >/dev/null 2>&1 || fail "token" "curl missing"

if ! python3 - "$KEYFILE" "$WORKDIR/pkey.pem" "$WORKDIR/sa-email.txt" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
email = d.get("client_email") or ""
key = d.get("private_key") or ""
if not email or "PRIVATE KEY" not in key:
    sys.exit(1)
open(sys.argv[2], "w").write(key)
open(sys.argv[3], "w").write(email)
PY
then
  fail "token" "service-account JSON unreadable or missing client_email/private_key"
fi

email="$(cat "$WORKDIR/sa-email.txt")"
jwt_unsigned="$(python3 - "$email" "$TOKEN_URL" <<'PY'
import base64, json, sys, time
def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
now = int(time.time())
header = {"alg": "RS256", "typ": "JWT"}
claims = {"iss": sys.argv[1],
          "scope": "https://www.googleapis.com/auth/cloud-platform",
          "aud": sys.argv[2], "iat": now, "exp": now + 3600}
print(b64(json.dumps(header).encode()) + "." + b64(json.dumps(claims).encode()))
PY
)" || fail "token" "could not build the JWT"
printf '%s' "$jwt_unsigned" > "$WORKDIR/jwt-unsigned.txt"

if command -v openssl >/dev/null 2>&1; then
  openssl dgst -sha256 -sign "$WORKDIR/pkey.pem" \
    -out "$WORKDIR/jwt-sig.bin" "$WORKDIR/jwt-unsigned.txt" \
    2>"$WORKDIR/sign.err" || fail "token" "openssl signing failed"
elif command -v node >/dev/null 2>&1; then
  cat > "$WORKDIR/sign.js" <<'JS'
const fs = require("fs");
const crypto = require("crypto");
const data = fs.readFileSync(process.argv[2]);
const key = fs.readFileSync(process.argv[3], "utf8");
fs.writeFileSync(process.argv[4], crypto.sign("RSA-SHA256", data, key));
JS
  node "$WORKDIR/sign.js" "$WORKDIR/jwt-unsigned.txt" \
    "$WORKDIR/pkey.pem" "$WORKDIR/jwt-sig.bin" \
    2>"$WORKDIR/sign.err" || fail "token" "node signing failed"
else
  fail "token" "no RSA signer available: openssl and node both missing"
fi

jwt="$(python3 - "$WORKDIR/jwt-unsigned.txt" "$WORKDIR/jwt-sig.bin" <<'PY'
import base64, sys
sig = base64.urlsafe_b64encode(open(sys.argv[2], "rb").read()).rstrip(b"=").decode()
print(open(sys.argv[1]).read().strip() + "." + sig)
PY
)" || fail "token" "could not assemble the signed JWT"

code="$(curl -sS -o "$WORKDIR/token.json" -w '%{http_code}' -X POST "$TOKEN_URL" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "assertion=$jwt" 2>"$WORKDIR/curl.err" || echo 000)"
code="${code:0:3}"
[[ "$code" == "200" ]] || fail "token" "OAuth token exchange returned HTTP $code"
ACCESS_TOKEN="$(python3 - "$WORKDIR/token.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("access_token", ""))
except Exception:
    print("")
PY
)"
[[ -n "$ACCESS_TOKEN" ]] || fail "token" "token response carried no access_token"
echo "step token: ✓ applied (service-account OAuth token obtained)"

# --- step 3: the project's web app config --------------------------
code="$(curl -sS -g -o "$WORKDIR/webapps.json" -w '%{http_code}' \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    "$FIREBASE_API/projects/$PROJECT/webApps" 2>"$WORKDIR/curl.err" || echo 000)"
code="${code:0:3}"
if [[ "$code" != "200" ]]; then
  estatus="$(python3 - "$WORKDIR/webapps.json" <<'PY'
import json, sys
try:
    print((json.load(open(sys.argv[1])).get("error") or {}).get("status", ""))
except Exception:
    print("")
PY
)"
  fail "webapps" "Firebase API list webApps returned HTTP $code ${estatus:+($estatus)}"
fi

APP_IDS=()
while IFS= read -r aid; do
  [[ -n "$aid" ]] && APP_IDS+=("$aid")
done < <(python3 - "$WORKDIR/webapps.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for app in d.get("apps", []):
    aid = app.get("appId") or ""
    if aid:
        print(aid)
PY
)
[[ ${#APP_IDS[@]} -gt 0 ]] || fail "webapps" "project has no web apps"
echo "step webapps: ✓ applied (${#APP_IDS[@]} web app(s) listed)"

# Fetch each app's config; require every web app to agree on one
# apiKey — fail closed rather than guess. Keys stay in variables.
KEYS=()
for aid in "${APP_IDS[@]}"; do
  ccode="$(curl -sS -g -o "$WORKDIR/cfg.json" -w '%{http_code}' \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$FIREBASE_API/projects/$PROJECT/webApps/$aid/config" \
      2>"$WORKDIR/curl.err" || echo 000)"
  ccode="${ccode:0:3}"
  [[ "$ccode" == "200" ]] \
    || fail "webapp-config" "config fetch for a web app returned HTTP $ccode"
  k="$(python3 - "$WORKDIR/cfg.json" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("apiKey", ""))
except Exception:
    print("")
PY
)"
  [[ -n "$k" ]] && KEYS+=("$k")
done
[[ ${#KEYS[@]} -gt 0 ]] || fail "webapp-config" "no apiKey in any web app config"
APIKEY="${KEYS[0]}"
for k in "${KEYS[@]}"; do
  [[ "$k" == "$APIKEY" ]] \
    || fail "webapp-config" "web apps disagree on the apiKey — refusing to guess"
done
echo "step webapp-config: ✓ applied (apiKey obtained; held in memory only)"

# --- step 4: set the secret and verify (names only) ----------------
command -v gh >/dev/null 2>&1 || fail "secret-set" "gh CLI missing"
if ! gh secret set "$SECRET_NAME" --repo "$TARGET_REPO" --body "$APIKEY" \
    2>"$WORKDIR/gh.err"; then
  fail "secret-set" "gh secret set failed"
fi
APIKEY=""
unset APIKEY
if gh secret list --repo "$TARGET_REPO" 2>"$WORKDIR/gh2.err" \
    | grep -q "^$SECRET_NAME[[:space:]]"; then
  echo "step secret: ✓ applied ($SECRET_NAME set on $TARGET_REPO; verified in the secret list)"
else
  fail "secret-verify" "$SECRET_NAME did not appear in gh secret list after set"
fi
echo "result: SUCCESS"
echo "finished: $(now_et)"
exit 0
