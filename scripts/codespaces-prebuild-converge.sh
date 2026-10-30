#!/usr/bin/env bash
# codespaces-prebuild-converge.sh — one-shot converger for GitHub
# Codespaces PREBUILD CONFIGURATIONS across every repo Andrew owns.
#
# Runs on Andrew's phone (Termux) under his own `gh` auth
# (andrewdhorowitz) — TERMUX ONLY, no browser sign-in, no PAT.
# Why this exists: a prebuild configuration makes GitHub rebuild
# and store a codespace snapshot on every trigger (for
# family-cards-demo: every push — 39 runs on Oct 29, 2026 alone),
# and the snapshots draw on the account's shared 15 GB Codespaces
# storage. Exactly one repo is known to carry a configuration
# (family-cards-demo); this script checks ALL of them.
#
# API REALITY (verified Oct 29–30, 2026 — read before "fixing"):
# GitHub's Codespaces REST reference documents NO endpoint for
# prebuild configurations; the documented management path is the
# UI (repo Settings -> Codespaces). The natural probe,
#   GET /repos/{owner}/{repo}/codespaces/prebuild-configurations
# returned 404 under the fleet fine-grained PAT on every repo
# tried, and disabling the managed workflow via the Actions API
# returned 422 "Unable to disable this workflow" (and disabling
# would not delete stored prebuilds anyway). So this script:
#   1. Probes the config endpoint under the RUNNER's auth anyway —
#      an owner OAuth token may fare better than the fleet PAT.
#      If it answers, the script lists, deletes what it finds
#      (DELETE .../codespaces/prebuild-configurations/{id}), and
#      verifies by re-listing (expect empty).
#   2. Where the endpoint is unavailable (404/403/422), falls back
#      to the one reliable signal: the managed "Dev Environment
#      Prebuilds" workflow (path
#      dynamic/codespaces/create_codespaces_prebuilds) in the
#      repo's Actions workflow list — a read verified working
#      Oct 29–30. The workflow is created by the Codespaces
#      service when a configuration exists: present = a
#      configuration is (or was) there; absent = none.
#   3. Repos it cannot clear through the API are reported
#      UI-required with the exact settings URL
#      (https://github.com/<owner>/<repo>/settings/codespaces)
#      so the human step is one tap: ellipsis -> Delete -> OK.
#
# Converger contract: check -> apply what's missing -> report
# "✓ applied" / "✓ already" / "– UI-required" / "– skipped
# (reason)" per repo, into scripts/codespaces-prebuild-results.md
# (flushed per line, then committed + pushed by the script).
# SUCCESS for this converger is a COMPLETE, VERIFIED REPORT:
# deletion may be UI-only, so a pass where every repo is either
# config-free or honestly reported UI-required (with its URL)
# exits 0. INCOMPLETE is reserved for checks that could not be
# made at all (transport/5xx/auth/enumeration failures); on any
# incomplete pass the script also writes
# scripts/codespaces-prebuild-errors.txt (run stderr + API error
# bodies) and commits + pushes both files, so the failure can be
# read from GitHub and the script fixed without screenshots.
# Idempotent; safe to re-run — after a UI deletion, a re-run
# reports "✓ already" wherever the API can verify it, and says so
# plainly where the managed-workflow entry may linger as history.
#
# Every pass writes a machine-readable outcome flag as the second
# line of the results file, directly under the header:
# "flag: SUCCESS" (complete report), "flag: INCOMPLETE" (a check
# could not be made), or "flag: IMPOSSIBLE: <reason>" for
# retry-proof failures (gh missing, gh not signed in). The flag
# is reporting only: it never changes attempts, backoff, or the
# exit code — a pass exits 0 iff the report is complete.
#
# Default invocation LOOPS until a pass completes: each attempt
# re-pulls this repo (picking up script fixes pushed mid-loop),
# runs one pass as a child process (so a replaced script file
# never corrupts a running process), and retries with backoff —
# 60s, 180s, then 300s (CP_LOOP_DELAYS, space-separated,
# overrides) — up to 20 attempts. --once runs a single pass and
# exits with that pass's real status. Note the loop normally
# finishes on attempt 1: UI-required repos do not make a pass
# incomplete, so after running this once, do the settings-page
# tap(s) it lists, then run it again to verify.
#
# Usage:
#   bash scripts/codespaces-prebuild-converge.sh          (loop)
#   bash scripts/codespaces-prebuild-converge.sh --once   (one pass)

