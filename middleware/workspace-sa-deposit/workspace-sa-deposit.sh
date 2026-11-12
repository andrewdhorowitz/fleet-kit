#!/usr/bin/env bash
# workspace-sa-deposit.sh — Step 0 of the Family Board invitation
# workflow: stand up the andrew-middleware Worker's Workspace
# service-account leg (runbook: goals/family-board/files/
# invitation-workflow-runbook-2026-11-11.md, Step 0).
#
# What it does, under Andrew's own login on his phone:
#   1. Creates OR reuses exactly ONE GCP project (andrewhorowitz3)
#      to hold the service account.
#   2. Enables the Admin SDK API (admin.googleapis.com) there.
#   3. Creates OR reuses ONE service account (mw-groups) and prints
#      its client ID + the exact Admin-console delegation step.
#   4. Mints at most ONE JSON key for it — into a phone-only temp
#      file — and deposits it as the Worker secret
#      GCP_WORKSPACE_SA_KEY via the Cloudflare API, then shreds the
#      temp file. The key value is never printed, logged, committed,
#      or sent anywhere else.
#   5. Deposits WORKSPACE_ADMIN_EMAIL (read from a one-line file
#      Andrew creates once: ~/workspace-admin-email.txt) as the
#      second Worker secret.
#
# Converger rules honored (fleet pacing rule + play-api-converge.sh
# precedent, owner-queue/done/20261106-1605-play-api-converge.sh):
# - Read-only preflight first; check before create; exactly ONE
#   project and ONE service account. A failed create is
#   STOP-and-report — this script never retries a create and never
#   mints a sibling resource (no second project ID, ever).
# - Idempotent + checkpointed (~/.workspace-sa-deposit.state):
#   a re-run reuses what exists and only re-verifies the secrets.
# - Pacing: deliberate sleeps with jitter between provider calls.
# - Non-interactive: stdin is never read (owner-queue jobs run with
#   stdin = /dev/null). Every input comes from a file or the
#   environment; a missing input is a clean stop with instructions.
# House style: "✓ applied" / "✓ already" / "– skipped (reason)";
# exit 0 only on verified success.

set -u
export PATH="$HOME/.local/bin:$HOME/bin:/data/data/com.termux/files/usr/bin:$PATH"

WORKER_NAME="andrew-middleware"
PROJECT_ID_DEFAULT="andrew-mw-workspace"
PROJECT_NAME="Andrew Middleware - Workspace SA"
PROJECT_ID_FILE="$HOME/workspace-sa-project-id.txt"
SA_ID="mw-groups"
SA_DISPLAY="Middleware Groups (Workspace service account)"
SA_DESC="Dedicated service account for andrew-middleware groups.* actions (Admin SDK, domain-wide delegation, group-member scope only). Created by workspace-sa-deposit.sh Nov 2026."
ADMIN_API="admin.googleapis.com"
DWD_SCOPE="https://www.googleapis.com/auth/admin.directory.group.member"
STATE="$HOME/.workspace-sa-deposit.state"
ADMIN_EMAIL_FILE="$HOME/workspace-admin-email.txt"
CF_TOKEN_FILE="$HOME/cloudflare-api-token.txt"
CF_API="https://api.cloudflare.com/client/v4"
STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"

say()  { echo "$*"; }
step() { echo "step $1: $2"; }
stop() { echo "step $1: – skipped ($2)"; echo "result: STOPPED — $2"; exit 1; }
impossible() { echo "flag: IMPOSSIBLE: $1"; echo "result: STOPPED — $1"; exit 3; }
pace() { sleep $(( $1 + RANDOM % 15 )); }

touch "$STATE" 2>/dev/null || true
have() { grep -q "^$1=1$" "$STATE" 2>/dev/null; }
mark() { grep -q "^$1=" "$STATE" 2>/dev/null || echo "$1=1" >> "$STATE"; }

