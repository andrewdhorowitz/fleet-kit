#!/usr/bin/env bash
# 20261106-2230-tb-fcm-register.sh — owner-queue job (queued by
# Muse, 2026-11-06, after Andrew approved by tapping "Build the
# FCM converger and queue it to my owner loop" in the main chat at
# ~22:27 ET).
#
# PURPOSE: give the Text Bridge app its Firebase registration so
# the shipped-but-inert FCM push wake-up leg (v0.6.0+, currently
# dark because FcmConfig's app ID / API key are blank) can light up:
#   1. In the EXISTING Firebase project family-routines-app, find
#      the Android app registered for package
#      com.andrewdhorowitz.textbridge — reuse it if present;
#      create it ONCE if absent. (Check-first: a failed create is a
#      failure to diagnose, never a retry that mints a sibling.)
#   2. Fetch that app's google-services config.
#   3. Deposit four values as Actions secrets on repo
#      andrewdhorowitz/text-bridge:
#        TB_FCM_APP_ID  TB_FCM_API_KEY  TB_FCM_SENDER_ID  TB_FCM_PROJECT_ID
#      CI injects them into the APK as BuildConfig fields (v0.6.2+);
#      the app reads them in FcmConfig / BridgeApplication.
#
# AUTH: the Firebase Admin SDK service-account JSON Andrew already
# holds on this phone (newest family-routines-app-firebase-adminsdk*.json
# across ~/storage/downloads, ~/Downloads, ~) — the same pattern as
# scripts/firebase-converge.sh: an RS256 JWT signed with the key,
# exchanged at Google's OAuth2 endpoint, then Firebase Management
# API calls (firebase.googleapis.com/v1beta1). The project is
# pinned by the keyfile's own project_id field: if it is not
# family-routines-app, the job refuses to act (no guessing, no
# creating anything in some other project).
#
# SECRECY: config values live only in a mode-700 temp dir (wiped on
# exit) and in gh's stdin. They are never printed, logged, or
# committed — this job's output (which the loop commits to
# owner-queue/results/) carries secret NAMES and verdicts only.
# The bridge's real credentials (bridge token, enrolled key pair)
# are never touched; the SA key is used only for its normal auth.
#
# CONTRACT: non-interactive, idempotent — every step checks first,
# so any re-run after a partial pass converges without creating a
# second app or changing values already deposited. Exits 0 only
# when all four secrets verify present by name on the repo.

set -u

PROJECT="family-routines-app"
PACKAGE="com.andrewdhorowitz.textbridge"
DISPLAY_NAME="Text Bridge"
TARGET_REPO="andrewdhorowitz/text-bridge"
KEY_GLOB="family-routines-app-firebase-adminsdk*.json"
MGMT="https://firebase.googleapis.com/v1beta1"
TOKEN_URL="https://oauth2.googleapis.com/token"

now_et() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S %Z'; }

echo "job: 20261106-2230-tb-fcm-register.sh"
echo "started: $(now_et)"
echo "target: Firebase project $PROJECT, package $PACKAGE -> secrets on $TARGET_REPO"

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR" 2>/dev/null || true
cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then rm -rf "$WORKDIR"; fi
}
trap cleanup EXIT

die() { # $1 = named reason; prints the failure tail and exits 1
  echo "result: FAILED ($1)"
  echo "finished: $(now_et)"
  exit 1
}

# --- step 0: tools + gh auth ---------------------------------------
for tool in python3 curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "step tools: FAILED ($tool not found on this device)"
    die "$tool missing — nothing done"
  fi
done
if ! command -v gh >/dev/null 2>&1; then
  echo "step gh: FAILED (gh CLI not found on this device)"
  die "gh CLI missing — nothing done"
fi
if ! gh auth status >/dev/null 2>"$WORKDIR/ghauth.err"; then
  echo "step gh: FAILED (gh is present but not authenticated)"
  die "gh not authed — nothing done"
fi
echo "step gh: ✓ applied (gh CLI present and authenticated)"

secret_present() { # $1 = secret name; names only, never values
  gh secret list --repo "$TARGET_REPO" 2>/dev/null \
    | grep -q "^$1[[:space:]]"
}

