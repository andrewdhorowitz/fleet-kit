#!/usr/bin/env bash
# 20261106-2126-fb-play-sa-deposit.sh — owner-queue job (queued by
# Muse, 2026-11-06, after Andrew approved by tapping "Queue the
# secret deposit to my owner loop" in the main chat at 21:25 ET).
#
# PURPOSE: deposit ONE Actions secret on repo
# andrewdhorowitz/family-board:
#   PLAY_SERVICE_ACCOUNT_JSON
# The Family Board TV app's .github/workflows/android.yml publishes
# to the Play internal track via Gradle Play Publisher and reads
# exactly this secret name; its four FB_KEYSTORE_* secrets are
# already deposited. Nothing else is touched: no other repos, no
# other secrets.
#
# SHAPE: the Play service-account half of
# owner-queue/done/rs-secrets-deposit.sh (the Nov 6, 2026 Routines
# deposit, exit 0), same mechanics: the play-publisher SA JSON is
# discovered on the phone by glob (newest play-publisher-513614-*.json
# across ~/storage/downloads, ~/Downloads, ~), shape-validated
# without printing values, and set with the phone's gh CLI.
#
# SECRECY: the key value lives only in the file the phone already
# holds and in gh's stdin — never printed, never written anywhere
# new, never committed. This job's output (which the loop commits
# to owner-queue/results/) carries the secret NAME and verdicts only.
#
# CONTRACT: non-interactive, idempotent — if the secret is already
# present it is reported "✓ already" and left untouched. Fails
# closed: any step that cannot complete names its reason in the
# summary and the job exits nonzero.

set -u

TARGET_REPO="andrewdhorowitz/family-board"
SA_GLOB="play-publisher-513614-*.json"

now_et() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S %Z'; }

echo "job: 20261106-2126-fb-play-sa-deposit.sh"
echo "started: $(now_et)"
echo "target repo: $TARGET_REPO"

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR" 2>/dev/null || true
cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then rm -rf "$WORKDIR"; fi
}
trap cleanup EXIT

OUTCOME="not attempted"

# --- step 0: gh present + authed -----------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "step gh: FAILED (gh CLI not found on this device)"
  echo "result: FAILED (gh CLI missing — nothing deposited)"
  echo "finished: $(now_et)"
  exit 1
fi
if ! gh auth status >/dev/null 2>"$WORKDIR/ghauth.err"; then
  echo "step gh: FAILED (gh is present but not authenticated)"
  echo "result: FAILED (gh not authed — nothing deposited)"
  echo "finished: $(now_et)"
  exit 1
fi
echo "step gh: ✓ applied (gh CLI present and authenticated)"

secret_present() { # $1 = secret name; names only, never values
  gh secret list --repo "$TARGET_REPO" 2>/dev/null \
    | grep -q "^$1[[:space:]]"
}

# --- step 1: Play service-account deposit ---------------------------
SA_OK=0
if secret_present "PLAY_SERVICE_ACCOUNT_JSON"; then
  OUTCOME="✓ already (present on $TARGET_REPO)"
  SA_OK=1
  echo "step play-sa: ✓ already (PLAY_SERVICE_ACCOUNT_JSON present on $TARGET_REPO — nothing to deposit)"
else
  # Same discovery as rs-secrets-deposit.sh: the newest glob match,
  # searched across the shared-storage Downloads bridge first (where
  # the earlier deposits found play-publisher-513614-*.json), then
  # ~/Downloads, then $HOME.
  newest=""
  for dir in "$HOME/storage/downloads" "$HOME/Downloads" "$HOME"; do
    [[ -d "$dir" ]] || continue
    for f in "$dir"/$SA_GLOB; do
      [[ -e "$f" ]] || continue
      if [[ -z "$newest" || "$f" -nt "$newest" ]]; then newest="$f"; fi
    done
  done
  if [[ -z "$newest" ]]; then
    OUTCOME="not set (SA key file not found on phone)"
    echo "step play-sa: – skipped (PLAY_SERVICE_ACCOUNT_JSON not set: SA key file not found on phone — no $SA_GLOB in ~/storage/downloads, ~/Downloads, or ~)"
  else
    SA_FILE="$newest"
    # Validate shape only (service-account JSON with the two fields
    # the key must carry). Field VALUES are never printed.
    if ! python3 - "$SA_FILE" <<'PY' >/dev/null 2>&1
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if d.get("type") != "service_account":
    sys.exit(1)
if not d.get("client_email") or "PRIVATE KEY" not in (d.get("private_key") or ""):
    sys.exit(1)
PY
    then
      OUTCOME="not set (candidate file found but it is not a valid service-account JSON)"
      echo "step play-sa: – skipped (PLAY_SERVICE_ACCOUNT_JSON not set: a $SA_GLOB file was found but is not a valid service-account JSON — refusing to deposit it)"
    elif ! gh secret set PLAY_SERVICE_ACCOUNT_JSON --repo "$TARGET_REPO" < "$SA_FILE" \
        2>"$WORKDIR/gh5.err"; then
      OUTCOME="FAILED (gh secret set failed)"
      echo "step play-sa: FAILED (gh secret set PLAY_SERVICE_ACCOUNT_JSON failed)"
    elif secret_present "PLAY_SERVICE_ACCOUNT_JSON"; then
      OUTCOME="✓ applied (set on $TARGET_REPO; verified in the secret list)"
      SA_OK=1
      echo "step play-sa: ✓ applied (PLAY_SERVICE_ACCOUNT_JSON set from the play-publisher SA JSON found on the phone; verified by name)"
    else
      OUTCOME="FAILED (set was attempted but the name did not appear in gh secret list)"
      echo "step play-sa: FAILED (PLAY_SERVICE_ACCOUNT_JSON did not appear in gh secret list after set)"
    fi
  fi
fi

# --- summary ---------------------------------------------------------
echo "summary (names + status only; no values were printed or stored):"
echo "  PLAY_SERVICE_ACCOUNT_JSON: $OUTCOME"

if [[ $SA_OK -eq 1 ]]; then
  echo "result: SUCCESS (PLAY_SERVICE_ACCOUNT_JSON present on $TARGET_REPO)"
  echo "finished: $(now_et)"
  exit 0
fi
echo "result: FAILED (deposit incomplete — see summary lines above for the named reason)"
echo "finished: $(now_et)"
exit 1
