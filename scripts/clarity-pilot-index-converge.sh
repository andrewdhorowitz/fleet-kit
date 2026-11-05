#!/usr/bin/env bash
# clarity-pilot-index-converge.sh — one-shot converger that fixes the
# Homework Clarity PILOT sign-in loop by creating the two missing
# Firestore collection-group field-override indexes in the pilot
# project (gen-lang-client-0590645241).
#
# Diagnosis (2026-11-04, confirmed by Andrew's screenshot 2026-11-05):
# after a successful Google sign-in, the app's findMembership() runs
# collectionGroup("members") where uid == <auth uid>, and findInvite()
# runs collectionGroup("invites") where email == <address>. Single-
# field indexes with COLLECTION_GROUP scope are NOT maintained by
# default, so both queries throw "failed-precondition" ("The query
# requires an index") and the app falls back to the sign-in screen —
# the loop. The live Firestore rules are the fixed version (the
# failure is failed-precondition, not permission-denied), so this
# script touches INDEXES ONLY — never rules, functions, or hosting.
# Full analysis: homework-clarity/SIGNIN-LOOP-DIAGNOSIS-2026-11-04.md
# (Defect A). Index definitions are staged verbatim from
# clarity/firestore/firestore.indexes.json.
#
# Runs on Andrew's phone (Termux) under ANDREW'S OWN Firebase login
# (the pilot project is registered to his fourpshot account; the
# fleet holds no credential for this project). The script never
# handles, prints, or stores any credential value — firebase-tools
# keeps its own login token. If no login exists, the script runs
# `firebase login --no-localhost` in the foreground: Andrew opens
# the printed URL in his browser, signs in as the pilot project's
# owner account, pastes the authorization code back into Termux,
# and the script continues on its own once the login lands.
#
# Converger contract (same as firebase-converge.sh): check -> apply
# only what's missing -> report "✓ applied" / "✓ already" /
# "– skipped (reason)" per step into
# clarity-pilot-index-converge-results.txt at the repo root (flag
# line as line 2: SUCCESS / INCOMPLETE / IMPOSSIBLE: <reason>), then
# commit + push the results. On any incomplete outcome the full
# error detail (run stderr + command output, email addresses
# masked) is written to clarity-pilot-index-converge-errors.txt and
# committed alongside, so a failure can be diagnosed from GitHub
# without screenshots. ONE pass per invocation, ONE deploy attempt
# per run — no retry loop, no repeated deploy spam. Idempotent:
# re-running when the indexes already serve reports ALREADY-CORRECT
# and deploys nothing. Exits nonzero when INCOMPLETE.
#
# The default invocation first re-pulls this repo (best effort —
# a failed pull never blocks the run), then executes one pass as a
# child process so a script file replaced by that pull can never
# corrupt the running pass.
#
# Tunables (env): CP_POLL_INTERVAL (seconds between verify polls,
# default 45), CP_POLL_MAX (max seconds to wait for READY, default
# 480). Index builds on a near-empty database usually finish in
# well under that; if the wait expires the results say so honestly
# and a re-run of the same command becomes a verify-only pass.
#
# Usage:
#   bash scripts/clarity-pilot-index-converge.sh

PROJECT="gen-lang-client-0590645241"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS="$REPO_ROOT/clarity-pilot-index-converge-results.txt"
ERRORS_FILE="$REPO_ROOT/clarity-pilot-index-converge-errors.txt"

# The exact index definitions staged for the deploy — verbatim from
# clarity/firestore/firestore.indexes.json. Do not edit here without
# editing that source of record.
INDEXES_JSON='{"fieldOverrides":[{"collectionGroup":"members","fieldPath":"uid","indexes":[{"order":"ASCENDING","queryScope":"COLLECTION_GROUP"},{"order":"DESCENDING","queryScope":"COLLECTION_GROUP"}]},{"collectionGroup":"invites","fieldPath":"email","indexes":[{"order":"ASCENDING","queryScope":"COLLECTION_GROUP"},{"order":"DESCENDING","queryScope":"COLLECTION_GROUP"}]}],"indexes":[]}'

OVERALL_OK=1
PERMANENT_REASON=""
WORKDIR=""
STDERR_LOG="/dev/null"
DETAIL_LOG="/dev/null"
STAGE_DIR=""

set -u

