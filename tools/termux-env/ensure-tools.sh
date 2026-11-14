#!/data/data/com.termux/files/usr/bin/bash
# ensure-tools.sh — fleet Termux environment ensurer (Andrew, Nov 14, 2026).
#
# Idea (Andrew's): the tools the fleet keeps needing — Node.js, the
# Firebase CLI, gcloud, curl, git, and friends — should just LIVE in
# his Termux, every time, instead of each owner-run package
# discovering one missing mid-run. This script is the single place
# that guarantees them:
#
#   * FAST when everything is present: a row of command -v checks,
#     no network, exits in well under a second. Safe to run from
#     .bashrc on every shell startup (install-bashrc.sh wires that).
#   * COMPLETE when something is missing: installs the full set up
#     front — Termux packages in ONE pkg call, the Firebase CLI via
#     npm, and the Google Cloud SDK via Google's installer with the
#     Termux components fix — so a later step never stops to ask
#     "where is X".
#
# Idempotent: re-running changes nothing that is already right.
# It never logs anyone in: authentication is reported at the end
# (firebase / gcloud), never forced — a shell startup must not block
# on an interactive login. Packages that need a login run it
# themselves, once, in their own flow.
#
# Usage:  bash ~/work/fleet-kit/tools/termux-env/ensure-tools.sh [--force]
#   --force skips the 24h stamp and re-checks everything (the checks
#   are cheap; installs still only happen for what is missing).

set -u
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

STAMP_DIR="$HOME/.fleet-termux-env"
STAMP="$STAMP_DIR/last-full-check"
mkdir -p "$STAMP_DIR"

GCLOUD_BIN="$PREFIX/google-cloud-sdk/bin"
export PATH="$GCLOUD_BIN:$PATH"

# ---------- fast path -------------------------------------------------------
# Everything present and a full check ran within 24h: do nothing.
all_present() {
  for c in node npm npx git curl wget which python python3 jq unzip firebase; do
    command -v "$c" >/dev/null 2>&1 || return 1
  done
  [ -x "$GCLOUD_BIN/gcloud" ] || return 1
  return 0
}
if [ "$FORCE" -eq 0 ] && all_present && [ -f "$STAMP" ]; then
  now=$(date +%s); then_s=$(stat -c %Y "$STAMP" 2>/dev/null || echo 0)
  if [ $((now - then_s)) -lt 86400 ]; then
    exit 0
  fi
fi

echo "=== fleet Termux env — ensuring tools ==="
changed=0

# ---------- Termux packages (one call, full set) ----------------------------
# nodejs-lts carries node; npm is its own Termux package. python
# gives python + python3 (gcloud wants python3). openssh for git
# over ssh; ca-certificates so curl/npm trust the world; unzip for
# SDK-style archives; jq because every fleet script ends up wanting
# it; which because bare Termux famously lacks it (Nov 14 lesson).
PKGS="git curl wget which nodejs-lts npm python jq unzip openssh ca-certificates"
missing=""
for c in git curl wget which node npm python3 jq unzip ssh; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
  echo "Installing Termux packages:$PKGS"
  pkg install -y $PKGS && changed=1
else
  echo "✓ Termux packages present (git curl wget which node npm python jq unzip ssh)"
fi

# ---------- Firebase CLI (npm global) ---------------------------------------
if command -v firebase >/dev/null 2>&1; then
  echo "✓ firebase-tools present ($(firebase --version 2>/dev/null))"
else
  echo "Installing firebase-tools (npm -g)…"
  npm install -g firebase-tools && changed=1
fi

# ---------- Google Cloud SDK -------------------------------------------------
# Andrew's proven recipe (Nov 14, 2026): the SDK lands under
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
  [ -x "$GCLOUD_BIN/gcloud" ] && changed=1
fi
export PATH="$GCLOUD_BIN:$PATH"

# ---------- verify + auth report (never forces a login) ----------------------
echo "--- versions ---"
for c in node npm git curl jq python3; do
  command -v "$c" >/dev/null 2>&1 && echo "$c: $($c --version 2>/dev/null | head -1)" || echo "$c: MISSING"
done
command -v firebase >/dev/null 2>&1 && echo "firebase: $(firebase --version 2>/dev/null)" || echo "firebase: MISSING"
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
  echo "=== fleet Termux env: READY (all tools present) ==="
else
  echo "=== fleet Termux env: INCOMPLETE — see MISSING lines above; re-running is safe ==="
  exit 1
fi
