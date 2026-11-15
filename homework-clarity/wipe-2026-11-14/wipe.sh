#!/data/data/com.termux/files/usr/bin/bash
# wipe.sh — owner-run FULL WIPE for Homework Clarity
# (homework-clarity/wipe-2026-11-14).
#
# Andrew approved a full clean slate for Homework Clarity on
# Nov 14, 2026. This package deletes, in the Homework Clarity
# project gen-lang-client-0590645241 ONLY:
#   - every document in every top-level Firestore collection
#     (families, registry, and any others found at runtime),
#     including all subcollections, and
#   - every Firebase Auth user in the project.
# Nothing else is touched — see README.md for the full list,
# including what is NOT touched (rules, Worker, other projects,
# the Google accounts themselves).
#
# Shape:
#   1. Ensures the full Termux toolset first (fleet-kit
#      tools/termux-env/ensure-tools.sh), so nothing stops
#      mid-run on a missing dependency.
#   2. Checks the Firebase CLI sign-in; only if there is none
#      does it run the ONE interactive step: firebase login
#      --no-localhost (sign in as andrewhorowitz3, the account
#      that owns the project). A live sign-in is reused silently.
#   3. Confirms the signed-in account can see the pinned project
#      and refuses to continue if it cannot.
#   4. Hands off to wipe.mjs, which inventories everything,
#      writes a JSON backup into this folder (aborts if the
#      backup fails), asks Andrew to type WIPE, deletes, and
#      verifies both stores are empty.
#
# This is a one-way door. The backup file wipe.mjs writes is
# the only recovery. Re-running is safe: each run takes a fresh
# inventory and a fresh backup before deleting anything.

set -u
cd "$(dirname "$0")"
PROJECT="gen-lang-client-0590645241"

echo "=== Homework Clarity FULL WIPE 2026-11-14 (owner-run) ==="
echo "Target project (pinned): $PROJECT"

# --- 1. tools ---------------------------------------------------------------
ENSURE="$HOME/work/fleet-kit/tools/termux-env/ensure-tools.sh"
if [ -f "$ENSURE" ]; then
  bash "$ENSURE" --force || { echo "✗ Toolset incomplete — fix the MISSING lines above, then re-run."; exit 1; }
else
  echo "fleet-kit ensurer not found at $ENSURE — run: git -C ~/work/fleet-kit pull"
  exit 1
fi

# --- 2. firebase sign-in ------------------------------------------------------
if firebase projects:list >/dev/null 2>&1; then
  echo "✓ Firebase CLI already signed in — reusing it."
else
  echo "Firebase CLI needs its one sign-in (approve in browser, paste code back;"
  echo "sign in as andrewhorowitz3):"
  firebase login --no-localhost || { echo "✗ Sign-in did not complete — re-run when ready."; exit 1; }
fi

# --- 3. the signed-in account must see the pinned project ---------------------
if firebase projects:list 2>/dev/null | grep -q "$PROJECT"; then
  echo "✓ Project $PROJECT is visible to this sign-in."
else
  echo "✗ Project $PROJECT is NOT visible to the signed-in account."
  echo "  Sign in as andrewhorowitz3 (the project owner) and re-run."
  echo "  Nothing was deleted."
  exit 1
fi

# --- 4. inventory → backup → confirm → delete → verify (wipe.mjs) -------------
node "$(pwd)/wipe.mjs"
RC=$?
if [ "$RC" -eq 0 ]; then
  echo ""
  echo "wipe.sh: finished (see the wipe.mjs summary above)."
else
  echo ""
  echo "wipe.sh: wipe.mjs exited $RC — read its summary above; nothing is hidden."
fi
exit "$RC"
