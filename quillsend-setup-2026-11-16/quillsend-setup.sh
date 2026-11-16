#!/data/data/com.termux/files/usr/bin/bash
# QuillSend owner setup — run in Termux on Andrew's phone.
#
#   cd ~/work/fleet-kit && git pull
#   bash quillsend-setup-2026-11-16/quillsend-setup.sh
#
# What it does (idempotent — safe to re-run; each phase checks before
# it creates, and a failed CREATE stops the script for diagnosis
# rather than minting siblings, per the fleet converger pacing rule):
#   1. Creates (or reuses) the QuillSend Google Cloud project and
#      enables the Gmail API.
#   2. Tries to create the OAuth consent brand + Web client through
#      the gcloud IAP APIs. Whatever the APIs refuse falls back to ONE
#      printed console step with the exact values to enter.
#   3. Generates the app's permanent upload keystore (if absent) and
#      records its SHA-1/SHA-256 fingerprints (public identifiers).
#   4. Deposits the repo secrets CI needs (QS_KEYSTORE_* and, when
#      known, QS_OAUTH_*_CLIENT_ID) into andrewdhorowitz/quillsend
#      via gh. Secret VALUES never appear in the results file or the
#      terminal summary — only names and timestamps.
#   5. PLAY_SERVICE_ACCOUNT_JSON: if the secret is already on the
#      repo, skips. Else if ~/play-service-account.json exists,
#      deposits it. Else CREATES a fresh key for the Play Publisher
#      service account with gcloud (running as Andrew) and deposits
#      it — no manual download step (Andrew, Nov 16, 2026). The key
#      file lives only on the phone; its value is never printed.
#
# Results land in quillsend-setup-results.txt next to this script —
# send that file's contents to Muse when it finishes (it contains
# no secrets: project id, OAuth client IDs and key fingerprints are
# public identifiers).
set -u
cd "$(dirname "$0")"
RESULTS="quillsend-setup-results.txt"
SUPPORT_EMAIL="andrewhorowitz3@gmail.com"
REPO="andrewdhorowitz/quillsend"
KEYSTORE="$HOME/quillsend-upload.jks"
CREDS_FILE="$HOME/quillsend-keystore-credentials.txt"
KEY_ALIAS="quillsend-upload"

log() { echo "$@" | tee -a "$RESULTS"; }
note() { echo "$@" >> "$RESULTS"; }
pace() { sleep $((20 + RANDOM % 20)); }   # deliberate pacing between provider creates

: > "$RESULTS"
log "QuillSend setup — $(date -Is)"
log "Account: $(gcloud config get-value account 2>/dev/null || echo '(gcloud not signed in)')"

# ---------- tools ----------
if [ -f "$HOME/work/fleet-kit/tools/termux-env/ensure-tools.sh" ]; then
  bash "$HOME/work/fleet-kit/tools/termux-env/ensure-tools.sh" || true
fi
for tool in gcloud gh jq python keytool; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    log "MISSING TOOL: $tool — install it (keytool comes with: pkg install -y openjdk-17) and re-run."
    exit 1
  fi
done
if ! gh auth status >/dev/null 2>&1; then
  log "gh is not signed in. Run: gh auth login  (account: andrewdhorowitz), then re-run this script."
  exit 1
fi

# ---------- phase 1: GCP project ----------
PROJECT_ID="quillsend-app"
if gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
  log "Project exists: $PROJECT_ID (reusing)"
else
  pace
  if gcloud projects create "$PROJECT_ID" --name="QuillSend" 2>create-err.txt; then
    log "Project created: $PROJECT_ID"
  else
    PROJECT_ID="quillsend-$((1000 + RANDOM % 9000))"
    log "quillsend-app unavailable ($(head -c 200 create-err.txt)); trying $PROJECT_ID ONCE."
    pace
    if gcloud projects create "$PROJECT_ID" --name="QuillSend" 2>create-err2.txt; then
      log "Project created: $PROJECT_ID"
    else
      log "PROJECT CREATION FAILED — stopping for diagnosis (no further creates attempted):"
      cat create-err2.txt | tee -a "$RESULTS"
      exit 1
    fi
  fi
fi
note "project_id=$PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null 2>&1

for api in gmail.googleapis.com iap.googleapis.com; do
  for attempt in 1 2 3; do
    if gcloud services enable "$api" --project="$PROJECT_ID" 2>/dev/null; then
      log "API enabled: $api"
      break
    fi
    [ "$attempt" = 3 ] && log "API ENABLE FAILED after 3 tries: $api (re-run the script to retry)"
    sleep 15
  done
done

