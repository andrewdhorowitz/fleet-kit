#!/usr/bin/env bash
# cf-token-converge.sh — owner-run in Termux.
#
# Prompts ONCE for a Cloudflare API token (hidden input), then sets it as
# the CF_API_TOKEN GitHub Actions secret in fleet-kit. Re-running simply
# replaces the secret — safe to run any time the token rotates.
#
# WHY THIS TOKEN EXISTS: the text-bridge-worker-secrets workflow needs a
# Cloudflare credential so it can set Worker secrets (it hands the
# FIREBASE_SERVICE_ACCOUNT_JSON Actions secret to the text-bridge-receiver
# Worker). Muse's own Cloudflare token cannot be extracted from its vault
# for this, so this dedicated token lives as a fleet-kit Actions secret.
#
# INTENDED TOKEN SCOPE (create it exactly this narrow):
#   Account · Workers Scripts · Edit
#   — nothing else. It can edit Worker scripts/secrets in the account and
#   cannot touch DNS, zones, Pages, or billing.
#
# The token lives only in memory for this run: it is never echoed, logged,
# written to disk, or committed. Verification reads secret METADATA only
# (name + updated timestamp), never the value.
set -u

REPO="andrewdhorowitz/fleet-kit"
SECRET_NAME="CF_API_TOKEN"

printf "Paste your Cloudflare API token (input hidden), then Enter: "
read -rs TOKEN
echo

if [ -z "${TOKEN:-}" ]; then
  echo "No token entered — nothing changed."
  exit 1
fi

if gh secret set "$SECRET_NAME" --repo "$REPO" --body "$TOKEN" >/dev/null 2>&1; then
  echo "✓ $REPO — $SECRET_NAME set"
else
  echo "✗ $REPO — FAILED (check gh auth / access)"
  unset TOKEN
  exit 1
fi

unset TOKEN

# Verify by metadata only: gh secret list prints name + updated timestamp,
# never values.
meta="$(gh secret list --repo "$REPO" 2>/dev/null | grep "^${SECRET_NAME}[[:space:]]" || true)"
if [ -n "$meta" ]; then
  echo "✓ verified in secret list: $meta"
else
  echo "✗ $SECRET_NAME set but not found in secret list — check the repo's Actions secrets."
  exit 1
fi

echo "Done."