API_STATUS_FILE="$(mktemp)"; API_BODY_FILE="$(mktemp)"
api() { # method url [json-body]; body -> $API_BODY_FILE, status -> $API_STATUS_FILE
  # Runs in the caller's shell (no command substitution), so plain
  # files are used to hand status/body back, per the play-api
  # precedent's note about subshells.
  local method="$1" url="$2" body="${3:-}" out
  if [ -n "$body" ]; then
    out="$(curl -sS -w $'\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$body" "$url" 2>/dev/null)" || out=""
  else
    out="$(curl -sS -w $'\n%{http_code}' -X "$method" \
      -H "Authorization: Bearer $TOKEN" "$url" 2>/dev/null)" || out=""
  fi
  if [ -z "$out" ]; then printf '000' > "$API_STATUS_FILE"; : > "$API_BODY_FILE"; return; fi
  printf '%s' "$out" | tail -1 > "$API_STATUS_FILE"
  printf '%s' "$out" | sed '$d' > "$API_BODY_FILE"
}
api_read() { API_STATUS="$(cat "$API_STATUS_FILE")"; RESP="$(cat "$API_BODY_FILE")"; }

json_get() { # $1 = dotted-ish key to extract from $RESP via python (small fields only)
  RESP="$RESP" KEY="$1" python3 - <<'PYEOF' 2>/dev/null || true
import json, os
try:
    data = json.loads(os.environ["RESP"])
    cur = data
    for part in os.environ["KEY"].split("."):
        cur = cur[part]
    print(cur)
except Exception:
    pass
PYEOF
}

poll_operation() { # $1 = operation name (operations/... or projects/.../operations/...)
  # Polls a Google long-running operation until done; returns 0/1.
  local op="$1" i
  for i in $(seq 1 15); do
    pace 12
    api GET "https://cloudresourcemanager.googleapis.com/v1/$op"; api_read
    if [ "$API_STATUS" = "200" ] && printf '%s' "$RESP" | grep -q '"done": *true'; then
      if printf '%s' "$RESP" | grep -q '"error"'; then return 1; fi
      return 0
    fi
  done
  return 1
}

main() {
say "job: workspace-sa-deposit.sh"
say "started: $STARTED_AT"
say "target worker: $WORKER_NAME"

# ---------- preflight: tools ----------
command -v curl >/dev/null 2>&1 || impossible "curl not found on phone"
command -v python3 >/dev/null 2>&1 || impossible "python3 not found on phone (pkg install python)"
step tools "✓ applied (curl + python3 present)"

# ---------- preflight: on-device inputs (fail BEFORE any create) ----------
if [ -s "$ADMIN_EMAIL_FILE" ]; then
  ADMIN_EMAIL="$(head -1 "$ADMIN_EMAIL_FILE" | tr -d '[:space:]')"
  case "$ADMIN_EMAIL" in
    *@*.*) : ;;
    *) stop admin-email "file $ADMIN_EMAIL_FILE exists but its first line is not an email address — fix the file (one line: the Workspace admin email the service account will impersonate) and re-run" ;;
  esac
  step admin-email-file "✓ applied (admin email read from $ADMIN_EMAIL_FILE; value not printed)"
else
  stop admin-email "missing input file — create it once with:  printf '%s' 'YOUR-ADMIN-EMAIL' > ~/workspace-admin-email.txt && chmod 600 ~/workspace-admin-email.txt  — then re-run this script"
fi

if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  CF_TOKEN="$CLOUDFLARE_API_TOKEN"
  step cf-token "✓ applied (Cloudflare token from environment)"
elif [ -s "$CF_TOKEN_FILE" ]; then
  CF_TOKEN="$(tr -d '[:space:]' < "$CF_TOKEN_FILE")"
  step cf-token "✓ applied (Cloudflare token read from $CF_TOKEN_FILE; value not printed)"
else
  stop cf-token "no Cloudflare API token available — either export CLOUDFLARE_API_TOKEN in this session, or save the token (one line, Workers Scripts Edit on the account) to ~/cloudflare-api-token.txt with chmod 600 — then re-run"
fi
CF_VERIFY="$(curl -sS "$CF_API/user/tokens/verify" -H "Authorization: Bearer $CF_TOKEN" 2>/dev/null)"
if ! printf '%s' "$CF_VERIFY" | grep -q '"status": *"active"'; then
  stop cf-token "Cloudflare token did not verify as active — check the token file/value and re-run (nothing was created)"
fi
step cf-token-verify "✓ applied (Cloudflare token verified active)"