# ---------- phase 2: OAuth brand + clients (best-effort API) ----------
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
BRAND=""
BRAND="$(gcloud alpha iap oauth-brands list --project="$PROJECT_ID" --format='value(name)' 2>/dev/null | head -1)"
if [ -z "$BRAND" ]; then
  pace
  BRAND="$(gcloud alpha iap oauth-brands create --application_title="QuillSend" --support_email="$SUPPORT_EMAIL" --project="$PROJECT_ID" --format='value(name)' 2>brand-err.txt)"
  if [ -n "$BRAND" ]; then
    log "OAuth brand created: $BRAND"
  else
    log "OAuth brand via API did not succeed. ONE console step instead:"
    log "  console.cloud.google.com -> project $PROJECT_ID -> APIs & Services -> OAuth consent screen:"
    log "  User type External, app name 'QuillSend', support email $SUPPORT_EMAIL, then Scopes -> add"
    log "  https://www.googleapis.com/auth/gmail.compose, and add your Google accounts as test users."
    note "brand=MANUAL (see above)"
  fi
else
  log "OAuth brand exists: $BRAND"
fi
[ -n "$BRAND" ] && note "brand=$BRAND"

# Web client via API (used by the Credential Manager account picker).
WEB_CLIENT_ID=""
if [ -n "$BRAND" ]; then
  TMPOUT="$(mktemp)"
  if gcloud alpha iap oauth-clients create qs-web --brand="$BRAND" --display_name="QuillSend Web" --project="$PROJECT_ID" >"$TMPOUT" 2>/dev/null; then
    WEB_CLIENT_ID="$(grep -oE '[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com' "$TMPOUT" | head -1)"
  fi
  rm -f "$TMPOUT"   # may contain a client secret — never kept, never logged
fi
if [ -n "$WEB_CLIENT_ID" ]; then
  log "Web OAuth client created: $WEB_CLIENT_ID"
  note "web_client_id=$WEB_CLIENT_ID"
else
  log "Web client not created via API. Console step (same sitting as the brand, if manual):"
  log "  APIs & Services -> Credentials -> Create credentials -> OAuth client ID -> Web application,"
  log "  name 'QuillSend Web'. Copy the client ID it shows."
  note "web_client_id=MANUAL"
fi

# ---------- phase 3: upload keystore ----------
if [ -f "$KEYSTORE" ]; then
  log "Keystore exists: $KEYSTORE (reusing)"
  STORE_PASS="$(grep '^storepass=' "$CREDS_FILE" 2>/dev/null | cut -d= -f2)"
  KEY_PASS="$(grep '^keypass=' "$CREDS_FILE" 2>/dev/null | cut -d= -f2)"
  if [ -z "$STORE_PASS" ] || [ -z "$KEY_PASS" ]; then
    log "Keystore exists but $CREDS_FILE is missing its passwords — cannot deposit secrets."
    log "Fix: restore that file (storepass=/keypass= lines) or delete the keystore and re-run."
    exit 1
  fi
else
  STORE_PASS="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
  KEY_PASS="$STORE_PASS"
  printf 'storepass=%s\nkeypass=%s\nalias=%s\n' "$STORE_PASS" "$KEY_PASS" "$KEY_ALIAS" > "$CREDS_FILE"
  chmod 600 "$CREDS_FILE"
  if keytool -genkeypair -keystore "$KEYSTORE" -alias "$KEY_ALIAS" \
      -keyalg RSA -keysize 2048 -validity 10957 \
      -storepass "$STORE_PASS" -keypass "$KEY_PASS" \
      -dname "CN=QuillSend, O=Andrew Horowitz" 2>keytool-err.txt; then
    log "Upload keystore generated: $KEYSTORE (passwords in $CREDS_FILE, mode 600)"
  else
    log "KEYSTORE GENERATION FAILED — stopping:"; cat keytool-err.txt | tee -a "$RESULTS"; exit 1
  fi
fi
SHA1="$(keytool -list -v -keystore "$KEYSTORE" -alias "$KEY_ALIAS" -storepass "$STORE_PASS" 2>/dev/null | grep -i 'SHA1:' | head -1 | sed 's/.*SHA1: *//')"
SHA256="$(keytool -list -v -keystore "$KEYSTORE" -alias "$KEY_ALIAS" -storepass "$STORE_PASS" 2>/dev/null | grep -i 'SHA256:' | head -1 | sed 's/.*SHA256: *//')"
log "Upload key SHA-1:   $SHA1"
log "Upload key SHA-256: $SHA256"
note "upload_key_sha1=$SHA1"
note "upload_key_sha256=$SHA256"

