#!/usr/bin/env bash
# show-bridge-token-once.sh — owner-run in Termux (fleet-kit clone).
#
# The Text Bridge token's value is write-only everywhere by design (the
# Worker secret and the fleet-kit secret can be set but never read
# back). So when the phone app needs the token — at install time — this
# script ROTATES it and shows the fresh value exactly once:
#
#   1. generates a fresh strong token (64 hex chars from /dev/urandom),
#   2. sets it as the fleet-kit Actions secret TEXT_BRIDGE_TOKEN,
#   3. dispatches text-bridge-token-sync.yml, which mirrors the same
#      value onto the text-bridge-receiver Worker (via CF_API_TOKEN),
#   4. waits for that run to go green,
#   5. prints the token ONCE, for typing into the app's token field.
#
# Re-running this script rotates the token again: any copy typed into
# the app earlier stops working until the new one is entered. If the
# mirror run fails, the token is NOT printed (it would not work anyway)
# — fix the failure and re-run.
#
# Run from anywhere inside the fleet-kit clone:
#   bash scripts/show-bridge-token-once.sh
set -u

REPO="andrewdhorowitz/fleet-kit"
WORKFLOW="text-bridge-token-sync.yml"

TOKEN="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
if [ -z "${TOKEN:-}" ]; then
  echo "✗ token generation failed — nothing changed."
  exit 1
fi

printf '%s' "$TOKEN" | gh secret set TEXT_BRIDGE_TOKEN --repo "$REPO" >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "✗ could not set the fleet-kit secret (check gh auth / access) — nothing else changed."
  unset TOKEN
  exit 1
fi
echo "✓ fleet-kit secret TEXT_BRIDGE_TOKEN updated"

if ! gh workflow run "$WORKFLOW" --repo "$REPO" >/dev/null 2>&1; then
  echo "✗ could not dispatch $WORKFLOW — the Worker still has the previous token; re-run this script to retry."
  unset TOKEN
  exit 1
fi
echo "✓ mirror workflow dispatched — waiting for it to finish…"
sleep 5

RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
if [ -z "${RUN_ID:-}" ] || ! gh run watch "$RUN_ID" --repo "$REPO" --exit-status >/dev/null 2>&1; then
  echo "✗ mirror run did not finish green (run id: ${RUN_ID:-unknown}) — token NOT shown."
  echo "  Check: gh run view ${RUN_ID:-} --repo $REPO — then re-run this script."
  unset TOKEN
  exit 1
fi
echo "✓ token mirrored onto the text-bridge-receiver Worker"
echo
echo "============================================================"
echo "  Text Bridge token — shown ONCE. Type it into the app now:"
echo
echo "  $TOKEN"
echo
echo "  It will not be shown again. If you lose it, re-run this"
echo "  script — that rotates it and shows the new one once."
echo "============================================================"
unset TOKEN
