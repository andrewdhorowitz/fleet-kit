#!/usr/bin/env bash
# Family Board — Stage 3 OAuth secret deposit (PREPARED, NOT RUN by Muse)
#
# Purpose: deposit the Family Board Google OAuth client ID and client secret
# as Worker secrets (GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET)
# on the existing text-bridge-receiver Cloudflare Worker, so the Stage 3
# server OAuth flow can use them without Muse ever seeing the values.
#
# Run by: Andrew ONLY, on his own phone in Termux, after creating the Web
# OAuth client in the Google Cloud console (see stage-3-owner-steps-2026-11-09.md).
#
# Guarantees: no secret value is ever printed, echoed, or logged by this
# script. The client secret and the Cloudflare API token are read with
# hidden input (read -s). Verification at the end lists secret NAMES only.
#
# Requires: curl (standard in Termux). Uses jq if available to build/parse
# JSON; falls back to python3 if jq is missing.

set -eu

ACCOUNT_ID="2e2d28cfd77d3c1215cbe512c7fd2733"
WORKER_NAME="text-bridge-receiver"
SECRETS_URL="https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/secrets"

echo "Family Board — Stage 3 OAuth secret deposit"
echo "Target Worker: ${WORKER_NAME}"
echo "Nothing you type for the secret / token prompts will be shown."
echo

# --- Prompts ---------------------------------------------------------------
printf "OAuth client ID: "
read -r OAUTH_CLIENT_ID

printf "OAuth client secret (hidden): "
read -rs OAUTH_CLIENT_SECRET
echo

printf "Cloudflare API token with Workers Scripts Edit permission (hidden): "
read -rs CF_API_TOKEN
echo
echo

if [ -z "${OAUTH_CLIENT_ID}" ] || [ -z "${OAUTH_CLIENT_SECRET}" ] || [ -z "${CF_API_TOKEN}" ]; then
  echo "ERROR: one of the three inputs was empty — nothing was sent. Re-run the script." >&2
  exit 1
fi

# --- Helpers ---------------------------------------------------------------
# Build the JSON body for one secret without printing the value anywhere.
# $1 = secret name, $2 = secret value (passed to the JSON tool, never echoed).
json_body() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg name "$1" --arg text "$2" \
      '{name: $name, text: $text, type: "secret_text"}'
  elif command -v python3 >/dev/null 2>&1; then
    SECRET_NAME="$1" SECRET_TEXT="$2" python3 -c \
      'import json, os; print(json.dumps({"name": os.environ["SECRET_NAME"], "text": os.environ["SECRET_TEXT"], "type": "secret_text"}))'
  else
    echo "ERROR: need jq or python3 to build JSON safely. Install one in Termux (pkg install jq) and re-run." >&2
    exit 1
  fi
}

# Succeed only if the API response says "success": true (value never shown).
check_success() {
  if printf '%s' "$1" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    return 0
  fi
  echo "ERROR: Cloudflare did not confirm success. Response was:" >&2
  printf '%s\n' "$1" >&2
  return 1
}

put_secret() {
  # $1 = secret name, $2 = secret value
  body="$(json_body "$1" "$2")"
  response="$(curl -sS -X PUT "${SECRETS_URL}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "${body}")"
  check_success "${response}"
  echo "Deposited secret: $1"
}

# --- Deposit the two secrets ----------------------------------------------
put_secret "GOOGLE_OAUTH_CLIENT_ID" "${OAUTH_CLIENT_ID}"
put_secret "GOOGLE_OAUTH_CLIENT_SECRET" "${OAUTH_CLIENT_SECRET}"

# --- Verify: list secret NAMES only (the list API never returns values) ---
echo
echo "Verifying — secret names currently on ${WORKER_NAME}:"
list_response="$(curl -sS -X GET "${SECRETS_URL}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}")"
check_success "${list_response}"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "${list_response}" | jq -r '.result[] | .name'
elif command -v python3 >/dev/null 2>&1; then
  printf '%s' "${list_response}" | python3 -c \
    'import json, sys; [print(s["name"]) for s in json.load(sys.stdin)["result"]]'
else
  # Safe fallback: the secrets-list response contains names/types only, no values.
  printf '%s\n' "${list_response}"
fi

# --- Clean up in-memory copies and finish ----------------------------------
unset OAUTH_CLIENT_ID OAUTH_CLIENT_SECRET CF_API_TOKEN

echo
echo "Done. Both secrets are deposited and verified by name above."
echo "You can now REVOKE the Cloudflare API token you created for this run"
echo "(Cloudflare dashboard -> My Profile -> API Tokens). It is not needed again."