PREBUILD_WORKFLOW_PATH="dynamic/codespaces/create_codespaces_prebuilds"
PREBUILD_WORKFLOW_NAME="Dev Environment Prebuilds"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS="$REPO_ROOT/scripts/codespaces-prebuild-results.md"
ERRORS_FILE="$REPO_ROOT/scripts/codespaces-prebuild-errors.txt"

OVERALL_OK=1
PERMANENT_REASON=""
LOGIN=""
WORKDIR=""
STDERR_LOG="/dev/null"
API_ERR_LOG="/dev/null"
API_CODE=""
API_BODY=""
UI_REQUIRED_COUNT=0
DELETED_COUNT=0
CLEAN_COUNT=0

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

# One gh REST call. Sets API_CODE ("" on transport failure) and
# leaves the response body in $API_BODY. HTTP errors are logged
# to the API error log for the errors file.
api_call() {
  local method="$1" path="$2" raw="$WORKDIR/api-raw.txt"
  API_BODY="$WORKDIR/api-body.txt"
  : > "$API_BODY"
  API_CODE=""
  gh api -i --method "$method" "$path" > "$raw" 2>>"$STDERR_LOG"
  API_CODE="$(python3 - "$raw" "$API_BODY" <<'PY'
import re, sys
try:
    raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
except Exception:
    print("")
    raise SystemExit
m = re.search(r"HTTP/\S+\s+(\d{3})", raw)
parts = re.split(r"\r?\n\r?\n", raw, maxsplit=1)
body = parts[1] if len(parts) > 1 else ""
open(sys.argv[2], "w").write(body)
print(m.group(1) if m else "")
PY
)"
  if [[ -n "$API_CODE" && "$API_CODE" -ge 400 ]]; then
    {
      echo "== $method $path -> HTTP $API_CODE"
      head -c 500 "$API_BODY"
      echo ""
    } >> "$API_ERR_LOG"
  fi
}

# First ~300 chars of the current API body, single line — safe to
# embed in a results line.
body_snippet() {
  [[ -n "${API_BODY:-}" && -f "$API_BODY" ]] || { echo "no response body"; return; }
  python3 -c '
import sys
try:
    text = open(sys.argv[1], errors="replace").read()
except Exception:
    print("unparseable error body")
    raise SystemExit
print(" ".join(text.split())[:300])
' "$API_BODY" 2>/dev/null || echo "unparseable error body"
}

# Extract the managed prebuild workflow from an actions/workflows
# list body in $API_BODY. Prints "<state>\t<id>" or nothing.
wf_state() {
  python3 - "$API_BODY" "$PREBUILD_WORKFLOW_PATH" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
for w in d.get("workflows") or []:
    if w.get("path") == sys.argv[2]:
        print("%s\t%s" % (w.get("state", "?"), w.get("id", "?")))
        break
PY
}

# Extract the newest run's "created_at status/conclusion" from a
# workflow runs body in $API_BODY. Prints "" when there are none.
wf_latest_run() {
  python3 - "$API_BODY" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
runs = d.get("workflow_runs") or []
if runs:
    r = runs[0]
    print("%s %s/%s" % (r.get("created_at", "?"), r.get("status", "?"),
                         r.get("conclusion") or "-"))
PY
}