log_line() { echo "$1" | tee -a "$RESULTS"; }

mark_incomplete() { OVERALL_OK=0; }

# Record a permanent (retry-proof) failure of this pass — the
# results flag reports it as IMPOSSIBLE. The first one wins.
mark_permanent() {
  if [[ -z "$PERMANENT_REASON" ]]; then
    PERMANENT_REASON="$1"
  fi
}

detail() { { echo "=== $*"; } >> "$DETAIL_LOG"; }

# _ensure_pkg CMD PKG -> 0 installed now, 2 already present, 1 failed.
# pkg output is never swallowed: every pkg run's stdout+stderr is
# captured into the detail log so a failed install is diagnosable
# from the committed errors file. The first install of a run is
# preceded by one `pkg update` (captured the same way).
PKG_UPDATED=0
_pkg_run_captured() {
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  {
    echo "=== $* (exit $rc)"
    printf '%s\n' "$out"
    echo ""
  } >> "$DETAIL_LOG"
  return $rc
}
_ensure_pkg() {
  if command -v "$1" >/dev/null 2>&1; then return 2; fi
  if command -v pkg >/dev/null 2>&1; then
    if [[ "$PKG_UPDATED" == "0" ]]; then
      PKG_UPDATED=1
      _pkg_run_captured pkg update
    fi
    _pkg_run_captured pkg install -y "$2"
  fi
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  return 1
}

