#!/data/data/com.termux/files/usr/bin/bash
# token-capture.sh — OWNER ONLY. Prompts for the Cloudflare admin token with
# hidden input and writes the cleaned value to ~/cf-token-admin.txt in Termux home,
# OUTSIDE any repo. Prints nothing but the character count.
# The converger runner (scripts/token-converge-from-file.sh) reads that file.

read -r -s -p "Paste the admin token value (or the whole curl line), then press Enter: " tok
echo

if [ -z "$tok" ]; then
  echo "Nothing entered — cf-token-admin.txt left unchanged."
  exit 1
fi

case "$tok" in
  *Bearer\ *) tok=${tok##*Bearer };;
esac
tok=$(printf %s "$tok" | tr -d " \r\n\"'")

if [ -z "$tok" ]; then
  echo "Nothing usable after cleaning — cf-token-admin.txt left unchanged."
  exit 1
fi

printf '%s\n' "$tok" > "$HOME/cf-token-admin.txt"
chmod 600 "$HOME/cf-token-admin.txt"
unset tok
echo "Wrote $(wc -c < "$HOME/cf-token-admin.txt") characters to ~/cf-token-admin.txt (character count only — the value is never printed)."
