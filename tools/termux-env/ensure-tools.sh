#!/data/data/com.termux/files/usr/bin/bash
# ensure-tools.sh — fleet Termux environment ensurer (Andrew, Nov 14, 2026).
#
# Andrew's model, exactly: the REQUIREMENTS ARE LISTS, not code.
#   requirements-termux.txt   Termux (pkg) packages, one per line
#   requirements-npm.txt      global npm packages, one per line
#   requirements-commands.txt commands that must exist on PATH
# This script is only the applier: it reads the lists, installs
# whatever is missing (the full set up front, in one pkg call, so
# no later step stops on a missing dependency), and checks the
# command list at the end. To change what lives in Andrew's base
# terminal, edit the lists — not this script. (gcloud is the one
# special case: it is not a pkg or npm package, so its installer
# recipe from Nov 14, 2026 is coded below, and it is verified by
# its path under $PREFIX rather than the command list.)
#
# FAST when everything is present: command checks + a 24h stamp,
# no network, exits in well under a second — safe from .bashrc at
# every shell startup (install-bashrc.sh wires that, ONE time;
# after that it is simply in effect, nobody runs a starter again).
#
# It never logs anyone in: sign-ins are reported at the end
# (firebase / gcloud), never forced — a shell startup must not
# block on an interactive login. Packages that need a login run
# it themselves, once, in their own flow.
#
# Usage:  bash ~/work/fleet-kit/tools/termux-env/ensure-tools.sh [--force]

set -u
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1
cd "$(dirname "$0")"

STAMP_DIR="$HOME/.fleet-termux-env"
STAMP="$STAMP_DIR/last-full-check"
mkdir -p "$STAMP_DIR"

GCLOUD_BIN="$PREFIX/google-cloud-sdk/bin"
export PATH="$GCLOUD_BIN:$PATH"

read_list() { grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$'; }
TERMUX_PKGS=$(read_list requirements-termux.txt)
NPM_PKGS=$(read_list requirements-npm.txt)
WANT_CMDS=$(read_list requirements-commands.txt)

all_present() {
  local c
  for c in $WANT_CMDS; do
    command -v "$c" >/dev/null 2>&1 || return 1
  done
  [ -x "$GCLOUD_BIN/gcloud" ] || return 1
  return 0
}

# ---------- fast path ---------------------------------------------------------
if [ "$FORCE" -eq 0 ] && all_present && [ -f "$STAMP" ]; then
  now=$(date +%s); then_s=$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)
  if [ $((now - then_s)) -lt 86400 ]; then
    exit 0
  fi
fi

echo "=== fleet Termux env — ensuring tools from the requirements lists ==="

# ---------- Termux packages (one call, full list) -----------------------------
if all_present; then
  echo "✓ Everything on the lists is already present."
else
  echo "Installing Termux packages from requirements-termux.txt:"
  echo "  $TERMUX_PKGS"
  pkg install -y $TERMUX_PKGS || true
fi

# ---------- global npm packages (from the list) -------------------------------
for p in $NPM_PKGS; do
  # firebase-tools -> the `firebase` command; generic rule: a global
  # package counts as present when its same-named command resolves,
  # with the one known rename handled explicitly.
  cmd="$p"
  [ "$p" = "firebase-tools" ] && cmd="firebase"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "✓ npm package present: $p"
  else
    echo "Installing npm package: $p"
    npm install -g "$p" || true
  fi
done

# ---------- Google Cloud SDK (special case: not a package) --------------------
# Andrew's proven recipe (Nov 14, 2026): SDK under
# $PREFIX/google-cloud-sdk (NOT ~/), and the components complaint
# ("unknown [gcloud, gcloud-crc32c]") is fixed by re-running
# install.sh with --override-components.
if [ -x "$GCLOUD_BIN/gcloud" ]; then
  echo "✓ gcloud present"
else
  echo "Installing Google Cloud SDK…"
  curl -sSL https://sdk.cloud.google.com | bash
  if [ -f "$PREFIX/google-cloud-sdk/install.sh" ]; then
    "$PREFIX/google-cloud-sdk/install.sh" --override-components >/dev/null 2>&1 || true
  fi
fi
export PATH="$GCLOUD_BIN:$PATH"

# ---------- verify against the command list + auth report ---------------------
echo "--- versions ---"
for c in node npm git curl jq python3 pip firebase; do
  command -v "$c" >/dev/null 2>&1 && echo "$c: $($c --version 2>/dev/null | head -1)" || echo "$c: MISSING"
done
[ -x "$GCLOUD_BIN/gcloud" ] && echo "gcloud: $(gcloud --version 2>/dev/null | head -1)" || echo "gcloud: MISSING"
echo "--- sign-ins (report only) ---"
if command -v firebase >/dev/null 2>&1; then
  if firebase projects:list >/dev/null 2>&1; then echo "firebase: signed in"; else echo "firebase: NOT signed in (a package that needs it will run: firebase login --no-localhost)"; fi
fi
if [ -x "$GCLOUD_BIN/gcloud" ]; then
  acct=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)
  [ -n "$acct" ] && echo "gcloud: signed in as $acct" || echo "gcloud: NOT signed in"
fi

touch "$STAMP"
if all_present; then
  echo "=== fleet Termux env: READY (everything on the requirements lists is present) ==="
else
  echo "=== fleet Termux env: INCOMPLETE — see MISSING lines above; re-running is safe ==="
  exit 1
fi
