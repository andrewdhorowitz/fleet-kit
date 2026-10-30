#!/usr/bin/env bash
# owner-loop.sh — the resident OWNER LOOP for fleet-kit.
#
# WHAT IT IS: a persistent loop Andrew keeps running in Termux on
# his phone. It watches this repo's owner-queue/pending/ directory:
# Muse queues owner-space work by committing small bash job
# scripts there; the loop pulls, runs each job, commits the
# results back to this repo, and waits for the next one. One loop
# serves every purpose — instead of a fresh one-shot converger per
# task, queue a job. (The one-shot convergers, e.g.
# scripts/firebase-converge.sh and
# scripts/codespaces-prebuild-converge.sh, remain the pattern for
# a job's own internals: check -> apply -> report.)
#
# TRUST BOUNDARY — READ THIS: the loop executes, unattended and
# with Andrew's own credentials, WHATEVER *.sh files land in
# owner-queue/pending/ of this repo. Only parties who can push to
# andrewdhorowitz/fleet-kit can queue jobs. Treat push access to
# this repo as code-execution access to the phone's Termux
# environment, because it is. Job scripts are expected to come
# from Claude (via the fleet PAT) or from Andrew himself.
#
# HOW IT RUNS: in Termux, from a clone of fleet-kit at
# ~/work/fleet-kit:
#   bash ~/work/fleet-kit/scripts/owner-loop.sh
# Stop it with Ctrl-C (SIGINT/SIGTERM also work): the loop
# finishes the bookkeeping for any job in flight, writes
# flag: STOPPED to owner-queue/status.md, commits + pushes that,
# releases its lockfile, and exits. Only ONE instance may run per
# clone: a lockfile (owner-queue/.loop.lock, never committed)
# makes a second instance refuse to start; a stale lock (holder
# PID no longer alive) is reclaimed automatically.
#
# EACH ROUND (default every 60s, OWNER_LOOP_INTERVAL):
#   1. git pull (rebase + autostash: the phone's local commits
#      are loop output — results + status — so they replay onto
#      origin, and autostash carries the loop's own uncommitted
#      status writes across the rebase so they never block it;
#      a conflict in owner-queue/status.md alone — mid-rebase or
#      in the autostash re-apply — auto-resolves for the local
#      side, since write_status()
#      regenerates that file every round anyway; any other
#      conflict aborts the rebase cleanly and is noted in
#      status.md) — failure is tolerated: noted on the terminal
#      and in status.md, an increasing backoff is added to the
#      round sleep, and the loop keeps going on the local copy.
#      A push rejected as non-fast-forward heals the same way:
#      the next round's rebase runs before commit_queue(), which
#      always re-attempts the push.
#   2. Self-update: if the pulled owner-loop.sh differs from the
#      running copy and parses (bash -n), the loop re-execs
#      itself, so fixes Muse pushes land WITHOUT Andrew
#      restarting anything. The loop always executes a private
#      snapshot copy of itself (taken at start and at each
#      re-exec), never the repo file directly — the same
#      protection the one-shot convergers get from running each
#      pass as a child process — so a mid-run pull can never
#      corrupt the running interpreter.
#   3. Every owner-queue/pending/*.sh, in name order: moved to
#      owner-queue/running/, executed (see JOB CONTRACT),
#      stdout+stderr captured to owner-queue/results/<jobname>.log
#      under a result header (job, started, finished, exit code),
#      the script moved to owner-queue/done/, and the queue
#      changes (results + moves + status) committed + pushed.
#   4. owner-queue/status.md rewritten (flag line, alive
#      timestamp in America/New_York time, round count, last job
#      + exit code, pending count, last push state). Rounds that
#      ran a job always commit; status-only changes are committed
#      at most every ~15 minutes (OWNER_LOOP_STATUS_COMMIT_EVERY)
#      to avoid commit spam.
# A failed job is a RESULT, never a loop exit: the loop survives
# any job outcome, including timeouts (per-job timeout default
# 1200s, OWNER_LOOP_JOB_TIMEOUT; exit 124 = timed out). A job
# found in running/ at startup (the loop died mid-job) is moved
# back to pending/ and re-run — jobs must be idempotent.
#
# JOB CONTRACT (full text in owner-queue/README.md): a job is a
# bash script. It runs via `bash <file>` (no exec bit needed)
# with cwd = the repo root and stdin = /dev/null; it must be
# non-interactive and idempotent, print its own report to stdout
# in the house style ("✓ applied" / "✓ already" / "– skipped
# (reason)"), and exit 0 ONLY on verified success. Muse reads
# owner-queue/results/*.log and owner-queue/status.md from
# GitHub — never terminal output.
#
# ENV KNOBS: OWNER_LOOP_INTERVAL (round sleep seconds, default
# 60), OWNER_LOOP_JOB_TIMEOUT (seconds, default 1200),
# OWNER_LOOP_STATUS_COMMIT_EVERY (seconds, default 900),
# OWNER_LOOP_MAX_ROUNDS (0 = forever, default 0; a test knob —
# after that many rounds the loop stops cleanly, exactly as if
# it had been signalled).
#
# Usage: bash scripts/owner-loop.sh

