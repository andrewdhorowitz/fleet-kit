#!/data/data/com.termux/files/usr/bin/bash
# token-capture.sh — OWNER ONLY. Prompts for the Cloudflare admin token with
# hidden input and writes the cleaned value to ~/blah.txt in Termux home,
# OUTSIDE any repo. Prints nothing but the character count.
# The converger runner (scripts/token-converge-from-file.sh) reads that file.

read -r -s -p "Paste the admin token value (or the whole curl line), then press Enter: " tok
echo

if [ -z "$tok" ]; then
  echo "Nothing entered — blah.txt left unchanged."
  exit 1
fi

case "$tok" in
  *Bearer\ *) tok=${tok##*Bearer };;
esac
tok=$(printf %s "$tok" | tr -d " \r\n\"'")

if [ -z "$tok" ]; then
  echo "Nothing usable after cleaning — blah.txt left unchanged."
  exit 1
fi

printf '%s\n' "$tok" > "$HOME/blah.txt"
chmod 600 "$HOME/blah.txt"
unset tok
echo "Wrote $(wc -c < "$HOME/blah.txt") characters to ~/blah.txt (expect 41 for a standard token)."