# --- step 1: locate + validate the Firebase Admin SDK keyfile ------
KEYFILE=""
for dir in "$HOME/storage/downloads" "$HOME/Downloads" "$HOME"; do
  [[ -d "$dir" ]] || continue
  for f in "$dir"/$KEY_GLOB; do
    [[ -e "$f" ]] || continue
    if [[ -z "$KEYFILE" || "$f" -nt "$KEYFILE" ]]; then KEYFILE="$f"; fi
  done
done
if [[ -z "$KEYFILE" ]]; then
  echo "step keyfile: – skipped (no $KEY_GLOB in ~/storage/downloads, ~/Downloads, or ~)"
  die "Firebase Admin SDK keyfile not found on phone — cannot authenticate"
fi
if ! python3 - "$KEYFILE" "$WORKDIR/pkey.pem" "$WORKDIR/sa-email.txt" "$PROJECT" <<'PY' >/dev/null 2>&1
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if d.get("type") != "service_account":
    sys.exit(1)
if d.get("project_id") != sys.argv[4]:
    sys.exit(1)
email = d.get("client_email") or ""
key = d.get("private_key") or ""
if not email or "PRIVATE KEY" not in key:
    sys.exit(1)
open(sys.argv[2], "w").write(key)
open(sys.argv[3], "w").write(email)
PY
then
  echo "step keyfile: FAILED (a $KEY_GLOB file was found but is not a valid service-account JSON for project $PROJECT — refusing to use it)"
  die "keyfile invalid or for a different project — nothing done"
fi
echo "step keyfile: ✓ applied (Admin SDK keyfile found; project_id verified as $PROJECT; values not printed)"

# --- step 2: OAuth2 access token via RS256 JWT ----------------------
SA_EMAIL="$(cat "$WORKDIR/sa-email.txt")"
JWT_UNSIGNED="$(python3 - "$SA_EMAIL" "$TOKEN_URL" <<'PY'
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
)" || die "could not build the auth JWT — nothing done"
printf '%s' "$JWT_UNSIGNED" > "$WORKDIR/jwt-unsigned.txt"

SIG_OK=0
if command -v openssl >/dev/null 2>&1; then
  if openssl dgst -sha256 -sign "$WORKDIR/pkey.pem" -binary \
      -out "$WORKDIR/jwt-sig.bin" "$WORKDIR/jwt-unsigned.txt" 2>/dev/null; then
    SIG_OK=1
  fi
fi
if [[ $SIG_OK -eq 0 ]] && command -v node >/dev/null 2>&1; then
  if node -e '
const crypto = require("crypto"), fs = require("fs");
const data = fs.readFileSync(process.argv[1]);
const key = fs.readFileSync(process.argv[2], "utf8");
fs.writeFileSync(process.argv[3], crypto.sign("RSA-SHA256", data, key));
' "$WORKDIR/jwt-unsigned.txt" "$WORKDIR/pkey.pem" "$WORKDIR/jwt-sig.bin" 2>/dev/null; then
    SIG_OK=1
  fi
fi
if [[ $SIG_OK -eq 0 ]]; then
  echo "step auth: FAILED (no working RSA signer: openssl and node both unavailable or failed)"
  die "no RSA signer — nothing done"
fi
JWT="$(python3 - "$WORKDIR/jwt-unsigned.txt" "$WORKDIR/jwt-sig.bin" <<'PY'
import base64, sys
sig = base64.urlsafe_b64encode(open(sys.argv[2], "rb").read()).rstrip(b"=").decode()
print(open(sys.argv[1]).read().strip() + "." + sig)
PY
)" || die "could not assemble the auth JWT — nothing done"

TOKEN_CODE="$(curl -sS -o "$WORKDIR/token.json" -w '%{http_code}' -X POST "$TOKEN_URL" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "assertion=$JWT" 2>"$WORKDIR/curl.err" || echo 000)"
TOKEN_CODE="${TOKEN_CODE:0:3}"
if [[ "$TOKEN_CODE" != "200" ]]; then
  echo "step auth: FAILED (token exchange returned HTTP $TOKEN_CODE — the SA key may be revoked or the clock skewed)"
  die "OAuth token exchange failed (HTTP $TOKEN_CODE) — nothing done"
fi
ACCESS_TOKEN="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("access_token", ""))
' "$WORKDIR/token.json")"
[[ -n "$ACCESS_TOKEN" ]] || die "token exchange returned no access token — nothing done"
echo "step auth: ✓ applied (access token minted from the Admin SDK key; token never printed)"

