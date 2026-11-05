#!/data/data/com.termux/files/usr/bin/bash
# token-converge-from-file.sh — runs the Cloudflare token converger with the
# admin token read from a local file that exists only on Andrew's phone.
#
# The token file is cf-token-admin.txt in Termux home (~/cf-token-admin.txt), outside the
# repo. It holds a clean copy of the raw admin token value. This script
# only reads it into memory for the duration of the run.

set -u
cd ~/work/fleet-kit || exit 1
git pull

TOKEN_FILE="$HOME/cf-token-admin.txt"
if [ ! -f "$TOKEN_FILE" ]; then
  echo "token file not found: $TOKEN_FILE"
  exit 1
fi

tok=$(tr -d '\r\n' < "$TOKEN_FILE")
# Tolerate the file containing a curl snippet or a leading "Bearer ".
case "$tok" in
  *Bearer\ *) tok=${tok##*Bearer }; tok=${tok%%\"*}; tok=${tok%%\'*};;
esac
tok=$(printf %s "$tok" | tr -d ' ')

if [ -z "$tok" ]; then
  echo "token file is empty"
  exit 1
fi

CF_TOKEN_ADMIN="$tok" python3 scripts/cf_token_converge.py
status=$?
unset tok
exit $status