set -u
shopt -s nullglob

# --- paths ------------------------------------------------------
# SELF_PATH is the repo copy of this script. The running process
# may be a snapshot copy living elsewhere (see the bootstrap
# below); OWNER_LOOP_SELF carries the repo path across execs.
SELF_PATH="${OWNER_LOOP_SELF:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")}"
SCRIPT_DIR="$(dirname "$SELF_PATH")"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

QUEUE_DIR="$REPO_ROOT/owner-queue"
PENDING_DIR="$QUEUE_DIR/pending"
RUNNING_DIR="$QUEUE_DIR/running"
DONE_DIR="$QUEUE_DIR/done"
RESULTS_DIR="$QUEUE_DIR/results"
STATUS_FILE="$QUEUE_DIR/status.md"
LOCK_FILE="$QUEUE_DIR/.loop.lock"
QPATHS=(owner-queue/pending owner-queue/running owner-queue/done owner-queue/results owner-queue/status.md)

# --- knobs & state ----------------------------------------------
INTERVAL="${OWNER_LOOP_INTERVAL:-60}"
JOB_TIMEOUT="${OWNER_LOOP_JOB_TIMEOUT:-1200}"
STATUS_COMMIT_EVERY="${OWNER_LOOP_STATUS_COMMIT_EVERY:-900}"
MAX_ROUNDS="${OWNER_LOOP_MAX_ROUNDS:-0}"

ROUND="${OWNER_LOOP_ROUNDS:-0}"
RESTARTS="${OWNER_LOOP_RESTARTS:-0}"
STARTED="${OWNER_LOOP_STARTED:-}"
LAST_JOB_DESC="none yet"
LAST_PUSH_DESC="never"
LAST_STATUS_COMMIT=0
GIT_FAILS=0
PULL_NOTE=""
STOP_REQUESTED=0
CURRENT_JOB=""
STATUS_NOTE=""
ORIG_ARGS=("$@")

now_et() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S %Z'; }
now_epoch() { date +%s; }
self_sum() { cksum "$SELF_PATH" 2>/dev/null | awk '{print $1"-"$2}'; }
SELF_SUM=""

[[ -n "$STARTED" ]] || STARTED="$(now_et)"

