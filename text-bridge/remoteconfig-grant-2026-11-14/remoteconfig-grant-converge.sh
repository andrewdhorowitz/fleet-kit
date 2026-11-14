#!/usr/bin/env bash
# remoteconfig-grant-converge.sh — one-shot converger that unblocks
# the version-policy Remote Config mirror (owner-run, Termux).
#
# The blocker (verified Nov 14, 2026; report:
# bridge-minversion-report-2026-11-14.md in the text-bridge-2 goal
# workspace): the text-bridge-receiver Worker's Firebase service
# account gets HTTP 403 from the Firebase Remote Config API on
# project family-routines-app (826159679918), so no Remote Config
# template exists and the apps' fallback policy leg finds no
# parameters. From outside, a 403 does not say which of these is
# missing, so this converger fixes BOTH, under Andrew's own gcloud
# login, on that one project only:
#   1. The Firebase Remote Config API
#      (firebaseremoteconfig.googleapis.com) is enabled.
#   2. The project's firebase-adminsdk-* service account — the
#      account whose key the Worker holds as
#      FIREBASE_SERVICE_ACCOUNT_JSON — is granted
#      roles/cloudconfig.admin (Firebase Remote Config Admin) on
#      the project. (Nov 14, 2026: the legacy role name
#      roles/firebaseremoteconfig.admin is no longer grantable at
#      project level — add-iam-policy-binding rejects it with
#      "Role roles/firebaseremoteconfig.admin is not supported
#      for this resource"; Google's current predefined role for
#      Remote Config is roles/cloudconfig.admin, permissions
#      cloudconfig.configs.get/update. A pre-existing legacy-name
#      binding still counts as satisfied.)
# Nothing else is touched: no other project, no other API, no other
# role, no other member.
#
# Service-account discovery: the credential itself lives only as a
# Worker secret, so the account is found from the project side —
# the project's service accounts are listed and the
# firebase-adminsdk-* account for family-routines-app is picked
# (there is normally exactly one). If there are ZERO or MULTIPLE
# plausible candidates the script STOPS and prints the full list
# for a human decision; it never guesses. The chosen account's
# email is printed in the output (an identifier, not a secret).
#
# Converger contract (fleet pattern): check -> apply what's
# missing -> verify by read-back, reporting "✓ applied" /
# "✓ already" / "– skipped (reason)" per step, into
# remoteconfig-grant-results.txt in this package directory
# (flushed per line, then committed + pushed by the script when
# git allows; the terminal output is the fallback record). A
# machine-readable outcome flag sits as the second line of the
# results file: "flag: SUCCESS" / "flag: INCOMPLETE" /
# "flag: IMPOSSIBLE: <reason>" for failures no retry can fix
# (gcloud missing, no login, ambiguous service account).
# Idempotent: re-running a finished converger is a no-op success.
#
# Pacing (fleet converger pacing rule): the two control-plane
# changes happen one at a time, each verified before the next
# begins, with a deliberate pause between a fresh API enable and
# the IAM grant. Nothing is burst-created; nothing is retried in a
# tight loop — verification polls wait between reads.
#
# Default invocation LOOPS until a pass fully succeeds: each
# attempt re-pulls this repo (picking up script fixes pushed
# mid-loop), runs one pass as a child process, and retries with
# backoff — 60s, 180s, then 300s (RC_LOOP_DELAYS, space-separated,
# overrides) — up to 10 attempts. An IMPOSSIBLE flag stops the
# loop at once. --once runs a single pass and exits with that
# pass's real status.
#
# When a pass succeeds, the script prints a DONE banner: tell
# Muse, and Muse re-runs version-policy-set, which seeds the
# four Remote Config parameters and read-back-verifies them
# (remote_config_synced: true) with no further build or publish.
#
# Usage:
#   bash text-bridge/remoteconfig-grant-2026-11-14/remoteconfig-grant-converge.sh          (loop)
#   bash text-bridge/remoteconfig-grant-2026-11-14/remoteconfig-grant-converge.sh --once   (one pass)

PROJECT_ID="family-routines-app"
PROJECT_NUMBER="826159679918"
API_NAME="firebaseremoteconfig.googleapis.com"
ROLE="roles/cloudconfig.admin"
LEGACY_ROLE="roles/firebaseremoteconfig.admin"
SA_PREFIX="firebase-adminsdk-"
SA_DOMAIN="@family-routines-app.iam.gserviceaccount.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS="$SCRIPT_DIR/remoteconfig-grant-results.txt"
ERRORS_FILE="$SCRIPT_DIR/remoteconfig-grant-errors.txt"

