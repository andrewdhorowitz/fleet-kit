#!/data/data/com.termux/files/usr/bin/bash
# token-converge-run.sh — OWNER-ONLY runner for the Cloudflare token converger.
#
# HOW TO USE (on Andrew's phone, in Termux):
#   1. Copy this file OUT of the repo:   cp ~/work/fleet-kit/scripts/token-converge-run.sh ~/
#   2. Edit the COPY in your home folder:  nano ~/token-converge-run.sh
#      Replace PASTE_RAW_TOKEN_HERE with the raw admin token (the characters
#      after "Bearer " in Cloudflare's curl example — no "Bearer", no quotes).
#   3. Run the COPY:   bash ~/token-converge-run.sh
#
# The filled-in copy lives ONLY in Termux home on this phone. NEVER commit it,
# never move it back into the repo, never send it anywhere. The repo copy must
# always keep the placeholder.

CF_TOKEN_ADMIN='PASTE_RAW_TOKEN_HERE'

cd ~/work/fleet-kit || exit 1
git pull
CF_TOKEN_ADMIN="$CF_TOKEN_ADMIN" python3 scripts/cf_token_converge.py