# firebase-tools comes from npm, not pkg: ensure node/npm first,
# then `npm install -g firebase-tools` (captured) only when the
# firebase command is missing. First install can take a few minutes.
ensure_tools() {
  local installed=() failed=() rc
  {
    echo "=== setup diagnostics (command -v)"
    for c in git python3 node npm firebase pkg; do
      local p
      p="$(command -v "$c" 2>/dev/null || true)"
      echo "$c: ${p:-missing}"
    done
    if command -v firebase >/dev/null 2>&1; then
      echo "firebase --version: $(firebase --version 2>/dev/null || echo unknown)"
    fi
    echo ""
  } >> "$DETAIL_LOG"
  _ensure_pkg git git;         rc=$?; [[ $rc -eq 0 ]] && installed+=(git);     [[ $rc -eq 1 ]] && failed+=(git)
  _ensure_pkg python3 python;  rc=$?; [[ $rc -eq 0 ]] && installed+=(python3); [[ $rc -eq 1 ]] && failed+=(python3)
  _ensure_pkg node nodejs;     rc=$?; [[ $rc -eq 0 ]] && installed+=(node);    [[ $rc -eq 1 ]] && failed+=(node)
  if [[ ${#failed[@]} -gt 0 ]]; then
    log_line "setup: – skipped (could not install: ${failed[*]})"
    return 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    log_line "setup: – skipped (npm missing even though node is present — cannot install firebase-tools)"
    return 1
  fi
  if ! command -v firebase >/dev/null 2>&1; then
    echo "firebase-tools not found — installing via npm (first install can take a few minutes)…"
    _pkg_run_captured npm install -g firebase-tools
    if command -v firebase >/dev/null 2>&1; then
      installed+=(firebase-tools)
    else
      log_line "setup: – skipped (firebase-tools install failed — see errors file)"
      return 1
    fi
  fi
  if [[ ${#installed[@]} -gt 0 ]]; then
    log_line "setup: ✓ applied (installed: ${installed[*]})"
  else
    log_line "setup: ✓ already (git, python3, node, firebase-tools present)"
  fi
  return 0
}

# Run a command with a soft timeout when coreutils `timeout` exists.
run_to() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

# Refresh the project list capture. Returns 0 when firebase reports
# a logged-in session (projects list succeeds and parses).
projects_capture() {
  run_to 120 firebase projects:list --json \
    > "$WORKDIR/projects.json" 2> "$WORKDIR/projects.err"
  local rc=$?
  [[ -s "$WORKDIR/projects.err" ]] && cat "$WORKDIR/projects.err" >> "$DETAIL_LOG"
  [[ $rc -eq 0 ]] || return 1
  python3 - "$WORKDIR/projects.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
start = raw.find("{")
if start < 0:
    sys.exit(1)
try:
    d = json.loads(raw[start:])
except Exception:
    sys.exit(1)
if isinstance(d, dict) and "result" in d:
    d = d["result"]
projects = d if isinstance(d, list) else (d or {}).get("projects")
sys.exit(0 if isinstance(projects, list) else 1)
PY
}

# 0 when the pilot project is visible to the signed-in account.
project_visible() {
  python3 - "$WORKDIR/projects.json" "$PROJECT" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw[raw.find("{"):])
if isinstance(d, dict) and "result" in d:
    d = d["result"]
projects = d if isinstance(d, list) else (d or {}).get("projects") or []
ids = [(p or {}).get("projectId") for p in projects]
sys.exit(0 if sys.argv[2] in ids else 1)
PY
}

# Auth: if firebase has no login, walk Andrew through the
# --no-localhost sign-in in the foreground, then wait (bounded) for
# the session to register. Instructions print to the TERMINAL ONLY
# (not the results file) — they name the owner account, which stays
# out of committed files.
ensure_auth() {
  if projects_capture; then
    log_line "auth: ✓ already (firebase login present)"
  else
    echo ""
    echo "================================================================"
    echo "Firebase sign-in needed — one browser step, then this script"
    echo "continues on its own:"
    echo "  1. The next command prints a Google sign-in URL and then"
    echo "     waits for an authorization code."
    echo "  2. Open that URL in your browser and sign in as"
    echo "     fourpshot@gmail.com — the account that OWNS the pilot"
    echo "     project ($PROJECT). Signing in as any other account"
    echo "     cannot see this project and the script will stop."
    echo "  3. Google shows an authorization code — copy it, come"
    echo "     back here, and paste it at the prompt."
    echo "================================================================"
    echo ""
    detail "auth: running firebase login --no-localhost (interactive)"
    firebase login --no-localhost 2>>"$DETAIL_LOG"
    local login_rc=$?
    detail "auth: firebase login exited $login_rc"
    local tries=0
    while ! projects_capture; do
      tries=$((tries + 1))
      if [[ $tries -gt 6 ]]; then
        log_line "auth: – skipped (firebase login did not register a session — re-run this script and complete the browser sign-in)"
        return 1
      fi
      sleep 10
    done
    log_line "auth: ✓ applied (signed in via firebase login --no-localhost)"
  fi
  if ! project_visible; then
    mark_permanent "pilot project not visible to the signed-in account"
    log_line "auth: – skipped (signed in, but project $PROJECT is not visible to this account — it belongs to the fourpshot owner account; run 'firebase logout' and re-run this script, signing in as that account)"
    return 1
  fi
  log_line "project: ✓ already ($PROJECT visible to the signed-in account)"
  return 0
}

# Check the live field overrides. Writes a verdict word to
# $WORKDIR/verdict.txt — READY (all four overrides present and any
# reported states READY), BUILDING (all present, some still
# building), MISSING (at least one absent), ERROR (listing failed
# or unparseable) — plus a compact found-summary for the results.
check_overrides() {
  run_to 180 firebase firestore:indexes --project "$PROJECT" --json \
    > "$WORKDIR/indexes.json" 2> "$WORKDIR/indexes.err"
  local rc=$?
  if [[ -s "$WORKDIR/indexes.err" ]]; then
    { echo "--- firebase firestore:indexes stderr (rc=$rc) ---"
      cat "$WORKDIR/indexes.err"; echo ""; } >> "$DETAIL_LOG"
  fi
  if [[ $rc -ne 0 ]]; then
    echo "ERROR" > "$WORKDIR/verdict.txt"
    echo "listing command failed (rc=$rc)" > "$WORKDIR/found.txt"
    return 1
  fi
  python3 - "$WORKDIR/indexes.json" "$WORKDIR/verdict.txt" "$WORKDIR/found.txt" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
start = raw.find("{")
verdict, found = "ERROR", "listing output unparseable"
if start >= 0:
    try:
        d = json.loads(raw[start:])
    except Exception:
        d = None
    if d is not None:
        if isinstance(d, dict) and "result" in d:
            d = d["result"]
        overrides = (d or {}).get("fieldOverrides") or []
        have = {}
        states = {}
        for o in overrides:
            key = (o.get("collectionGroup"), o.get("fieldPath"))
            for idx in (o.get("indexes") or []):
                if idx.get("queryScope") == "COLLECTION_GROUP":
                    have[(key, idx.get("order"))] = True
                    st = idx.get("state")
                    if st:
                        states[(key, idx.get("order"))] = st
        required = [(("members", "uid"), "ASCENDING"),
                    (("members", "uid"), "DESCENDING"),
                    (("invites", "email"), "ASCENDING"),
                    (("invites", "email"), "DESCENDING")]
        present = [r for r in required if have.get(r)]
        building = [r for r in present
                    if states.get(r) and states[r] != "READY"]
        found = ("overrides in project: %d field override entr(ies); "
                 "required collection-group entries present: %d/4"
                 % (len(overrides), len(present)))
        if len(present) == 4 and not building:
            verdict = "READY"
        elif len(present) == 4:
            verdict = "BUILDING"
        else:
            verdict = "MISSING"
open(sys.argv[2], "w").write(verdict)
open(sys.argv[3], "w").write(found)
PY
}

# Poll the check until READY or the bounded wait expires.
# Echoes the final verdict word.
verify_poll() {
  local interval="${CP_POLL_INTERVAL:-45}" max="${CP_POLL_MAX:-480}"
  local waited=0 verdict
  while : ; do
    check_overrides
    verdict="$(cat "$WORKDIR/verdict.txt" 2>/dev/null || echo ERROR)"
    if [[ "$verdict" == "READY" || "$verdict" == "ERROR" ]]; then
      echo "$verdict"; return
    fi
    if [[ $waited -ge $max ]]; then
      echo "$verdict"; return
    fi
    echo "verify: state $verdict — waiting ${interval}s for the index build…"
    sleep "$interval"
    waited=$((waited + interval))
  done
}

# The one deploy attempt: stage a minimal temp dir whose
# firebase.json points firestore.indexes at the staged definitions,
# then deploy firestore:indexes ONLY for the pilot project.
deploy_indexes() {
  STAGE_DIR="$(mktemp -d)"
  printf '%s\n' '{"firestore":{"indexes":"firestore.indexes.json"}}' \
    > "$STAGE_DIR/firebase.json"
  printf '%s\n' "$INDEXES_JSON" > "$STAGE_DIR/firestore.indexes.json"
  detail "deploy: staged firebase.json + firestore.indexes.json in $STAGE_DIR"
  ( cd "$STAGE_DIR" && run_to 600 firebase deploy --only firestore:indexes \
      --project "$PROJECT" --non-interactive ) \
    > "$WORKDIR/deploy.log" 2>&1
  local rc=$?
  { echo "--- firebase deploy --only firestore:indexes (rc=$rc) ---"
    cat "$WORKDIR/deploy.log"; echo ""; } >> "$DETAIL_LOG"
  return $rc
}

# Compose the errors file from the run's stderr + detail log, with
# email addresses masked before anything is committed.
compose_errors() {
  {
    echo "clarity-pilot-index-converge errors — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""
    echo "== run stderr =="
    cat "$STDERR_LOG" 2>/dev/null
    echo ""
    echo "== detail log =="
    cat "$DETAIL_LOG" 2>/dev/null
  } | python3 -c '
import re, sys
text = sys.stdin.read()
text = re.sub(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+", "[email]", text)
sys.stdout.write(text)
' > "$ERRORS_FILE"
}

commit_results() {
  (
    cd "$REPO_ROOT" || return
    local files=(clarity-pilot-index-converge-results.txt)
    git add -- clarity-pilot-index-converge-results.txt 2>/dev/null || return
    if [[ "$OVERALL_OK" == "0" ]]; then
      git add -- clarity-pilot-index-converge-errors.txt 2>/dev/null
      files+=(clarity-pilot-index-converge-errors.txt)
    elif [[ -f clarity-pilot-index-converge-errors.txt ]]; then
      # Green run: a stale errors file from an earlier failed run
      # must not linger — remove it so the repo state reads clean.
      rm -f clarity-pilot-index-converge-errors.txt
      git add -A -- clarity-pilot-index-converge-errors.txt 2>/dev/null
      files+=(clarity-pilot-index-converge-errors.txt)
    fi
    if git diff --cached --quiet -- "${files[@]}" 2>/dev/null; then
      echo "results: unchanged — nothing to commit"
      return
    fi
    if ! git commit -q -m "clarity-pilot-index-converge results $(date '+%Y-%m-%d %H:%M')" -- "${files[@]}" 2>/dev/null; then
      echo "results: commit failed (files are saved locally at $RESULTS)"
      return
    fi
    if git push -q origin HEAD 2>/dev/null; then
      if [[ "$OVERALL_OK" == "0" ]]; then
        echo "results: committed and pushed (results + errors)"
      else
        echo "results: committed and pushed"
      fi
    else
      echo "results: committed locally — push failed, will ride the next push"
    fi
  )
}

# Insert the outcome flag as line 2 of the results file (directly
# under the header) and echo it to the terminal like every other
# results line. Reporting only — no behavior depends on it.
write_flag() {
  local flag_line="$1"
  { head -n 1 "$RESULTS"; echo "$flag_line"; tail -n +2 "$RESULTS"; } \
    > "$RESULTS.flagtmp" && mv "$RESULTS.flagtmp" "$RESULTS"
  echo "$flag_line"
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
    log_line "summary: OK — the members.uid and invites.email collection-group overrides are in place; final proof is a fresh sign-in in the Homework Clarity app (the family should load)"
  else
    log_line "summary: INCOMPLETE — see above; full error detail in clarity-pilot-index-converge-errors.txt"
    compose_errors
  fi
  commit_results
}

main() {
  : > "$RESULTS"
  log_line "clarity-pilot-index-converge results — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  log_line "target: project $PROJECT — field overrides members.uid + invites.email (COLLECTION_GROUP, ASC+DESC); indexes only, rules untouched"
  if ! ensure_tools; then
    mark_incomplete; finalize; exit 1
  fi
  if ! ensure_auth; then
    mark_incomplete; finalize; exit 1
  fi
  # Check first: never deploy over a state we could not read.
  check_overrides
  local verdict found
  verdict="$(cat "$WORKDIR/verdict.txt" 2>/dev/null || echo ERROR)"
  found="$(cat "$WORKDIR/found.txt" 2>/dev/null || echo '')"
  case "$verdict" in
    READY)
      log_line "indexes: ✓ already ($found) — ALREADY-CORRECT, nothing deployed"
      finalize; exit 0 ;;
    ERROR)
      log_line "indexes: – skipped (could not read the project's current indexes: $found — nothing deployed; see errors file)"
      mark_incomplete; finalize; exit 1 ;;
    BUILDING)
      log_line "indexes: ✓ already present ($found) — waiting for the build to finish"
      ;;
    *)
      log_line "indexes: check — $found; overrides incomplete, deploying"
      if deploy_indexes; then
        log_line "indexes: ✓ applied (firebase deploy --only firestore:indexes completed)"
      else
        log_line "indexes: – skipped (the one deploy attempt failed — see errors file for the full deploy output; nothing else was changed)"
        mark_incomplete; finalize; exit 1
      fi
      ;;
  esac
  # Verify: poll until READY or the bounded wait expires.
  local final
  final="$(verify_poll)"
  found="$(cat "$WORKDIR/found.txt" 2>/dev/null || echo '')"
  case "$final" in
    READY)
      log_line "verify: ✓ already (all four collection-group overrides present and serving — $found)" ;;
    ERROR)
      log_line "verify: – skipped (index listing failed during verification — the deploy itself completed; re-run this script to verify)"
      mark_incomplete ;;
    *)
      log_line "verify: – skipped (overrides present but still $final after the bounded wait — $found; index builds can take a few more minutes: re-run this same command shortly and it will only verify, then sign in to the app)"
      mark_incomplete ;;
  esac
  finalize
  exit $((1 - OVERALL_OK))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" != "--pass" ]]; then
    # Wrapper: refresh the local clone (best effort), then run the
    # freshly pulled script as a child process — a pull that
    # replaces this file mid-run can never corrupt the pass.
    if ! git -C "$REPO_ROOT" pull -q >/dev/null 2>&1; then
      echo "--- git pull failed — continuing with the local copy ---"
    fi
    bash "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" --pass
    exit $?
  fi
  WORKDIR="$(mktemp -d)"
  STDERR_LOG="$WORKDIR/stderr.log"
  DETAIL_LOG="$WORKDIR/detail.log"
  : > "$STDERR_LOG"
  : > "$DETAIL_LOG"
  trap 'rm -rf "$WORKDIR" ${STAGE_DIR:+"$STAGE_DIR"}' EXIT
  main 2>>"$STDERR_LOG"
fi