# gcloud must never prompt: the loop runs unattended.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

OVERALL_OK=1
PERMANENT_REASON=""
SA_EMAIL=""
API_WAS_ENABLED=0
WORKDIR=""
ERRLOG="/dev/null"

set -u

log_line() { echo "$1" | tee -a "$RESULTS"; }
mark_incomplete() { OVERALL_OK=0; }
mark_permanent() {
  if [[ -z "$PERMANENT_REASON" ]]; then PERMANENT_REASON="$1"; fi
  OVERALL_OK=0
}

# Run a command capturing combined output into $WORKDIR/cmd.out;
# returns the command's exit code. Failures are appended to the
# error log with a header (they ride into the errors file on an
# incomplete run).
run_cap() {
  local desc="$1"; shift
  "$@" > "$WORKDIR/cmd.out" 2> "$WORKDIR/cmd.err"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    {
      echo "=== $desc (exit $rc): $*"
      cat "$WORKDIR/cmd.err" 2>/dev/null
      cat "$WORKDIR/cmd.out" 2>/dev/null
      echo ""
    } >> "$ERRLOG"
  fi
  return $rc
}

snippet() { # first ~400 chars, single line, of a file
  [[ -f "$1" ]] || { echo "no output"; return; }
  tr '\n' ' ' < "$1" | cut -c1-400
}

err_text() { # stderr first, stdout as fallback
  if [[ -s "$WORKDIR/cmd.err" ]]; then snippet "$WORKDIR/cmd.err";
  else snippet "$WORKDIR/cmd.out"; fi
}

# --- preflight -----------------------------------------------------
# gcloud present and logged in, python3 for JSON parsing, and the
# project reachable under this login. Login/project problems are
# IMPOSSIBLE (a human must fix them); the loop stops for those.
preflight() {
  if ! command -v gcloud >/dev/null 2>&1; then
    mark_permanent "gcloud is not installed in this Termux"
    log_line "preflight: – skipped (gcloud not found — install the Google Cloud CLI once, sign in, and re-run; the loop cannot fix this)"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    mark_permanent "python3 is not installed in this Termux"
    log_line "preflight: – skipped (python3 not found — pkg install python, then re-run)"
    return 1
  fi
  local account
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)"
  if [[ -z "$account" ]]; then
    mark_permanent "no active gcloud login"
    log_line "preflight: – skipped (no active gcloud login — run: gcloud auth login, as the account that owns project $PROJECT_ID, then re-run)"
    return 1
  fi
  log_line "preflight: ✓ gcloud login active ($account)"
  if ! run_cap "projects describe" gcloud projects describe "$PROJECT_ID" --format='value(projectId)'; then
    mark_permanent "project $PROJECT_ID not reachable under this login"
    log_line "preflight: – skipped (cannot read project $PROJECT_ID under $account — sign in as the project owner and re-run | detail: $(err_text))"
    return 1
  fi
  log_line "preflight: ✓ project $PROJECT_ID ($PROJECT_NUMBER) reachable"
  return 0
}

# --- step 1: the Remote Config API is enabled ----------------------
api_is_enabled() {
  gcloud services list --enabled --project="$PROJECT_ID" \
    --format='value(config.name)' 2>/dev/null \
    | grep -qx "$API_NAME"
}

step1() {
  if api_is_enabled; then
    API_WAS_ENABLED=1
    log_line "step 1 api $API_NAME: ✓ already"
    return 0
  fi
  if ! run_cap "services enable" gcloud services enable "$API_NAME" --project="$PROJECT_ID"; then
    log_line "step 1 api enable: – skipped (gcloud services enable failed | detail: $(err_text))"
    mark_incomplete; return 1
  fi
  # Enabling is asynchronous: poll the enabled list until it shows.
  local i
  for i in 1 2 3 4 5 6; do
    if api_is_enabled; then
      log_line "step 1 api $API_NAME: ✓ applied (verified enabled)"
      return 0
    fi
    sleep 15
  done
  log_line "step 1 api $API_NAME: – skipped (enable accepted but the API does not show as enabled yet — propagation lag; the loop's next pass re-checks)"
  mark_incomplete; return 1
}

