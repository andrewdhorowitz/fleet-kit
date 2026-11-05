#!/data/data/com.termux/files/usr/bin/bash
# delete-agent-token.sh — OWNER ONLY, one-off. Deletes the "Cloudflare Agent
# Token - 2026-11-05" USER token (id below) using the admin token read from
# ~/cf-token-admin.txt. Ruled by Andrew 2026-11-05 (the token was silently minted by
# Cloudflare's in-dashboard "Ask AI" assistant; read-only, never expires,
# unused by anything in the fleet).
# Safety: verifies the admin token first, refuses if the target is the admin
# itself, and checks the target's name before deleting.

set -u
TARGET_ID="fdcbddd0e2f5a40e98af01a8afa22e11"
EXPECTED_NAME="Cloudflare Agent Token - 2026-11-05"

if [ ! -f "$HOME/cf-token-admin.txt" ]; then
  echo "No ~/cf-token-admin.txt — run scripts/token-capture.sh first (paste the admin token from 1Password)."
  exit 1
fi
tok=$(tr -d '\r\n ' < "$HOME/cf-token-admin.txt")

self=$(curl -s "https://api.cloudflare.com/client/v4/user/tokens/verify" -H "Authorization: Bearer $tok")
case "$self" in
  *'"success":true'*|*'"success": true'*) ;;
  *) echo "Admin token did not verify — nothing deleted."; unset tok; exit 1;;
esac
self_id=$(printf %s "$self" | sed -n 's/.*"id":[[:space:]]*"\([a-f0-9]*\)".*/\1/p' | head -n 1)
if [ "$self_id" = "$TARGET_ID" ]; then
  echo "Target IS the admin token — refusing."
  unset tok; exit 1
fi

name=$(python3 -c '
import json, sys, urllib.request
req = urllib.request.Request("https://api.cloudflare.com/client/v4/user/tokens/" + sys.argv[2])
req.add_header("Authorization", "Bearer " + sys.argv[1])
try:
    print(json.load(urllib.request.urlopen(req, timeout=30)).get("result", {}).get("name", ""))
except Exception:
    print("")
' "$tok" "$TARGET_ID")
if [ "$name" != "$EXPECTED_NAME" ]; then
  echo "Target name is '$name', not '$EXPECTED_NAME' — nothing deleted."
  unset tok; exit 1
fi

echo "Deleting '$name' ($TARGET_ID)..."
curl -s -X DELETE "https://api.cloudflare.com/client/v4/user/tokens/$TARGET_ID" -H "Authorization: Bearer $tok"
echo
unset tok