# ---------- auth: get a Google OAuth access token (play-api paths) ----------
TOKEN=""
if command -v gcloud >/dev/null 2>&1; then
  ACCT="$(gcloud config get-value account 2>/dev/null | head -1)"
  if [ -n "$ACCT" ] && [ "$ACCT" != "(unset)" ]; then
    TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
    [ -n "$TOKEN" ] && say "auth: via gcloud (account name not logged)"
  fi
fi
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
[ -n "$TOKEN" ] || impossible "no Google auth path on phone (no gcloud session, no firebase login) — sign in once (gcloud or firebase) in Termux, then re-run"

# ---------- Cloudflare: find the account that holds the Worker ----------
CF_ACCOUNT_ID=""
ACCOUNTS_JSON="$(curl -sS "$CF_API/accounts?per_page=50" -H "Authorization: Bearer $CF_TOKEN" 2>/dev/null)"
ACCT_IDS="$(printf '%s' "$ACCOUNTS_JSON" | ACCOUNTS_JSON="$ACCOUNTS_JSON" python3 -c '
import json, os
try:
    data = json.loads(os.environ["ACCOUNTS_JSON"])
    print("\n".join(a["id"] for a in data.get("result", [])))
except Exception:
    pass' 2>/dev/null)"
[ -n "$ACCT_IDS" ] || stop cf-account "Cloudflare account list came back empty/unreadable — token may lack account read; nothing was created"
MATCHES=0
for aid in $ACCT_IDS; do
  W_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "$CF_API/accounts/$aid/workers/scripts/$WORKER_NAME" -H "Authorization: Bearer $CF_TOKEN" 2>/dev/null)"
  if [ "$W_CODE" = "200" ]; then
    CF_ACCOUNT_ID="$aid"; MATCHES=$((MATCHES+1))
  fi
done
[ "$MATCHES" = "1" ] || stop cf-account "expected exactly one Cloudflare account holding worker $WORKER_NAME, found $MATCHES — STOP; Muse reviews before anything is created"
SECRETS_URL="$CF_API/accounts/$CF_ACCOUNT_ID/workers/scripts/$WORKER_NAME/secrets"
step cf-account "✓ applied (worker $WORKER_NAME located; account id not printed)"

cf_secret_names() {
  curl -sS "$SECRETS_URL" -H "Authorization: Bearer $CF_TOKEN" 2>/dev/null | \
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print("\n".join(s["name"] for s in data.get("result", [])))
except Exception:
    pass' 2>/dev/null
}
cf_put_secret_from_file() { # $1 = secret name, $2 = file whose CONTENTS are the value
  local name="$1" src="$2" bodyfile resp
  bodyfile="$(mktemp)"; chmod 600 "$bodyfile"
  SECRET_NAME="$name" SRC_FILE="$src" BODY_FILE="$bodyfile" python3 - <<'PYEOF'
import json, os
with open(os.environ["SRC_FILE"], "r", encoding="utf-8") as f:
    value = f.read()
if os.environ["SECRET_NAME"] == "WORKSPACE_ADMIN_EMAIL":
    value = value.strip().splitlines()[0].strip()
body = {"name": os.environ["SECRET_NAME"], "text": value, "type": "secret_text"}
with open(os.environ["BODY_FILE"], "w", encoding="utf-8") as f:
    json.dump(body, f)
PYEOF
  resp="$(curl -sS -X PUT "$SECRETS_URL" -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" --data "@$bodyfile" 2>/dev/null)"
  shred -u "$bodyfile" 2>/dev/null || rm -f "$bodyfile"
  printf '%s' "$resp" | grep -q '"success": *true'
}

# Snapshot of the Worker's current secret NAMES (never values).
NAMES_BEFORE="$(cf_secret_names)"
if printf '%s\n' "$NAMES_BEFORE" | grep -qx "GCP_WORKSPACE_SA_KEY"; then SA_KEY_SET=1; else SA_KEY_SET=0; fi
if printf '%s\n' "$NAMES_BEFORE" | grep -qx "WORKSPACE_ADMIN_EMAIL"; then ADMIN_EMAIL_SET=1; else ADMIN_EMAIL_SET=0; fi
say "worker secrets before: GCP_WORKSPACE_SA_KEY set=$([ $SA_KEY_SET = 1 ] && echo true || echo false), WORKSPACE_ADMIN_EMAIL set=$([ $ADMIN_EMAIL_SET = 1 ] && echo true || echo false)"