# --- status -----------------------------------------------------
write_status() {
  local flag="$1"
  local pend=( "$PENDING_DIR"/*.sh )
  local running_desc="none"
  [[ -n "$CURRENT_JOB" ]] && running_desc="$CURRENT_JOB"
  {
    echo "# owner-loop status"
    echo "flag: $flag"
    echo "updated: $(now_et)"
    echo "loop: started $STARTED · round $ROUND · restarts $RESTARTS"
    echo "last job: $LAST_JOB_DESC"
    echo "pending: ${#pend[@]} job(s) · running: $running_desc"
    echo "last push: $LAST_PUSH_DESC"
    [[ -n "$STATUS_NOTE" ]] && echo "note: $STATUS_NOTE"
  } > "$STATUS_FILE"
}

# --- git ----------------------------------------------------------
# Stage exactly the queue paths the loop manages (never the
# lockfile, never a job's own side effects outside the queue),
# commit if they changed, push. Returns 0 iff the push is current.
commit_queue() {
  local msg="$1"
  git add -A -- "${QPATHS[@]}" 2>/dev/null || { LAST_PUSH_DESC="FAILED (git add) $(now_et)"; return 1; }
  if ! git diff --cached --quiet -- "${QPATHS[@]}" 2>/dev/null; then
    if ! git commit -q -m "$msg" -- "${QPATHS[@]}" 2>/dev/null; then
      LAST_PUSH_DESC="FAILED (git commit) $(now_et)"
      return 1
    fi
  fi
  if git push -q origin HEAD 2>/dev/null; then
    LAST_PUSH_DESC="ok $(now_et)"
    return 0
  fi
  LAST_PUSH_DESC="FAILED $(now_et) — will retry next round"
  return 1
}

# A pull --rebase stalls with the rebase left in progress when a
# replayed local commit conflicts with what origin gained in the
# meantime. The one predictable conflict is owner-queue/status.md:
# both sides rewrite it (the loop every round, a push whenever
# Muse-side work carries it along), and its content is disposable
# — write_status() regenerates it wholesale each round. So if the
# ONLY conflicted path is status.md, resolve it for the local side
# and continue: during a rebase, --theirs is the local commit
# being replayed (the freshest local write). Any other conflict
# aborts the rebase cleanly — the tree returns to the pre-pull
# local state and the round continues on the local copy, with the
# reason left in PULL_NOTE for status.md. Returns 0 iff a rebase
# was in progress and has now finished cleanly.
heal_rebase() {
  local i gitdir unmerged
  for ((i = 0; i < 25; i++)); do
    gitdir="$(git rev-parse --git-dir 2>/dev/null)" || return 1
    [[ -d "$gitdir/rebase-merge" || -d "$gitdir/rebase-apply" ]] || return 1
    unmerged="$(git diff --name-only --diff-filter=U 2>/dev/null)"
    if [[ -n "$unmerged" && "$unmerged" != "owner-queue/status.md" ]]; then
      PULL_NOTE="rebase conflict in ${unmerged//$'\n'/ }; rebase aborted"
      git rebase --abort >/dev/null 2>&1 || true
      return 1
    fi
    if [[ "$unmerged" == "owner-queue/status.md" ]]; then
      git checkout --theirs -- owner-queue/status.md 2>/dev/null \
        && git add -- owner-queue/status.md 2>/dev/null \
        || { git rebase --abort >/dev/null 2>&1 || true; return 1; }
    fi
    if ! GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 && [[ -z "$unmerged" ]]; then
      # A replayed commit that became empty can stall --continue;
      # skipping it is safe (its content is already upstream).
      git rebase --skip >/dev/null 2>&1 || true
    fi
    gitdir="$(git rev-parse --git-dir 2>/dev/null)" || return 1
    [[ -d "$gitdir/rebase-merge" || -d "$gitdir/rebase-apply" ]] || return 0
  done
  PULL_NOTE="rebase did not settle; aborted"
  git rebase --abort >/dev/null 2>&1 || true
  return 1
}

# The companion case: the rebase itself succeeded, but the
# --autostash re-apply clashed — the loop's own uncommitted
# status.md write against a status.md change that arrived in the
# same pull. No rebase is in progress then; the tree just has
# conflicted paths. If status.md is the only one, resolve it for
# the local side (the stashed write, --theirs in a stash-apply
# conflict) and drop the spent autostash entry. The pull had
# already landed at that point, so the caller counts it a success.
heal_unmerged_status() {
  local unmerged
  unmerged="$(git diff --name-only --diff-filter=U 2>/dev/null)"
  if [[ -n "$unmerged" && "$unmerged" != "owner-queue/status.md" ]]; then
    # Not auto-resolvable (e.g. a job's own dirty file clashed in
    # the re-apply): leave it for a human, but name it for status.
    PULL_NOTE="conflict left in ${unmerged//$'\n'/ } (not auto-resolved)"
    return 1
  fi
  [[ "$unmerged" == "owner-queue/status.md" ]] || return 1
  git checkout --theirs -- owner-queue/status.md 2>/dev/null || return 1
  git add -- owner-queue/status.md 2>/dev/null || return 1
  if [[ "$(git stash list --format=%gs 2>/dev/null | head -n 1)" == *autostash* ]]; then
    git stash drop -q >/dev/null 2>&1 || true
  fi
  return 0
}

# 0 iff the tree is whole: no rebase in progress, no path left
# unmerged. do_pull judges its outcome by this, not by git's exit
# code alone (see below).
pull_clean() {
  local gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" || return 1
  [[ ! -d "$gitdir/rebase-merge" && ! -d "$gitdir/rebase-apply" ]] || return 1
  [[ -z "$(git diff --name-only --diff-filter=U 2>/dev/null)" ]]
}

# Pull with an explicit reconcile strategy: local commits (loop
# output) rebase onto origin. --autostash because status.md sits
# dirty in the tree between heartbeat commits, and a rebase pull
# refuses a dirty tree outright ("cannot pull with rebase: You
# have unstaged changes" — the same wall a manual pull from a
# second session hits while the loop is running). On failure, the
# heal steps get their chance before the round falls back to the
# local copy. Success is judged by the state left behind, not
# the exit code: git exits 0 even when the autostash re-apply
# conflicted (stash kept, path left unmerged), and a stalled
# rebase hides behind a nonzero exit the heals can still finish.
# The pull counts as landed iff it exited cleanly or a heal
# completed the integration AND the tree is whole again — a fetch
# that never reached origin satisfies neither.
do_pull() {
  PULL_NOTE=""
  local landed=0
  git pull -q --rebase --autostash >/dev/null 2>&1 && landed=1
  heal_rebase && landed=1
  heal_unmerged_status && landed=1
  if [[ $landed -eq 1 ]] && pull_clean; then
    GIT_FAILS=0
    case "$STATUS_NOTE" in "git pull failed"*) STATUS_NOTE="" ;; esac
    return 0
  fi
  GIT_FAILS=$((GIT_FAILS + 1))
  echo "--- owner-loop: git pull failed ($GIT_FAILS in a row) — continuing with the local copy ---"
  STATUS_NOTE="git pull failed ($GIT_FAILS in a row)${PULL_NOTE:+ — $PULL_NOTE} — continuing on the local copy"
  return 1
}

# --- lock ---------------------------------------------------------
acquire_lock() {
  if ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
    return 0
  fi
  local pid=""
  pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
  if [[ -n "$pid" && "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "owner-loop: already running (pid $pid) — refusing to start a second instance"
    echo "owner-loop: if that is wrong, remove $LOCK_FILE and start again"
    return 1
  fi
  # Stale lock, or our own PID handed over by a re-exec: reclaim.
  echo "$$" > "$LOCK_FILE"
  return 0
}

release_lock() {
  if [[ -f "$LOCK_FILE" && "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
    rm -f "$LOCK_FILE"
  fi
}

# --- self-update --------------------------------------------------
# If the repo copy changed under us (a pull landed a fix) and the
# new copy parses, re-exec it through the snapshot bootstrap so
# the running interpreter's file is again a private copy.
self_update_check() {
  local cur=""
  cur="$(self_sum)"
  [[ -n "$cur" && -n "$SELF_SUM" && "$cur" != "$SELF_SUM" ]] || return 0
  if ! bash -n "$SELF_PATH" 2>/dev/null; then
    echo "--- owner-loop: pulled update fails bash -n — staying on the running copy ---"
    STATUS_NOTE="pulled owner-loop.sh update has a syntax error; still running the previous copy"
    return 0
  fi
  echo "--- owner-loop: script updated upstream — re-execing the new copy ---"
  OWNER_LOOP_SELF="$SELF_PATH" OWNER_LOOP_SNAPSHOT="" \
  OWNER_LOOP_ROUNDS="$ROUND" OWNER_LOOP_RESTARTS=$((RESTARTS + 1)) \
  OWNER_LOOP_STARTED="$STARTED" \
    exec bash "$SELF_PATH" "${ORIG_ARGS[@]}"
  # exec replaces this process; reaching this line means it failed.
  echo "--- owner-loop: re-exec failed — continuing on the running copy ---"
  SELF_SUM="$cur"
}

# --- one job ------------------------------------------------------
run_one_job() {
  local src="$1" name log tmp started finished code
  name="$(basename "$src")"
  log="$RESULTS_DIR/$name.log"
  echo "--- owner-loop: job $name (round $ROUND) ---"
  mv -- "$src" "$RUNNING_DIR/$name" || { echo "--- owner-loop: could not move $name to running/ — skipping ---"; return; }
  CURRENT_JOB="$name"
  write_status "ALIVE"
  tmp="$(mktemp)"
  started="$(now_et)"
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$REPO_ROOT" && timeout -k 30 "$JOB_TIMEOUT" bash "$RUNNING_DIR/$name" </dev/null >"$tmp" 2>&1 )
    code=$?
  else
    ( cd "$REPO_ROOT" && bash "$RUNNING_DIR/$name" </dev/null >"$tmp" 2>&1 )
    code=$?
  fi
  finished="$(now_et)"
  {
    echo "# owner-loop result"
    echo "# job: $name"
    echo "# started: $started"
    echo "# finished: $finished"
    echo "# exit code: $code"
    echo "# ---- job output ----"
    cat "$tmp"
  } > "$log"
  rm -f "$tmp"
  mv -- "$RUNNING_DIR/$name" "$DONE_DIR/$name" 2>/dev/null || true
  CURRENT_JOB=""
  if [[ $code -eq 124 ]]; then
    LAST_JOB_DESC="$name — exit 124 (timed out after ${JOB_TIMEOUT}s) at $finished"
  else
    LAST_JOB_DESC="$name — exit $code at $finished"
  fi
  echo "--- owner-loop: job $name — exit $code ---"
  write_status "ALIVE"
  commit_queue "owner-loop: $name exit $code $finished" || true
}

# --- sleep ---------------------------------------------------------
# Chunked so a stop signal is honored within a few seconds even
# when the signal reaches only this process, not the sleep child.
sleep_round() {
  local total="$1" elapsed=0 step
  while [[ $elapsed -lt $total && $STOP_REQUESTED -eq 0 ]]; do
    step=$((total - elapsed))
    [[ $step -gt 5 ]] && step=5
    sleep "$step"
    elapsed=$((elapsed + step))
  done
}

# --- shutdown ------------------------------------------------------
shutdown() {
  CURRENT_JOB=""
  write_status "STOPPED"
  commit_queue "owner-loop: stopped $(now_et)" || true
  echo "owner-loop: stopped after $ROUND round(s) — status committed (flag: STOPPED)"
}

# --- main -----------------------------------------------------------
main() {
  cd "$REPO_ROOT" || { echo "owner-loop: cannot cd to repo root $REPO_ROOT"; return 1; }
  if ! command -v git >/dev/null 2>&1; then
    echo "owner-loop: git is not installed — in Termux: pkg install git"
    return 1
  fi
  mkdir -p "$PENDING_DIR" "$RUNNING_DIR" "$DONE_DIR" "$RESULTS_DIR"
  if ! acquire_lock; then
    return 1
  fi
  trap 'release_lock' EXIT
  trap 'STOP_REQUESTED=1' INT TERM

  # Crash recovery: a job left in running/ (the loop died mid-job)
  # goes back to pending/ and will run again — jobs are idempotent.
  local stuck=( "$RUNNING_DIR"/*.sh ) s
  for s in "${stuck[@]}"; do
    mv -- "$s" "$PENDING_DIR/" 2>/dev/null \
      && echo "--- owner-loop: recovered $(basename "$s") from running/ back to pending/ ---"
  done

  SELF_SUM="$(self_sum)"
  echo "owner-loop: alive — repo $REPO_ROOT"
  echo "owner-loop: round interval ${INTERVAL}s · job timeout ${JOB_TIMEOUT}s · Ctrl-C to stop"
  write_status "ALIVE"
  commit_queue "owner-loop: started $(now_et)" || true
  LAST_STATUS_COMMIT="$(now_epoch)"

  local jobs ran extra
  while [[ $STOP_REQUESTED -eq 0 ]]; do
    ROUND=$((ROUND + 1))
    do_pull || true
    self_update_check
    jobs=( "$PENDING_DIR"/*.sh )
    ran=0
    for s in "${jobs[@]}"; do
      [[ $STOP_REQUESTED -eq 0 ]] || break
      run_one_job "$s"
      ran=1
    done
    if [[ $ran -eq 1 ]]; then
      LAST_STATUS_COMMIT="$(now_epoch)"
    else
      write_status "ALIVE"
      if [[ $(( $(now_epoch) - LAST_STATUS_COMMIT )) -ge $STATUS_COMMIT_EVERY ]]; then
        commit_queue "owner-loop: heartbeat $(now_et)" || true
        LAST_STATUS_COMMIT="$(now_epoch)"
      fi
    fi
    if [[ $MAX_ROUNDS -gt 0 && $ROUND -ge $MAX_ROUNDS ]]; then
      STATUS_NOTE="stopped after $MAX_ROUNDS round(s) (OWNER_LOOP_MAX_ROUNDS test knob)"
      break
    fi
    extra=0
    if [[ $GIT_FAILS -gt 0 ]]; then
      extra=$((GIT_FAILS * 30))
      [[ $extra -gt 300 ]] && extra=300
    fi
    sleep_round $((INTERVAL + extra))
  done
  shutdown
  return 0
}

# --- snapshot bootstrap --------------------------------------------
# Never execute the repo file directly: bash reads a script file
# incrementally while it runs, so a git pull replacing
# scripts/owner-loop.sh mid-run could corrupt this process. Take a
# private snapshot copy and exec THAT; SELF_PATH keeps pointing at
# the repo copy for pull/self-update comparisons. (The one-shot
# convergers get the same protection by running each pass as a
# child process; a resident loop snapshots instead.)
if [[ "${OWNER_LOOP_SNAPSHOT:-}" != "1" ]]; then
  _snapdir="$(mktemp -d)"
  cp "$SELF_PATH" "$_snapdir/owner-loop.sh"
  OWNER_LOOP_SELF="$SELF_PATH" OWNER_LOOP_SNAPSHOT="1" \
    exec bash "$_snapdir/owner-loop.sh" "$@"
  echo "owner-loop: snapshot exec failed" >&2
  exit 1
fi

main "$@"
