#!/usr/bin/env bash
# Smart Home secrets deposit (queued by Muse 2026-11-11, Andrew's word).
#
# What this job does, on Andrew's phone:
#   1. Finds the homegraph-reporter service-account JSON key Andrew
#      downloaded from Google Cloud Console (matched by CONTENT, never
#      printed — not its contents, not a fragment).
#   2. Sets it as the fleet-kit Actions secret GOOGLE_HOME_SA_JSON.
#   3. Generates the SMART_HOME_LINK_CODE on-device (or reuses the one
#      already on the device), saves it ONLY to ~/smarthome-link-code.txt
#      (chmod 600, outside this repo — Andrew reads it there when he
#      links in Google Home), and sets it as a fleet-kit Actions secret.
#   4. Dispatches the text-bridge-worker-secrets workflow, which hands
#      both secrets to the text-bridge-receiver Worker, and watches the
#      run so this log carries the verified outcome.
# Idempotent: gh secret set overwrites; safe to re-run end to end.
set -uo pipefail

REPO="andrewdhorowitz/fleet-kit"
FAIL=0

echo "== Smart Home secrets deposit =="

# 1) gh sanity
if ! gh auth status >/dev/null 2>&1; then
  echo "✗ gh is not authenticated on this device — run 'gh auth login' first, then ask Muse to re-queue"
  exit 1
fi
echo "✓ gh authenticated"

# 2) Locate the SA key JSON by content (name-agnostic, value never shown)
KEY=""
for dir in "$HOME/Downloads" "$HOME" \
           /storage/emulated/0/Download /storage/emulated/0/Downloads \
           /storage/emulated/0/Documents \
           "/storage/emulated/0/Android/data/com.android.chrome/files/Download"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    if grep -q '"type": *"service_account"' "$f" \
       && grep -q 'homegraph' "$f" \
       && grep -q '@family-routines-app.iam.gserviceaccount.com' "$f"; then
      KEY="$f"
      break 2
    fi
  done
done
if [ -z "$KEY" ]; then
  echo "✗ homegraph-reporter key JSON not found in any folder this job can read."
  echo "  Likely cause: Chrome's downloads live in its app-private folder, which Termux cannot read."
  echo "  Fix: Chrome → Downloads → the key file → Share → save it into the shared Download folder,"
  echo "  then ask Muse to re-queue this job."
  exit 1
fi
echo "✓ found the SA key file (contents not shown)"

# 3) Deposit the SA JSON as an Actions secret
if gh secret set GOOGLE_HOME_SA_JSON --repo "$REPO" < "$KEY"; then
  echo "✓ GOOGLE_HOME_SA_JSON set in fleet-kit Actions secrets"
else
  echo "✗ gh secret set GOOGLE_HOME_SA_JSON failed"
  FAIL=1
fi

# 4) Link code: reuse the device copy if one exists, else generate here
CODE_FILE="$HOME/smarthome-link-code.txt"
if [ -s "$CODE_FILE" ]; then
  echo "✓ link code already saved on this device (reusing; value not shown)"
else
  LC="$(head -c 64 /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 20)"
  printf '%s' "$LC" > "$CODE_FILE"
  chmod 600 "$CODE_FILE"
  unset LC
  echo "✓ link code generated; saved only to ~/smarthome-link-code.txt (read it there when linking; value not shown)"
fi
if gh secret set SMART_HOME_LINK_CODE --repo "$REPO" < "$CODE_FILE"; then
  echo "✓ SMART_HOME_LINK_CODE set in fleet-kit Actions secrets"
else
  echo "✗ gh secret set SMART_HOME_LINK_CODE failed"
  FAIL=1
fi

# 5) Hand both secrets to the Worker via the workflow, and watch it
if [ "$FAIL" -eq 0 ]; then
  if gh workflow run text-bridge-worker-secrets.yml --repo "$REPO"; then
    echo "✓ worker-secrets workflow dispatched"
    sleep 10
    RUN_ID="$(gh run list --repo "$REPO" --workflow text-bridge-worker-secrets.yml --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
    if [ -n "${RUN_ID:-}" ] && [ "$RUN_ID" != "null" ]; then
      if gh run watch "$RUN_ID" --repo "$REPO" --exit-status >/dev/null 2>&1; then
        echo "✓ workflow run $RUN_ID succeeded — both secrets are set on the Worker"
      else
        echo "✗ workflow run $RUN_ID did not succeed — check the Actions tab for text-bridge-worker-secrets"
        FAIL=1
      fi
    else
      echo "– could not read back the workflow run id; check the Actions tab to confirm the hand-off"
    fi
  else
    echo "✗ workflow dispatch failed"
    FAIL=1
  fi
fi

exit "$FAIL"