# api METHOD URL [BODYFILE] -> sets API_CODE, body in $WORKDIR/api-body.json
api() {
  local method="$1" url="$2" bodyfile="${3:-}"
  local args=(-sS -o "$WORKDIR/api-body.json" -w '%{http_code}'
              -X "$method" -H "Authorization: Bearer $ACCESS_TOKEN"
              -H "Content-Type: application/json")
  if [[ -n "$bodyfile" ]]; then args+=(--data-binary "@$bodyfile"); fi
  API_CODE="$(curl "${args[@]}" "$url" 2>"$WORKDIR/api.err" || echo 000)"
  API_CODE="${API_CODE:0:3}"
}

err_note() { # short, value-free error summary from the last API body
  python3 - "$WORKDIR/api-body.json" <<'PY' 2>/dev/null || echo "no error detail"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    e = d.get("error", {})
    print((str(e.get("status", "")) + " " + str(e.get("message", "")))[:280])
except Exception:
    print("unparseable error body")
PY
}

# --- step 3: find the Android app (check first; create at most once)
api GET "$MGMT/projects/$PROJECT/androidApps?pageSize=100"
if [[ "$API_CODE" != "200" ]]; then
  echo "step list-apps: FAILED (HTTP $API_CODE: $(err_note))"
  die "could not list Android apps in $PROJECT (HTTP $API_CODE)"
fi
python3 - "$WORKDIR/api-body.json" "$PACKAGE" "$WORKDIR/app-name.txt" "$WORKDIR/app-count.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
apps = [a for a in d.get("apps", []) if a.get("packageName") == sys.argv[2]]
open(sys.argv[4], "w").write(str(len(apps)))
if len(apps) == 1:
    open(sys.argv[3], "w").write(apps[0].get("name", ""))
PY
APP_COUNT="$(cat "$WORKDIR/app-count.txt" 2>/dev/null || echo parse-error)"
if [[ "$APP_COUNT" == "parse-error" ]]; then
  die "could not parse the app list — nothing created"
fi
if [[ "$APP_COUNT" -gt 1 ]]; then
  echo "step find-app: FAILED ($APP_COUNT Android apps already carry package $PACKAGE — ambiguous; a human must decide which is the bridge's)"
  die "ambiguous: multiple apps for $PACKAGE — nothing created or deposited"
fi

if [[ "$APP_COUNT" == "1" ]]; then
  echo "step find-app: ✓ already (an Android app for $PACKAGE exists in $PROJECT — reusing it; nothing created)"
else
  printf '{"packageName": "%s", "displayName": "%s"}' "$PACKAGE" "$DISPLAY_NAME" \
    > "$WORKDIR/create-body.json"
  api POST "$MGMT/projects/$PROJECT/androidApps" "$WORKDIR/create-body.json"
  if [[ "$API_CODE" != "200" ]]; then
    echo "step create-app: FAILED (HTTP $API_CODE: $(err_note))"
    die "Android app creation failed (HTTP $API_CODE) — no retry minted; diagnose before re-running"
  fi
  OP_NAME="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("name", ""))
' "$WORKDIR/api-body.json")"
  if [[ -z "$OP_NAME" ]]; then
    die "create call returned no operation name — state unknown; re-run (the check-first list will find the app if it landed)"
  fi
  # Poll the operation to completion (paced, bounded) — no second create.
  CREATED=0
  for _ in $(seq 1 24); do
    sleep 5
    api GET "$MGMT/$OP_NAME"
    if [[ "$API_CODE" != "200" ]]; then
      echo "step create-app: FAILED (operation poll returned HTTP $API_CODE: $(err_note))"
      die "app creation state unknown (poll HTTP $API_CODE) — re-run is safe: the list check finds the app if it landed"
    fi
    if python3 - "$WORKDIR/api-body.json" "$WORKDIR/app-name.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if not d.get("done"):
    sys.exit(1)
if "error" in d:
    sys.exit(2)
name = (d.get("response") or {}).get("name", "")
if not name:
    sys.exit(2)
