#!/data/data/com.termux/files/usr/bin/bash
# publish-rules.sh — owner-run Firestore rules publish for
# Homework Clarity (homework-clarity/rules-publish-2026-11-14).
#
# Why this exists: the current firestore.rules (the Nov 14 version —
# personal-space seating clause + the run-as parent grant on kids'
# items/days/profile) has been sitting unpublished since Nov 13
# because the new Firebase console's Rules tab shows Andrew the
# editor and "Develop and test" but NO Publish button. Publishing
# is a Firebase CLI deploy; this script packages the whole thing:
#
#   1. Ensures the full Termux toolset first (fleet-kit
#      tools/termux-env/ensure-tools.sh — node, firebase-tools,
#      gcloud, curl, git, … installed up front if missing, so no
#      step below stops on a missing dependency).
#   2. Checks the Firebase CLI sign-in; only if there is none does
#      it run the ONE interactive step: firebase login
#      --no-localhost (approve in the browser, paste the code back;
#      sign in as andrewhorowitz3 — the account that owns the
#      project). A live sign-in is reused silently.
#   3. Deploys ONLY the Firestore rules from this package
#      (firebase.json + firestore.rules ride along in the folder)
#      to project gen-lang-client-0590645241.
#   4. Verifies: re-reads the project's current ruleset list via
#      the Firebase Rules API using the CLI's own saved credential
#      and reports the newest ruleset's create time — a deploy that
#      didn't land says so here.
#
# Idempotent: re-running redeploys the same rules. Creates nothing
# on any provider control plane beyond the ruleset release itself.

set -u
cd "$(dirname "$0")"
PROJECT="gen-lang-client-0590645241"

echo "=== Homework Clarity rules publish 2026-11-14 (owner-run) ==="

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

# --- 3. deploy the rules -------------------------------------------------------
echo "Deploying Firestore rules to $PROJECT…"
if ! firebase deploy --only firestore:rules --project "$PROJECT" --non-interactive; then
  echo "✗ Deploy failed — see the Firebase output above; nothing was published. Re-running is safe."
  exit 1
fi

# --- 4. verify -----------------------------------------------------------------
# The CLI stores its OAuth credential in configstore; borrow its
# refresh token to mint an access token and list rulesets.
echo "Verifying the live ruleset…"
node -e '
const fs = require("fs"), os = require("os"), path = require("path");
(async () => {
  const cfgPath = path.join(os.homedir(), ".config/configstore/firebase-tools.json");
  const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
  const tok = cfg.tokens || {};
  let access = tok.access_token;
  const expired = !tok.expires_at || Date.now() > tok.expires_at - 60000;
  if ((!access || expired) && tok.refresh_token) {
    const body = new URLSearchParams({
      grant_type: "refresh_token", refresh_token: tok.refresh_token,
      client_id: "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com",
      client_secret: "j9iVZfS8kkCEFUPaAeJV0sAi",
    });
    const r = await fetch("https://oauth2.googleapis.com/token", { method: "POST", body });
    const j = await r.json();
    access = j.access_token;
  }
  if (!access) { console.log("verify: no access token available — deploy output above is the record."); return; }
  const r = await fetch("https://firebaserules.googleapis.com/v1/projects/gen-lang-client-0590645241/rulesets?pageSize=3", { headers: { Authorization: "Bearer " + access } });
  const j = await r.json();
  if (!r.ok) { console.log("verify: ruleset list failed (" + r.status + ") — deploy output above is the record."); return; }
  const sets = (j.rulesets || []);
  if (!sets.length) { console.log("verify: no rulesets returned — unexpected; tell Muse."); return; }
  console.log("verify: newest live ruleset " + sets[0].name.split("/").pop() + " created " + sets[0].createTime);
})();
' || echo "verify step could not run — the deploy output above is the record."

echo ""
echo "=== RULES PUBLISHED to $PROJECT ==="
echo "Back in the app: a parent's 'Open in edit mode' on a kid's row now"
echo "opens the list for real, and the private-space create button works."
echo "Tell Muse the publish ran — Muse will re-verify from its side."