# --- step 2: discover the firebase-adminsdk service account --------
step2() {
  if ! run_cap "service-accounts list" gcloud iam service-accounts list \
      --project="$PROJECT_ID" --format='value(email)'; then
    log_line "step 2 service account discovery: – skipped (could not list service accounts | detail: $(err_text))"
    mark_incomplete; return 1
  fi
  cp "$WORKDIR/cmd.out" "$WORKDIR/all-sas.txt"
  local candidates=()
  local email
  while IFS= read -r email; do
    case "$email" in
      "$SA_PREFIX"*"$SA_DOMAIN") candidates+=("$email") ;;
    esac
  done < "$WORKDIR/all-sas.txt"
  if [[ ${#candidates[@]} -eq 1 ]]; then
    SA_EMAIL="${candidates[0]}"
    log_line "step 2 service account: ✓ found — $SA_EMAIL"
    return 0
  fi
  if [[ ${#candidates[@]} -eq 0 ]]; then
    mark_permanent "no $SA_PREFIX* service account exists on $PROJECT_ID"
    log_line "step 2 service account discovery: – STOPPED (no ${SA_PREFIX}* account on $PROJECT_ID — not guessing; full list follows)"
  else
    mark_permanent "multiple $SA_PREFIX* service accounts on $PROJECT_ID — a human must pick"
    log_line "step 2 service account discovery: – STOPPED (${#candidates[@]} ${SA_PREFIX}* candidates on $PROJECT_ID — not guessing; full list follows)"
  fi
  log_line "  all service accounts on $PROJECT_ID:"
  while IFS= read -r email; do
    [[ -n "$email" ]] && log_line "    $email"
  done < "$WORKDIR/all-sas.txt"
  log_line "  Tell Muse which account the Worker uses, and this step gets pinned by hand."
  return 1
}

# --- step 3: the role grant, verified by policy read-back ----------
binding_present() {
  gcloud projects get-iam-policy "$PROJECT_ID" --format=json \
    > "$WORKDIR/policy.json" 2>/dev/null || return 1
  python3 - "$WORKDIR/policy.json" "$ROLE" "$LEGACY_ROLE" "serviceAccount:$SA_EMAIL" <<'PY'
import json, sys
try:
    policy = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
roles = {sys.argv[2], sys.argv[3]}
for b in policy.get("bindings") or []:
    if b.get("role") in roles and sys.argv[4] in (b.get("members") or []):
        sys.exit(0)
sys.exit(1)
PY
}

step3() {
  if binding_present; then
    log_line "step 3 role $ROLE for $SA_EMAIL: ✓ already"
    return 0
  fi
  if [[ "$API_WAS_ENABLED" == "0" ]]; then
    # Pacing: a fresh control-plane change (the API enable) just
    # landed and was verified; pause before the second one.
    log_line "step 3: pacing pause 60s (one control-plane change at a time)"
    sleep 60
  fi
  if ! run_cap "add-iam-policy-binding" gcloud projects add-iam-policy-binding \
      "$PROJECT_ID" --member="serviceAccount:$SA_EMAIL" \
      --role="$ROLE" --condition=None; then
    log_line "step 3 role grant: – skipped (add-iam-policy-binding failed | detail: $(err_text))"
    mark_incomplete; return 1
  fi
  # IAM propagation can lag the write: read back until it shows.
  local i
  for i in 1 2 3 4 5; do
    if binding_present; then
      log_line "step 3 role $ROLE for $SA_EMAIL: ✓ applied (verified in the project IAM policy)"
      return 0
    fi
    sleep 15
  done
  log_line "step 3 role grant: – skipped (binding accepted but not visible in the policy read-back yet — propagation lag; the loop's next pass re-checks)"
  mark_incomplete; return 1
}

# --- results bookkeeping --------------------------------------------
compose_errors() {
  {
    echo "remoteconfig-grant errors — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""
    cat "$ERRLOG" 2>/dev/null
  } > "$ERRORS_FILE"
}

commit_results() {
  (
    cd "$REPO_ROOT" || return
    local rel_results="text-bridge/remoteconfig-grant-2026-11-14/remoteconfig-grant-results.txt"
    local rel_errors="text-bridge/remoteconfig-grant-2026-11-14/remoteconfig-grant-errors.txt"
    local files=("$rel_results")
    git add -- "$rel_results" 2>/dev/null || return
    if [[ "$OVERALL_OK" == "0" ]]; then
      git add -- "$rel_errors" 2>/dev/null
      files+=("$rel_errors")
    elif [[ -f "$ERRORS_FILE" ]]; then
      rm -f "$ERRORS_FILE"
      git add -A -- "$rel_errors" 2>/dev/null
      files+=("$rel_errors")
    fi
    if git diff --cached --quiet -- "${files[@]}" 2>/dev/null; then
      echo "results: unchanged — nothing to commit"
      return
    fi
    if ! git commit -q -m "remoteconfig-grant results $(date '+%Y-%m-%d %H:%M')" -- "${files[@]}" 2>/dev/null; then
      echo "results: commit failed (files are saved locally at $RESULTS)"
      return
    fi
    if git push -q origin HEAD 2>/dev/null; then
      echo "results: committed and pushed"
    else
      echo "results: committed locally — push failed, will ride the next push"
    fi
  )
}

write_flag() {
  local flag_line="$1"
  { head -n 1 "$RESULTS"; echo "$flag_line"; tail -n +2 "$RESULTS"; } \
    > "$RESULTS.flagtmp" && mv "$RESULTS.flagtmp" "$RESULTS"
  echo "$flag_line"
}

print_done_banner() {
  echo ""
  echo "=== DONE — Remote Config access granted and verified ==="
  echo "Tell Muse: \"the Remote Config grant converger finished\"."
  echo "Muse then re-runs version-policy-set, which seeds the four"
  echo "Remote Config parameters (bridge + homehelper min/latest) and"
  echo "read-back-verifies them — no further build or publish needed."
}

finalize() {
  local flag_line
  if [[ "$OVERALL_OK" == "1" ]]; then
    flag_line="flag: SUCCESS"
  elif [[ -n "$PERMANENT_REASON" ]]; then
    flag_line="flag: IMPOSSIBLE: $PERMANENT_REASON"
  else
    flag_line="flag: INCOMPLETE"
  fi
  write_flag "$flag_line"
  if [[ "$OVERALL_OK" == "1" ]]; then
    log_line "summary: OK — API enabled, role granted, both verified by read-back"
  else
    log_line "summary: INCOMPLETE — see the step lines above; full error detail in remoteconfig-grant-errors.txt"
    compose_errors
  fi
  commit_results
  if [[ "$OVERALL_OK" == "1" ]]; then print_done_banner; fi
}

main() {
  : > "$RESULTS"
  log_line "remoteconfig-grant results — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  if ! preflight; then finalize; exit 1; fi
  # Each step checks and applies independently; only step 3 depends
  # on an earlier one (it needs the account step 2 discovers).
  step1 || true
  step2 || true
  if [[ -n "$SA_EMAIL" ]]; then step3 || true; fi
  finalize
  exit $((1 - OVERALL_OK))
}

# Loop wrapper (default mode): Andrew runs one command and the
# script babysits itself. Each attempt re-pulls the repo — so a
# fix pushed mid-loop is picked up automatically — then runs one
# full pass as a CHILD invocation of the freshly pulled script
# (--once), which commits+pushes its own results as the audit
# trail. A failed git pull never kills the loop: it is noted and
# the local copy runs. An IMPOSSIBLE flag (gcloud missing, no
# login, ambiguous service account) stops the loop immediately —
# only a human can clear those.
loop_main() {
  local delays=(${RC_LOOP_DELAYS:-60 180 300})
  local max_attempts=10 attempt delay idx
  local self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! git -C "$REPO_ROOT" pull -q >/dev/null 2>&1; then
      echo "--- git pull failed — continuing with the local copy ---"
    fi
    if bash "$self" --once; then
      echo "--- remoteconfig-grant: SUCCESS on attempt $attempt/$max_attempts ---"
      return 0
    fi
    if grep -q '^flag: IMPOSSIBLE' "$RESULTS" 2>/dev/null; then
      echo "--- remoteconfig-grant: STOPPED — the results file names a problem only a human can clear (see above) ---"
      return 1
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      idx=$((attempt - 1))
      if [[ $idx -ge ${#delays[@]} ]]; then idx=$((${#delays[@]} - 1)); fi
      delay="${delays[$idx]}"
      echo "--- attempt $attempt/$max_attempts — incomplete, retrying in ${delay}s (script re-pulled) ---"
      sleep "$delay"
    fi
  done
  echo "summary: INCOMPLETE after $max_attempts attempts — stopping loop"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == "--once" ]]; then
    WORKDIR="$(mktemp -d)"
    ERRLOG="$WORKDIR/errors.log"
    : > "$ERRLOG"
    trap 'rm -rf "$WORKDIR"' EXIT
    main
  else
    loop_main
    exit $?
  fi
fi