# Parse a prebuild-configurations list body in $API_BODY. Prints
# "COUNT <n>" then one "ID <id>" per configuration, or
# "UNPARSEABLE". Defensive about the envelope: the endpoint is
# undocumented, so accept a bare array or an object carrying the
# list under any of the usual keys.
cfg_parse() {
  python3 - "$API_BODY" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("UNPARSEABLE")
    raise SystemExit
items = None
if isinstance(d, list):
    items = d
elif isinstance(d, dict):
    for key in ("prebuild_configurations", "configurations", "items"):
        if isinstance(d.get(key), list):
            items = d[key]
            break
    if items is None and "id" in d:
        items = [d]
if items is None:
    print("UNPARSEABLE")
    raise SystemExit
print("COUNT %d" % len(items))
for it in items:
    if isinstance(it, dict) and it.get("id") is not None:
        print("ID %s" % it["id"])
PY
}

ensure_tools() {
  local missing=()
  command -v gh >/dev/null 2>&1 || missing+=("gh")
  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v python3 >/dev/null 2>&1 || missing+=("python3")
  if [[ ${#missing[@]} -gt 0 ]]; then
    mark_permanent "missing tool(s): ${missing[*]}"
    log_line "tools: – skipped (not installed: ${missing[*]} — in Termux: pkg install ${missing[*]})"
    return 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    mark_permanent "gh is not signed in"
    log_line "auth: – skipped (gh is not signed in — run: gh auth login)"
    return 1
  fi
  api_call GET "user"
  if [[ "$API_CODE" != "200" ]]; then
    log_line "auth: – skipped (GET /user failed — HTTP ${API_CODE:-transport error}: $(body_snippet))"
    return 1
  fi
  LOGIN="$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("login", ""))
except Exception:
    print("")
' "$API_BODY")"
  if [[ -z "$LOGIN" ]]; then
    log_line "auth: – skipped (could not read the signed-in login from GET /user)"
    return 1
  fi
  log_line "auth: ✓ applied (gh signed in as $LOGIN — repos enumerated under this account)"
  return 0
}

# Enumerate every repo the signed-in account owns, one full name
# ("owner/repo") per line, into $WORKDIR/repos.txt.
enumerate_repos() {
  local out="$WORKDIR/repos.txt"
  : > "$out"
  gh api --paginate "user/repos?per_page=100&affiliation=owner" \
    --jq '.[].full_name' 2>>"$STDERR_LOG" | grep -E '^[^/]+/[^/]+$' >> "$out" || true
  sort -u -o "$out" "$out"
  [[ -s "$out" ]]
}

# Check (and, where the API allows, clear) one repo's prebuild
# configurations. Appends exactly one per-repo results line and
# updates the pass counters. $1 = full name, $2 = repo name.
check_repo() {
  local full="$1" repo="$2"
  local settings_url="https://github.com/$full/settings/codespaces"

  # Signal 1 (verified readable): the managed workflow list.
  api_call GET "repos/$full/actions/workflows?per_page=100"
  if [[ "$API_CODE" != "200" ]]; then
    log_line "- \`$repo\` — – skipped (workflows list failed — HTTP ${API_CODE:-transport error}: $(body_snippet))"
    mark_incomplete
    return
  fi
  local wf="" wf_state_val="" wf_id=""
  wf="$(wf_state)"
  if [[ -n "$wf" ]]; then
    wf_state_val="${wf%%$'\t'*}"
    wf_id="${wf##*$'\t'}"
  fi

  # Signal 2 (probe): the config endpoint itself.
  api_call GET "repos/$full/codespaces/prebuild-configurations"
  local probe_code="$API_CODE"
  case "$probe_code" in
    200)
      local parsed count
      parsed="$(cfg_parse)"
      if [[ "$parsed" == "UNPARSEABLE" ]]; then
        log_line "- \`$repo\` — – skipped (config endpoint answered 200 but the body shape is unrecognized: $(body_snippet))"
        mark_incomplete
        return
      fi
      count="$(echo "$parsed" | awk '/^COUNT /{print $2}')"
      if [[ "$count" == "0" ]]; then
        CLEAN_COUNT=$((CLEAN_COUNT + 1))
        if [[ -n "$wf" ]]; then
          log_line "- \`$repo\` — ✓ already (config API verifies: no prebuild configurations — the managed workflow entry still listed is leftover run history)"
        else
          log_line "- \`$repo\` — ✓ already (config API verifies: no prebuild configurations)"
        fi
        return
      fi
      # Configurations found and the API is answering: delete
      # each. IDs are collected into an array first — a while-read
      # loop would share stdin with the gh calls inside it.
      local ids=() _id
      while read -r _ _id; do
        [[ -n "${_id:-}" ]] && ids+=("$_id")
      done <<EOF
$(echo "$parsed" | grep '^ID ' || true)
EOF
      local id deleted=0 refused=""
      for id in "${ids[@]}"; do
        api_call DELETE "repos/$full/codespaces/prebuild-configurations/$id"
        if [[ "$API_CODE" == "204" || "$API_CODE" == "200" ]]; then
          deleted=$((deleted + 1))
        else
          refused="$API_CODE"
        fi
      done
      # Verify by re-listing.
      api_call GET "repos/$full/codespaces/prebuild-configurations"
      local after="?"
      if [[ "$API_CODE" == "200" ]]; then
        after="$(cfg_parse | awk '/^COUNT /{print $2}')"
      fi
      if [[ "$after" == "0" ]]; then
        DELETED_COUNT=$((DELETED_COUNT + 1))
        log_line "- \`$repo\` — ✓ applied (deleted $deleted prebuild configuration(s) via the API; re-list verifies empty)"
      else
        UI_REQUIRED_COUNT=$((UI_REQUIRED_COUNT + 1))
        log_line "- \`$repo\` — – UI-required ($count configuration(s) found; API deletion ${refused:+refused, HTTP $refused }did not clear them — delete at $settings_url)"
      fi
      ;;
    404|403|422)
      # Endpoint unavailable under this auth (the documented
      # state of the world): decide from the workflow signal.
      if [[ -z "$wf" ]]; then
        CLEAN_COUNT=$((CLEAN_COUNT + 1))
        log_line "- \`$repo\` — ✓ already (no prebuild configuration — no managed workflow; config endpoint unavailable under this auth, HTTP $probe_code)"
      else
        UI_REQUIRED_COUNT=$((UI_REQUIRED_COUNT + 1))
        local latest=""
        api_call GET "repos/$full/actions/workflows/$wf_id/runs?per_page=1"
        if [[ "$API_CODE" == "200" ]]; then
          latest="$(wf_latest_run)"
        fi
        log_line "- \`$repo\` — – UI-required (managed \"$PREBUILD_WORKFLOW_NAME\" workflow present, state: $wf_state_val${latest:+, latest run $latest}; config endpoint unavailable under this auth, HTTP $probe_code — delete the configuration at $settings_url ; if it is already deleted there, this entry is leftover run history and no action is needed)"
      fi
      ;;
    *)
      log_line "- \`$repo\` — – skipped (config endpoint returned HTTP ${probe_code:-transport error}: $(body_snippet))"
      mark_incomplete
      ;;
  esac
}