open(sys.argv[2], "w").write(name)
PY
    then
      CREATED=1
      break
    else
      rc=$?
      if [[ $rc -eq 2 ]]; then
        echo "step create-app: FAILED (the create operation completed with an error: $(err_note))"
        die "Android app creation operation errored — no sibling minted; diagnose before re-running"
      fi
    fi
  done
  if [[ $CREATED -ne 1 ]]; then
    die "app creation operation did not complete within ~2 minutes — re-run is safe (check-first)"
  fi
  echo "step create-app: ✓ applied (Android app for $PACKAGE registered in $PROJECT — exactly one create)"
fi

APP_NAME_RES="$(cat "$WORKDIR/app-name.txt")"
[[ -n "$APP_NAME_RES" ]] || die "no app resource name resolved — nothing deposited"

# --- step 4: fetch the app config, extract values to temp files ----
api GET "$MGMT/$APP_NAME_RES/config"
if [[ "$API_CODE" != "200" ]]; then
  echo "step config: FAILED (HTTP $API_CODE: $(err_note))"
  die "could not fetch the app config (HTTP $API_CODE) — nothing deposited"
fi
if ! python3 - "$WORKDIR/api-body.json" "$WORKDIR" "$PACKAGE" "$PROJECT" <<'PY'
import base64, json, sys
d = json.load(open(sys.argv[1]))
workdir = sys.argv[2]
raw = base64.b64decode(d["configFileContents"]).decode("utf-8")
cfg = json.loads(raw)
info = cfg.get("project_info", {})
if info.get("project_id") != sys.argv[4]:
    sys.exit(1)
clients = [c for c in cfg.get("client", [])
           if (c.get("client_info", {}).get("android_client_info", {})
               .get("package_name") == sys.argv[3])]
if len(clients) != 1:
    sys.exit(1)
c = clients[0]
app_id = c.get("client_info", {}).get("mobilesdk_app_id", "")
keys = c.get("api_key", [])
api_key = keys[0].get("current_key", "") if keys else ""
sender = str(info.get("project_number", ""))
if not app_id or not api_key or not sender:
    sys.exit(1)
open(workdir + "/v_app_id", "w").write(app_id)
open(workdir + "/v_api_key", "w").write(api_key)
open(workdir + "/v_sender_id", "w").write(sender)
open(workdir + "/v_project_id", "w").write(info["project_id"])
PY
then
  echo "step config: FAILED (the fetched config does not carry the expected project/package fields — refusing to deposit anything unverified)"
  die "config extraction failed validation — nothing deposited"
fi
echo "step config: ✓ applied (google-services config fetched; app ID, API key, sender ID, project ID extracted to the private temp dir; values not printed)"

# --- step 5: deposit the four secrets (names verified only) --------
declare -a NAMES=(TB_FCM_APP_ID TB_FCM_API_KEY TB_FCM_SENDER_ID TB_FCM_PROJECT_ID)
declare -a FILES=(v_app_id v_api_key v_sender_id v_project_id)
DEPOSIT_OK=1
for i in 0 1 2 3; do
  name="${NAMES[$i]}"
  if secret_present "$name"; then
    echo "step deposit $name: ✓ already (present on $TARGET_REPO — left untouched)"
  elif ! gh secret set "$name" --repo "$TARGET_REPO" < "$WORKDIR/${FILES[$i]}" \
      2>"$WORKDIR/gh-$name.err"; then
    echo "step deposit $name: FAILED (gh secret set failed)"
    DEPOSIT_OK=0
  elif secret_present "$name"; then
    echo "step deposit $name: ✓ applied (set on $TARGET_REPO; verified by name)"
  else
    echo "step deposit $name: FAILED (set attempted but the name did not appear in gh secret list)"
    DEPOSIT_OK=0
  fi
done

# --- summary ---------------------------------------------------------
echo "summary (names + status only; no values were printed or stored):"
for name in "${NAMES[@]}"; do
  if secret_present "$name"; then
    echo "  $name: present on $TARGET_REPO"
  else
    echo "  $name: MISSING on $TARGET_REPO"
    DEPOSIT_OK=0
  fi
done

if [[ $DEPOSIT_OK -eq 1 ]]; then
  echo "result: SUCCESS (Text Bridge FCM registration complete; all four secrets present on $TARGET_REPO)"
  echo "finished: $(now_et)"
  exit 0
fi
die "deposit incomplete — see the step lines above for the named reason"
