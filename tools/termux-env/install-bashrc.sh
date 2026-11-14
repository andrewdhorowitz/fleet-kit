#!/data/data/com.termux/files/usr/bin/bash
# install-bashrc.sh — one-time wiring: makes Andrew's Termux start
# every shell with the fleet tools on PATH and guaranteed present.
#
# Adds ONE guarded block to ~/.bashrc (marker: fleet-termux-env).
# The block itself is cheap: it puts the gcloud SDK on PATH and runs
# ensure-tools.sh ONLY when something is actually missing or the
# last full check is over 24h old — a healthy shell pays a few
# command -v checks and nothing else. Re-running this installer is
# a no-op once the block is there.
#
# Usage: bash ~/work/fleet-kit/tools/termux-env/install-bashrc.sh

set -u
BASHRC="$HOME/.bashrc"
MARKER="fleet-termux-env"
touch "$BASHRC"
if grep -q "$MARKER" "$BASHRC"; then
  echo "✓ ~/.bashrc already carries the $MARKER block — nothing to do."
  exit 0
fi
cat >> "$BASHRC" <<'EOF'

# >>> fleet-termux-env (added by fleet-kit tools/termux-env/install-bashrc.sh) >>>
# gcloud lives under $PREFIX, not on the default PATH.
export PATH="$PREFIX/google-cloud-sdk/bin:$PATH"
# Guarantee the fleet toolset (node, firebase, gcloud, curl, git, …):
# ensure-tools.sh is a fast no-op when everything is present; it only
# installs when something is missing or stale (>24h since full check).
if [ -f "$HOME/work/fleet-kit/tools/termux-env/ensure-tools.sh" ]; then
  bash "$HOME/work/fleet-kit/tools/termux-env/ensure-tools.sh" >/dev/null 2>&1 || true
fi
# <<< fleet-termux-env <<<
EOF
echo "✓ Added the $MARKER block to ~/.bashrc."
echo "Open a NEW Termux session (or run: source ~/.bashrc) to pick it up."
