# owner-queue — the owner loop's work queue

`scripts/owner-loop.sh` is a resident loop Andrew keeps running in
Termux on his phone. It executes small bash **job scripts** that
Claude queues here, so owner-space work (things that need Andrew's
own accounts, credentials, or phone) doesn't need a fresh one-shot
converger — or a request to Andrew — for every task.

**Trust boundary:** the loop runs, unattended and with Andrew's
credentials, whatever `*.sh` files land in `pending/` of this
repo. Only parties who can push to `andrewdhorowitz/fleet-kit`
can queue jobs — push access to this repo *is* code-execution
access to the phone's Termux environment. Job scripts are
expected to come from Claude (via the fleet PAT) or Andrew.

## Layout

| Path | What it is |
|---|---|
| `pending/` | Jobs waiting to run. Muse commits job scripts here; the loop takes them in filename order. |
| `running/` | The job executing right now (moved here by the loop for the duration). Empty whenever the loop is idle. |
| `done/` | Job scripts that have run, whatever their exit code. The audit trail of what was executed. |
| `results/<jobname>.log` | One log per job: a header (`job`, `started`, `finished`, `exit code`) followed by the job's captured stdout+stderr. Repeat runs of a same-named job overwrite the log. |
| `status.md` | The loop's heartbeat, rewritten every round and committed by the loop (see below). |
| `.loop.lock` | The running instance's PID. Local only — never committed. |

## The job contract

A job is a bash script. Name it so filename order is the order
you want it run — a sortable prefix works well, e.g.
`20261030-0115-short-slug.sh`.

- It runs via `bash <file>` (no exec bit needed) with **cwd = the
  repo root**, **stdin = /dev/null**, under a per-job timeout
  (default 1200s; exit 124 means it was killed by the timeout).
- It must be **non-interactive** (it can never be answered) and
  **idempotent** (if the loop dies mid-job, the job is moved back
  to `pending/` and run again from the top).
- It prints its own report to stdout in the house style —
  `✓ applied` / `✓ already` / `– skipped (reason)` per step —
  and **exits 0 only on verified success**. A nonzero exit is a
  result, not a catastrophe: it lands in the job's log, the script
  still moves to `done/`, and the loop keeps going.
- A job that changes things outside the queue (the convergers
  are the model) commits and pushes its own results itself. The
  loop's commits cover only queue bookkeeping: `pending/`,
  `running/`, `done/`, `results/`, `status.md`.

## How Muse queues and reads

- **Queue:** commit the job script to `owner-queue/pending/` and
  push. The loop picks it up on its next round (default 60s).
- **Read:** `owner-queue/status.md` for liveness and the last
  job's outcome; `owner-queue/results/<jobname>.log` for a job's
  full output and exit code; `owner-queue/done/` confirms a job
  was taken. Nothing about the loop is read from Andrew's
  terminal — if it isn't in this repo, it didn't get reported.
- **Fix the loop itself:** edit `scripts/owner-loop.sh`, commit,
  push. The running loop re-execs the new copy on its next round
  (after a `bash -n` check) — no restart needed.
- **Ask Andrew to start the loop only when it is down** (see
  below). While `status.md` is fresh, queue work silently.

## How Andrew starts and stops it

Start (one paste in Termux; the loop then runs in the foreground
of that session):

```
mkdir -p ~/work; if [ -d ~/work/fleet-kit/.git ]; then git -C ~/work/fleet-kit pull -q; else git clone -q https://github.com/andrewdhorowitz/fleet-kit ~/work/fleet-kit; fi; bash ~/work/fleet-kit/scripts/owner-loop.sh
```

Stop: **Ctrl-C** in that Termux session. The loop finishes the
bookkeeping for any job in flight, writes `flag: STOPPED` to
`status.md`, commits + pushes it, releases its lockfile, and
exits. Starting it twice is refused by the lockfile; a stale lock
from a dead process is reclaimed automatically.

## Down detection

`status.md` carries an `updated:` timestamp (America/New_York)
that the loop refreshes every round; status-only changes are
committed at least every ~15 minutes, and any round that runs a
job commits immediately. Therefore:

- **`updated:` older than ~30 minutes — or `flag:` reads
  `STOPPED` — means the loop is down.** That is the only
  situation in which Muse asks Andrew to start it.
- A fresh `flag: ALIVE` means queue freely; results land in
  `results/` without any action from Andrew.
