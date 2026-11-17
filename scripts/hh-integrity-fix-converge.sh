#!/usr/bin/env bash
# hh-integrity-fix-converge.sh — one-shot converger for Home Helper's
# enrollment blocker (Play Integrity decode HTTP 403).
#
# Runs on Andrew's phone (Termux) under his own gcloud login
# (andrewhorowitz3). Muse has no GCP credentials; this script is
# the owner-run fix for the diagnosis in
# home-helper/state/enrollment-integrity-403-diagnosis-2026-11-16.md:
# the fleet Worker's Play Integrity decode call for package
# com.andrewdhorowitz.homehelper gets HTTP 403 because the decode
# service account is not authorized in Home Helper's linked Cloud
# project, family-routines-app (826159679918). Two possible
# sub-causes, both fixed here — both operations are idempotent,
# reversible, and create no resources:
#   (a) the Play Integrity API is not enabled in family-routines-app
#       -> Step 1 enables it.
#   (b) the decode service account (its key is the Worker secret
#       PLAY_INTEGRITY_SA_JSON; the account itself lives in project
#       play-publisher-513614) has no grant in family-routines-app
#       -> Step 3 grants it roles/serviceusage.serviceUsageConsumer
#          there (Google's documented remedy for cross-project
#          decode).
#
# Steps:
#   0. Preflight: gcloud exists and is signed in (the active account
#      is printed); both projects are visible. Stop loudly if not.
#   1. Enable playintegrity.googleapis.com in family-routines-app
#      (skip if already enabled), then verify it lists as enabled.
#   2. Confirm the decode service account: it is pinned exactly to
#      play-api@play-publisher-513614.iam.gserviceaccount.com (see
#      DECODE_SA_EMAIL below — the Worker secret
#      PLAY_INTEGRITY_SA_JSON is the play-api account's key, per
#      the Nov 7, 2026 build record). If that exact account is
#      absent from play-publisher-513614's list, print ALL accounts
#      found and STOP loudly — nothing is granted. (The original
#      name-match discovery ran Nov 17, 2026 and stopped safely:
#      neither of the project's two accounts — play-api@ and
#      play-publisher@ — has "integrity" in its name.)
#   3. Grant the discovered account Service Usage Consumer in
#      family-routines-app (skip if the binding already exists),
#      then verify the binding in the project's IAM policy.
#
# Converger contract: check -> apply what's missing -> report
# "✓ applied" / "✓ already" / "– skipped (reason)" per step into
# hh-integrity-fix-results.txt at the repo root (appended per run,
# flushed per line, then committed + pushed by the script when git
# allows; if the push-back fails, the printed output still carries
# the result). Idempotent; safe to re-run.
#
# Pacing (fleet converger pacing rule): a deliberate pause
# (HH_PACE_SLEEP seconds if set, otherwise a jittered 20–45s)
# separates the mutating operations, and follows a successful API
# enable for propagation.
#
# Default invocation LOOPS until a pass fully succeeds: each attempt
# re-pulls this repo (picking up script fixes pushed mid-loop),
# runs one pass as a child process (so a replaced script file never
# corrupts a running process), and retries with backoff — 60s,
# 180s, then 300s (HH_LOOP_DELAYS, space-separated, overrides) — up
# to 20 attempts. --once runs a single pass and exits with that
# pass's real status. Exit codes: 0 = success; 1 = incomplete,
# retrying may help; 3 = stopped loudly on a retry-proof condition
# (preflight failure, or the pinned service account not found)
# — the loop never retries a 3.
#
# Usage:
#   bash scripts/hh-integrity-fix-converge.sh          (loop)
#   bash scripts/hh-integrity-fix-converge.sh --once   (one pass)

TARGET_PROJECT="family-routines-app"
TARGET_PROJECT_NUMBER="826159679918"
SA_PROJECT="play-publisher-513614"
API_SERVICE="playintegrity.googleapis.com"
GRANT_ROLE="roles/serviceusage.serviceUsageConsumer"
APP_PACKAGE="com.andrewdhorowitz.homehelper"
# The decode account, pinned exactly. Identification: the Worker
# secret PLAY_INTEGRITY_SA_JSON is the play-api service account's
# key — Nov 7, 2026 build record (~/memory/2026-11-07.md):
# "play-api SA value traveled repo-secret → Cloudflare inside
# Actions only". The Nov 17, 2026 run of this script confirmed the
# only service accounts in play-publisher-513614 are play-api@ and
# play-publisher@ — neither has "integrity" in its name, so the
# original name-match discovery stopped safely and this pin
# replaced it.
DECODE_SA_EMAIL="play-api@play-publisher-513614.iam.gserviceaccount.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS="$REPO_ROOT/hh-integrity-fix-results.txt"

OVERALL_OK=1
STOP_LOUD=0
SA_EMAIL=""

set -u

log_line() { echo "$1" | tee -a "$RESULTS"; }

mark_incomplete() { OVERALL_OK=0; }

