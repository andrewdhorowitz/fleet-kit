# owner-loop status
flag: NOT-STARTED
updated: —
The loop has not run yet. Andrew starts it in Termux (see
owner-queue/README.md); once alive, scripts/owner-loop.sh
rewrites this file every round. While the loop is expected to be
running, an `updated:` timestamp older than ~30 minutes — or a
flag of STOPPED — means the loop is down.