# ---------- the project: reuse or ONE create ----------
PROJECT="$PROJECT_ID_DEFAULT"
if [ -s "$PROJECT_ID_FILE" ]; then
  CAND="$(head -1 "$PROJECT_ID_FILE" | tr -d '[:space:]')"
  case "$CAND" in
    [a-z][a-z0-9-]*)
      if [ ${#CAND} -ge 6 ] && [ ${#CAND} -le 30 ]; then PROJECT="$CAND"; fi ;;
  esac
fi
say "project: $PROJECT"
api GET "https://cloudresourcemanager.googleapis.com/v1/projects/$PROJECT"; api_read
if [ "$API_STATUS" = "200" ]; then
  step project "✓ already (project $PROJECT exists and is visible to the signed-in account)"
  mark PROJECT_OK
elif [ "$API_STATUS" = "404" ]; then
  pace 30
  api POST "https://cloudresourcemanager.googleapis.com/v1/projects" \
    "{\"projectId\":\"$PROJECT\",\"name\":\"$PROJECT_NAME\"}"; api_read
  OP_NAME="$(json_get name)"
  case "$OP_NAME" in
    operations/*) : ;;
    *)
      echo "create response: HTTP $API_STATUS"; echo "$RESP" | head -c 500; echo
      stop project "project create did not start (HTTP $API_STATUS) — STOP per pacing rule; no second project ID will be tried. Common cause: project quota on the account — the fix is Andrew designating an existing project in ~/workspace-sa-project-id.txt, decided with Muse, not a script retry" ;;
  esac
  if poll_operation "$OP_NAME"; then
    step project "✓ applied (created project $PROJECT — the one and only create)"
    mark PROJECT_OK
  else
    echo "$RESP" | head -c 500; echo
    stop project "project create operation did not complete cleanly — STOP; Muse diagnoses from this log before any further step"
  fi
else
  echo "project check: HTTP $API_STATUS"; echo "$RESP" | head -c 400; echo
  stop project "project check failed (HTTP $API_STATUS) — cannot verify state; STOP"
fi
pace 20

# ---------- enable the Admin SDK API ----------
api GET "https://serviceusage.googleapis.com/v1/projects/$PROJECT/services/$ADMIN_API"; api_read
if printf '%s' "$RESP" | grep -q '"state": *"ENABLED"'; then
  step admin-api "✓ already ($ADMIN_API enabled on $PROJECT)"
  mark API_OK
elif [ "$API_STATUS" = "200" ] || [ "$API_STATUS" = "404" ]; then
  pace 30
  api POST "https://serviceusage.googleapis.com/v1/projects/$PROJECT/services/$ADMIN_API:enable" '{}'; api_read
  SU_OP="$(json_get name)"
  ENABLED=0
  case "$SU_OP" in
    projects/*/operations/*|operations/*)
      for i in $(seq 1 15); do
        pace 12
        api GET "https://serviceusage.googleapis.com/v1/$SU_OP"; api_read
        if [ "$API_STATUS" = "200" ] && printf '%s' "$RESP" | grep -q '"done": *true'; then ENABLED=1; break; fi
      done ;;
  esac
  if [ "$ENABLED" = "1" ]; then
    api GET "https://serviceusage.googleapis.com/v1/projects/$PROJECT/services/$ADMIN_API"; api_read
    if printf '%s' "$RESP" | grep -q '"state": *"ENABLED"'; then
      step admin-api "✓ applied ($ADMIN_API enabled on $PROJECT)"
      mark API_OK
    else
      stop admin-api "enable operation finished but the service does not read ENABLED (HTTP $API_STATUS) — STOP; Muse reviews"
    fi
  else
    echo "$RESP" | head -c 400; echo
    stop admin-api "API enable did not complete (HTTP $API_STATUS) — STOP per pacing rule"
  fi
else
  stop admin-api "service state check failed (HTTP $API_STATUS) — cannot verify state; STOP"
fi
pace 20

# ---------- the service account ----------
SA_EMAIL="$SA_ID@$PROJECT.iam.gserviceaccount.com"
api GET "https://iam.googleapis.com/v1/projects/$PROJECT/serviceAccounts/$SA_EMAIL"; api_read
if [ "$API_STATUS" = "200" ]; then
  step service-account "✓ already ($SA_EMAIL exists)"
  mark SA_OK
elif [ "$API_STATUS" = "404" ]; then
  pace 30
  api POST "https://iam.googleapis.com/v1/projects/$PROJECT/serviceAccounts" \
    "{\"accountId\":\"$SA_ID\",\"serviceAccount\":{\"displayName\":\"$SA_DISPLAY\",\"description\":\"$SA_DESC\"}}"; api_read
  if [ "$API_STATUS" = "200" ] || [ "$API_STATUS" = "201" ]; then
    step service-account "✓ applied (created $SA_EMAIL)"
    mark SA_OK
  else
    echo "create failed: HTTP $API_STATUS"; echo "$RESP" | head -c 500; echo
    stop service-account "service-account create failed (HTTP $API_STATUS) — STOP per pacing rule; Muse diagnoses before any retry"
  fi
else
  echo "describe failed: HTTP $API_STATUS"; echo "$RESP" | head -c 400; echo
  stop service-account "service-account describe failed (HTTP $API_STATUS) — cannot verify state; STOP"
fi
# Read back the numeric client ID (uniqueId) — an identifier, not a secret.
pace 15
api GET "https://iam.googleapis.com/v1/projects/$PROJECT/serviceAccounts/$SA_EMAIL"; api_read
SA_CLIENT_ID="$(json_get uniqueId)"
[ -n "$SA_CLIENT_ID" ] || stop service-account "could not read back the SA uniqueId (client ID) — STOP; the delegation step needs it"
step sa-client-id "✓ applied (client ID read back)"

# ---------- the key + Worker secret deposit ----------
if [ "$SA_KEY_SET" = "1" ]; then
  step sa-key-secret "✓ already (GCP_WORKSPACE_SA_KEY present on worker $WORKER_NAME — no new key minted)"
  mark KEY_OK
elif have KEY_OK; then
  stop sa-key-secret "checkpoint says a key was already deposited, but GCP_WORKSPACE_SA_KEY is not in the Worker's secret list — needs Muse review before any new key is minted"
else
  # Count existing user-managed keys first (read-only): a leftover
  # key with no checkpoint means a previous partial run — stop.
  api GET "https://iam.googleapis.com/v1/projects/$PROJECT/serviceAccounts/$SA_EMAIL/keys"; api_read
  KEY_COUNT="$(RESP="$RESP" python3 -c '
import json, os
try:
    data = json.loads(os.environ["RESP"])
    print(sum(1 for k in data.get("keys", []) if k.get("keyType") == "USER_MANAGED"))
except Exception:
    print(-1)' 2>/dev/null)"
  if [ "$KEY_COUNT" != "0" ]; then
    stop sa-key-secret "service account already has $KEY_COUNT user-managed key(s) but the Worker secret is unset and no checkpoint exists — a previous partial run is possible; STOP, Muse reviews before another key is minted"
  fi
  pace 45
  TMPKEY="$(mktemp "$HOME/.workspace-sa-key.XXXXXX.json")"
  chmod 600 "$TMPKEY"
  api POST "https://iam.googleapis.com/v1/projects/$PROJECT/serviceAccounts/$SA_EMAIL/keys" \
    '{"privateKeyType":"TYPE_GOOGLE_CREDENTIALS_FILE","keyAlgorithm":"KEY_ALG_RSA_2048"}'; api_read
  if [ "$API_STATUS" != "200" ] && [ "$API_STATUS" != "201" ]; then
    rm -f "$TMPKEY"
    echo "key create failed: HTTP $API_STATUS"; echo "$RESP" | head -c 400; echo
    stop key "key create failed (HTTP $API_STATUS) — STOP; no key material written"
  fi
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
    stop key "minted key payload did not decode as JSON — temp files removed; STOP"
  fi
  rm -f "$RESP_FILE"
  step key "✓ applied (one key minted into a phone-only temp file)"
  pace 20
  if cf_put_secret_from_file "GCP_WORKSPACE_SA_KEY" "$TMPKEY"; then
    step sa-key-secret "✓ applied (GCP_WORKSPACE_SA_KEY deposited on worker $WORKER_NAME)"
  else
    shred -u "$TMPKEY" 2>/dev/null || rm -f "$TMPKEY"
    stop sa-key-secret "Cloudflare secret deposit failed — temp key shredded; STOP (the minted key is now orphaned on the SA; tell Muse, who will have it deleted before any new mint)"
  fi
  shred -u "$TMPKEY" 2>/dev/null || rm -f "$TMPKEY"
  NAMES_NOW="$(cf_secret_names)"
  if printf '%s\n' "$NAMES_NOW" | grep -qx "GCP_WORKSPACE_SA_KEY"; then
    step sa-key-verify "✓ applied (GCP_WORKSPACE_SA_KEY verified by name on the Worker; temp key shredded)"
    mark KEY_OK
  else
    stop sa-key-verify "deposit reported success but the secret is not in the Worker's list — needs Muse review; do NOT re-run blindly"
  fi
fi

# ---------- WORKSPACE_ADMIN_EMAIL deposit ----------
if [ "$ADMIN_EMAIL_SET" = "1" ]; then
  step admin-email-secret "✓ already (WORKSPACE_ADMIN_EMAIL present on worker $WORKER_NAME)"
  mark EMAIL_OK
else
  pace 20
  if cf_put_secret_from_file "WORKSPACE_ADMIN_EMAIL" "$ADMIN_EMAIL_FILE"; then
    NAMES_NOW="$(cf_secret_names)"
    if printf '%s\n' "$NAMES_NOW" | grep -qx "WORKSPACE_ADMIN_EMAIL"; then
      step admin-email-secret "✓ applied (WORKSPACE_ADMIN_EMAIL deposited and verified by name; value not printed)"
      mark EMAIL_OK
    else
      stop admin-email-secret "deposit reported success but the secret is not in the Worker's list — needs Muse review"
    fi
  else
    stop admin-email-secret "Cloudflare deposit of WORKSPACE_ADMIN_EMAIL failed — STOP; Muse reviews"
  fi
fi

# ---------- delegation instructions (Andrew's human step) ----------
say ""
say "=================================================================="
say "YOUR NEXT STEP (Admin console — only you can do this):"
say "  1. Open admin.google.com signed in as the Workspace admin."
say "  2. Security -> Access and data control -> API controls"
say "     -> Domain-wide delegation -> Add new."
say "  3. Client ID:  $SA_CLIENT_ID"
say "     OAuth scope: $DWD_SCOPE"
say "  4. Authorize. That one scope only — group membership only."
say "Until this is done, the middleware's groups.* calls will fail"
say "Google-side even though both Worker secrets are set. After it,"
say "tell Muse — the groups.get verification read is Muse's step."
say "=================================================================="
say ""
say "summary booleans:"
say "  project_ok: true"
say "  admin_api_enabled: true"
say "  service_account_ok: true"
say "  sa_client_id: $SA_CLIENT_ID"
say "  gcp_workspace_sa_key_set: true"
say "  workspace_admin_email_set: true"
say "result: SUCCESS (service account ready; both Worker secrets deposited and verified by name; values never printed)"
exit 0
}

# Run main with output captured so a results log can be written in
# the owner-queue format (header + captured output) when the
# fleet-kit checkout is discoverable. Under the owner loop, the
# loop writes its own results/<job>.log from the same stdout.
CAPTURE="$(mktemp)"
main 2>&1 | tee "$CAPTURE"
RC="${PIPESTATUS[0]}"
RESULTS_DIR=""
if [ -d "owner-queue/results" ]; then
  RESULTS_DIR="owner-queue/results"
elif [ -d "$(dirname "$0")/../../owner-queue/results" ]; then
  RESULTS_DIR="$(dirname "$0")/../../owner-queue/results"
fi
if [ -n "$RESULTS_DIR" ]; then
  LOG="$RESULTS_DIR/workspace-sa-deposit.sh.log"
  {
    echo "job: workspace-sa-deposit.sh"
    echo "started: $STARTED_AT"
    echo "finished: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "exit code: $RC"
    echo ""
    cat "$CAPTURE"
  } > "$LOG" 2>/dev/null || true
fi
rm -f "$CAPTURE" "$API_STATUS_FILE" "$API_BODY_FILE"
exit "$RC"