# Retry-proof failure: record it, mark the pass incomplete, and
# tell the loop wrapper (via exit code 3) not to retry.
mark_stop() {
  STOP_LOUD=1
  mark_incomplete
}

# Deliberate pause between mutating operations (pacing rule).
pace() {
  local secs
  if [[ -n "${HH_PACE_SLEEP:-}" ]]; then
    secs="$HH_PACE_SLEEP"
  else
    secs=$((20 + RANDOM % 26))
  fi
  if [[ "$secs" != "0" ]]; then
    echo "--- pacing pause: ${secs}s ---"
    sleep "$secs"
  fi
}

# Step 0 — preflight: gcloud present, signed in, projects visible.
preflight() {
  if ! command -v gcloud >/dev/null 2>&1; then
    log_line "preflight: ✗ STOPPED — gcloud not found on PATH (run the fleet Termux env ensurer first, then re-run this script)"
    mark_stop; return
  fi
  local account
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)"
  if [[ -z "$account" ]]; then
    log_line "preflight: ✗ STOPPED — gcloud has no active signed-in account (run 'gcloud auth login' first)"
    mark_stop; return
  fi
  log_line "preflight: gcloud present, signed in as $account"
  local proj
  for proj in "$TARGET_PROJECT" "$SA_PROJECT"; do
    if gcloud projects describe "$proj" >/dev/null 2>&1; then
      log_line "preflight: project $proj: ✓ visible"
    else
      log_line "preflight: ✗ STOPPED — project $proj is not visible to this login"
      mark_stop; return
    fi
  done
}

# Step 1 — Play Integrity API enabled in family-routines-app.
step1() {
  local listed
  listed="$(gcloud services list --enabled --project="$TARGET_PROJECT" \
      --filter="config.name=$API_SERVICE" --format='value(config.name)' 2>/dev/null)"
  if [[ "$listed" == "$API_SERVICE" ]]; then
    log_line "step 1 play integrity api ($API_SERVICE in $TARGET_PROJECT): ✓ already"
    return
  fi
  echo "step 1: enabling $API_SERVICE in $TARGET_PROJECT ..."
  if ! gcloud services enable "$API_SERVICE" --project="$TARGET_PROJECT"; then
    log_line "step 1 play integrity api: – skipped (gcloud services enable failed — see terminal output above)"
    mark_incomplete; return
  fi
  pace
  listed="$(gcloud services list --enabled --project="$TARGET_PROJECT" \
      --filter="config.name=$API_SERVICE" --format='value(config.name)' 2>/dev/null)"
  if [[ "$listed" == "$API_SERVICE" ]]; then
    log_line "step 1 play integrity api ($API_SERVICE in $TARGET_PROJECT): ✓ applied"
  else
    log_line "step 1 play integrity api: – skipped (enable ran but the service does not list as enabled yet — propagation lag; the loop's next pass re-checks)"
    mark_incomplete
  fi
}

# Step 2 — confirm the decode service account exists in
# play-publisher-513614. The account is pinned exactly (see
# DECODE_SA_EMAIL above): the Worker secret PLAY_INTEGRITY_SA_JSON
# is the play-api account's key per the Nov 7, 2026 build record.
# If the pinned account is absent from the project's list, stop
# loudly and print everything — nothing is granted.
step2() {
  local listing
  if ! listing="$(gcloud iam service-accounts list --project="$SA_PROJECT" \
      --format='value(email,displayName)' 2>/dev/null)"; then
    log_line "step 2 decode service account: – skipped (could not list service accounts in $SA_PROJECT)"
    mark_incomplete; return
  fi
  if [[ -z "$listing" ]]; then
    log_line "step 2 decode service account: ✗ STOPPED — no service accounts at all listed in $SA_PROJECT (unexpected; nothing granted)"
    mark_stop; return
  fi
  if printf '%s\n' "$listing" | awk '{print $1}' | grep -qx "$DECODE_SA_EMAIL"; then
    SA_EMAIL="$DECODE_SA_EMAIL"
    log_line "step 2 decode service account: ✓ found $SA_EMAIL (pinned decode account present in $SA_PROJECT)"
    return
  fi
  # Pinned account absent: print everything and stop WITHOUT
  # granting anything.
  log_line "step 2 decode service account: ✗ STOPPED — pinned decode account $DECODE_SA_EMAIL not found in $SA_PROJECT; nothing was granted. All service accounts in $SA_PROJECT:"
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && log_line "  sa: $line"
  done <<< "$listing"
  log_line "step 2: send this list to Muse — the pinned account no longer matches reality, and the script must be re-pinned before any grant is made."
  mark_stop
}