# Android OAuth client: no public API creates Android-type clients —
# one console step, with every value it needs printed here.
log "Android OAuth client (console, one time): APIs & Services -> Credentials -> Create credentials"
log "  -> OAuth client ID -> Android. Name 'QuillSend Android', package com.andrewdhorowitz.quillsend,"
log "  SHA-1 certificate fingerprint: $SHA1"
ANDROID_CLIENT_ID=""
if [ -n "${QS_ANDROID_CLIENT_ID_INPUT:-}" ]; then
  ANDROID_CLIENT_ID="$QS_ANDROID_CLIENT_ID_INPUT"
else
  printf 'Paste the Android client ID (or press Enter to finish it later): '
  read -r ANDROID_CLIENT_ID || ANDROID_CLIENT_ID=""
fi
[ -n "$ANDROID_CLIENT_ID" ] && note "android_client_id=$ANDROID_CLIENT_ID"
if [ -z "$WEB_CLIENT_ID" ]; then
  printf 'If you created the Web client in the console, paste its client ID (or Enter): '
  read -r WEB_CLIENT_ID || WEB_CLIENT_ID=""
  [ -n "$WEB_CLIENT_ID" ] && note "web_client_id=$WEB_CLIENT_ID"
fi

# ---------- phase 4: GitHub secret deposits ----------
log "Depositing repo secrets into $REPO (values are piped, never printed):"
base64 -w0 "$KEYSTORE" | gh secret set QS_KEYSTORE_BASE64 --repo "$REPO" && log "  QS_KEYSTORE_BASE64 set"
printf '%s' "$STORE_PASS" | gh secret set QS_KEYSTORE_PASSWORD --repo "$REPO" && log "  QS_KEYSTORE_PASSWORD set"
printf '%s' "$KEY_ALIAS" | gh secret set QS_KEY_ALIAS --repo "$REPO" && log "  QS_KEY_ALIAS set"
printf '%s' "$KEY_PASS" | gh secret set QS_KEY_PASSWORD --repo "$REPO" && log "  QS_KEY_PASSWORD set"
[ -n "$WEB_CLIENT_ID" ] && { printf '%s' "$WEB_CLIENT_ID" | gh secret set QS_OAUTH_WEB_CLIENT_ID --repo "$REPO" && log "  QS_OAUTH_WEB_CLIENT_ID set"; }
[ -n "$ANDROID_CLIENT_ID" ] && { printf '%s' "$ANDROID_CLIENT_ID" | gh secret set QS_OAUTH_ANDROID_CLIENT_ID --repo "$REPO" && log "  QS_OAUTH_ANDROID_CLIENT_ID set"; }
# Play Publisher service-account key: check the repo first; deposit the
# local file if one exists; otherwise create the key here, as Andrew.
PLAY_SA="play-publisher@play-publisher-513614.iam.gserviceaccount.com"
PLAY_KEY_FILE="$HOME/play-service-account.json"
if gh secret list --repo "$REPO" 2>/dev/null | awk '{print $1}' | grep -qx "PLAY_SERVICE_ACCOUNT_JSON"; then
  log "  PLAY_SERVICE_ACCOUNT_JSON already on the repo (skipping)"
elif [ -f "$PLAY_KEY_FILE" ]; then
  gh secret set PLAY_SERVICE_ACCOUNT_JSON --repo "$REPO" < "$PLAY_KEY_FILE" && log "  PLAY_SERVICE_ACCOUNT_JSON set (from $PLAY_KEY_FILE)"
else
  pace
  if gcloud iam service-accounts keys create "$PLAY_KEY_FILE" --iam-account="$PLAY_SA" 2>playkey-err.txt; then
    chmod 600 "$PLAY_KEY_FILE"
    log "  Play service-account key created: $PLAY_KEY_FILE (value never printed)"
    gh secret set PLAY_SERVICE_ACCOUNT_JSON --repo "$REPO" < "$PLAY_KEY_FILE" && log "  PLAY_SERVICE_ACCOUNT_JSON set"
  else
    log "  PLAY KEY CREATION FAILED — stopping for diagnosis (no retry, no sibling keys):"
    cat playkey-err.txt | tee -a "$RESULTS"
    log "  (Common causes: the 10-key cap on that service account, or missing"
    log "   iam.serviceAccountKeys.create permission on project play-publisher-513614.)"
    exit 1
  fi
fi
log "Secrets now on the repo (names only):"
gh secret list --repo "$REPO" 2>/dev/null | awk '{print "  " $1}' | tee -a "$RESULTS"

log ""
log "DONE. Send Muse the contents of $RESULTS (no secrets in it)."
log "Still owner-side after this: the Play Console app entry (package"
log "com.andrewdhorowitz.quillsend) — a ~5-minute console step with no API;"
log "and once the app is on Play, add the Play App Signing SHA-1 (Play Console"
log "-> App integrity) as a SECOND fingerprint on the Android OAuth client."