compose_errors() {
  {
    echo "codespaces-prebuild-converge errors — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""
    echo "== run stderr =="
    cat "$STDERR_LOG" 2>/dev/null
    echo ""
    echo "== api errors =="
    cat "$API_ERR_LOG" 2>/dev/null
  } > "$ERRORS_FILE"
}

commit_results() {
  (
    cd "$REPO_ROOT" || return
    local files=(scripts/codespaces-prebuild-results.md)
    git add -- scripts/codespaces-prebuild-results.md 2>/dev/null || return
    if [[ "$OVERALL_OK" == "0" ]]; then
      git add -- scripts/codespaces-prebuild-errors.txt 2>/dev/null
      files+=(scripts/codespaces-prebuild-errors.txt)
    elif [[ -f scripts/codespaces-prebuild-errors.txt ]]; then
      # Green run: a stale errors file from an earlier failed run
      # must not linger — remove it so the repo state reads clean.
      rm -f scripts/codespaces-prebuild-errors.txt
      git add -A -- scripts/codespaces-prebuild-errors.txt 2>/dev/null
      files+=(scripts/codespaces-prebuild-errors.txt)
    fi
    if git diff --cached --quiet -- "${files[@]}" 2>/dev/null; then
      echo "results: unchanged — nothing to commit"
      return
    fi
    if ! git commit -q -m "codespaces-prebuild-converge results $(date '+%Y-%m-%d %H:%M')" -- "${files[@]}" 2>/dev/null; then
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
# results line. SUCCESS = complete report (every repo config-free
# or honestly UI-required); IMPOSSIBLE = a permanent failure was
# recorded (first one wins); anything else is INCOMPLETE.
# Reporting only — no behavior depends on it.
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
    if [[ "$UI_REQUIRED_COUNT" -gt 0 ]]; then
      log_line "summary: OK — complete report: $CLEAN_COUNT repo(s) verified config-free, $DELETED_COUNT cleared via the API, $UI_REQUIRED_COUNT need the settings-page tap listed above; re-run after deleting to verify"
    else
      log_line "summary: OK — every repo verified free of prebuild configurations ($CLEAN_COUNT already clean, $DELETED_COUNT cleared via the API)"
    fi
  else
    log_line "summary: INCOMPLETE — one or more repos could not be checked (see above); full error detail in scripts/codespaces-prebuild-errors.txt"
    compose_errors
  fi
  commit_results
}

main() {
  : > "$RESULTS"
  log_line "# codespaces-prebuild-converge results — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  if ! ensure_tools; then
    mark_incomplete
    finalize
    exit 1
  fi
  if ! enumerate_repos; then
    log_line "repos: – skipped (could not enumerate the account's repos via gh)"
    mark_incomplete
    finalize
    exit 1
  fi
  local total full repo
  total="$(wc -l < "$WORKDIR/repos.txt" | tr -d ' ')"
  log_line "repos: ✓ applied (enumerated $total owned repo(s))"
  log_line ""
  log_line "## Per-repo"
  while read -r full; do
    [[ -n "$full" ]] || continue
    repo="${full##*/}"
    check_repo "$full" "$repo"
  done < "$WORKDIR/repos.txt"
  finalize
  exit $((1 - OVERALL_OK))
}

# Loop wrapper (default mode): Andrew runs one command and the
# script babysits itself. Each attempt re-pulls the repo — so a
# fix pushed mid-loop is picked up automatically — then runs one
# full pass as a CHILD invocation of the freshly pulled script
# (`--once`), which commits+pushes its own results/errors as the
# audit trail. A failed git pull (offline, conflict) never kills
# the loop: it is noted and the local copy runs. The wrapper only
# prints to the terminal; it writes no files of its own.
loop_main() {
  local delays=(${CP_LOOP_DELAYS:-60 180 300})
  local max_attempts=20 attempt delay idx
  local self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! git -C "$REPO_ROOT" pull -q >/dev/null 2>&1; then
      echo "--- git pull failed — continuing with the local copy ---"
    fi
    if bash "$self" --once "$@"; then
      echo "--- codespaces-prebuild-converge: SUCCESS on attempt $attempt/$max_attempts ---"
      return 0
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
  WORKDIR="$(mktemp -d)"
  STDERR_LOG="$WORKDIR/stderr.log"
  API_ERR_LOG="$WORKDIR/api-errors.log"
  : > "$STDERR_LOG"
  : > "$API_ERR_LOG"
  trap 'rm -rf "$WORKDIR"' EXIT
  main "${PASS_ARGS[@]}" 2>>"$STDERR_LOG"
fi