# Step 3 — Service Usage Consumer grant in family-routines-app.
step3() {
  local existing
  existing="$(gcloud projects get-iam-policy "$TARGET_PROJECT" \
      --flatten='bindings[].members' \
      --filter="bindings.role=$GRANT_ROLE AND bindings.members=serviceAccount:$SA_EMAIL" \
      --format='value(bindings.role)' 2>/dev/null)"
  if [[ "$existing" == "$GRANT_ROLE" ]]; then
    log_line "step 3 grant $GRANT_ROLE to $SA_EMAIL in $TARGET_PROJECT: ✓ already"
    return
  fi
  pace
  echo "step 3: granting $GRANT_ROLE to $SA_EMAIL in $TARGET_PROJECT ..."
  if ! gcloud projects add-iam-policy-binding "$TARGET_PROJECT" \
      --member="serviceAccount:$SA_EMAIL" --role="$GRANT_ROLE"; then
    log_line "step 3 grant: – skipped (add-iam-policy-binding failed — see terminal output above)"
    mark_incomplete; return
  fi
  existing="$(gcloud projects get-iam-policy "$TARGET_PROJECT" \
      --flatten='bindings[].members' \
      --filter="bindings.role=$GRANT_ROLE AND bindings.members=serviceAccount:$SA_EMAIL" \
      --format='value(bindings.role)' 2>/dev/null)"
  if [[ "$existing" == "$GRANT_ROLE" ]]; then
    log_line "step 3 grant $GRANT_ROLE to $SA_EMAIL in $TARGET_PROJECT: ✓ applied"
  else
    log_line "step 3 grant: – skipped (binding did not verify in the project policy after the grant — propagation lag; the loop's next pass re-checks)"
    mark_incomplete
  fi
}

commit_results() {
  (
    cd "$REPO_ROOT" || return
    git add -- hh-integrity-fix-results.txt 2>/dev/null || return
    if git diff --cached --quiet -- hh-integrity-fix-results.txt 2>/dev/null; then
      echo "results: unchanged — nothing to commit"
      return
    fi
    if ! git commit -q -m "hh-integrity-fix results $(date '+%Y-%m-%d %H:%M')" -- hh-integrity-fix-results.txt 2>/dev/null; then
      echo "results: commit failed (file is saved locally at $RESULTS)"
      return
    fi
    if git push -q origin HEAD 2>/dev/null; then
      echo "results: committed and pushed"
    else
      echo "results: committed locally — push failed, will ride the next push"
    fi
  )
}

finalize() {
  if [[ "$OVERALL_OK" == "1" ]]; then
    log_line "summary: OK — the Play Integrity API is enabled in $TARGET_PROJECT and $SA_EMAIL holds $GRANT_ROLE there"
    log_line "NEXT STEP: wait ~3 minutes for propagation, then re-tap ENROLL THIS DEVICE in Home Helper."
  elif [[ "$STOP_LOUD" == "1" ]]; then
    log_line "summary: STOPPED — a retry-proof condition (see above); nothing further was attempted and no grant was made beyond any step already marked ✓ applied"
  else
    log_line "summary: INCOMPLETE — one or more steps skipped (see above); re-running is safe"
  fi
  commit_results
}

main() {
  log_line "hh-integrity-fix run — $(date '+%Y-%m-%d %H:%M:%S %Z') (Home Helper $APP_PACKAGE enrollment: Play Integrity decode authorization in $TARGET_PROJECT, project $TARGET_PROJECT_NUMBER)"
  preflight
  if [[ "$STOP_LOUD" == "0" ]]; then step1; fi
  if [[ "$STOP_LOUD" == "0" ]]; then step2; fi
  if [[ "$STOP_LOUD" == "0" ]]; then step3; fi
  finalize
  if [[ "$STOP_LOUD" == "1" ]]; then exit 3; fi
  exit $((1 - OVERALL_OK))
}

# Loop wrapper (default mode): Andrew runs one command and the
# script babysits itself. Each attempt re-pulls the repo — so a
# fix pushed mid-loop is picked up automatically — then runs one
# full pass as a CHILD invocation of the freshly pulled script
# (`--once`), which commits+pushes its own results as the audit
# trail. A failed git pull (offline, conflict) never kills the
# loop: it is noted and the local copy runs. The wrapper only
# prints to the terminal; it writes no files of its own. A child
# exit of 3 (stopped loudly) ends the loop immediately.
loop_main() {
  local delays=(${HH_LOOP_DELAYS:-60 180 300})
  local max_attempts=20 attempt delay idx rc
  local self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! git -C "$REPO_ROOT" pull -q >/dev/null 2>&1; then
      echo "--- git pull failed — continuing with the local copy ---"
    fi
    bash "$self" --once "$@"; rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "--- hh-integrity-fix: SUCCESS on attempt $attempt/$max_attempts ---"
      return 0
    fi
    if [[ $rc -eq 3 ]]; then
      echo "--- hh-integrity-fix: STOPPED (retry-proof condition — see hh-integrity-fix-results.txt) ---"
      return 3
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
  ONCE=0
  PASS_ARGS=()
  for _arg in "$@"; do
    if [[ "$_arg" == "--once" ]]; then
      ONCE=1
    else
      PASS_ARGS+=("$_arg")
    fi
  done
  if [[ $ONCE -eq 0 ]]; then
    loop_main "${PASS_ARGS[@]}"
    exit $?
  fi
  main "${PASS_ARGS[@]}"
fi
