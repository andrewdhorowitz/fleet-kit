# Workspace SA deposit — Step 0 of the Family Board invitation workflow

Prepared by Muse, Nov 11, 2026. Spec: the invitation-workflow
runbook, Step 0 (`~/workspace/goals/family-board/files/
invitation-workflow-runbook-2026-11-11.md`). Build report:
`~/workspace/goals/family-board/files/
workspace-sa-deposit-package-report-2026-11-11.md`.

**Status: PREPARED, NOT RUN.** Nothing here has executed. The
service-account key does not exist yet — it is created on your
phone, by the script, when you run it.

## What the script does (when run under your login)

1. Checks its inputs first and stops cleanly if any is missing —
   before creating anything.
2. Creates **or reuses exactly one** GCP project
   (`andrew-mw-workspace`, unless you designate another — below)
   under andrewhorowitz3, and enables the Admin SDK API
   (`admin.googleapis.com`) in it. One create, then verify; a
   failed create stops the script — it never tries a second
   project ID.
3. Creates **or reuses one** service account (`mw-groups`) and
   reads back its numeric client ID.
4. If the Worker doesn't already hold the secret: mints **one**
   JSON key into a phone-only temp file, deposits it as the
   `andrew-middleware` Worker secret `GCP_WORKSPACE_SA_KEY` via
   the Cloudflare API, shreds the temp file, and verifies the
   secret **by name** (values are never returned or printed).
5. Deposits `WORKSPACE_ADMIN_EMAIL` the same way, from your
   on-device file.
6. Prints the delegation block (client ID + the single scope)
   for your Admin-console step, plus a booleans-only summary.
7. Writes its log to `owner-queue/results/
   workspace-sa-deposit.sh.log` in the owner-queue format when
   the fleet-kit checkout is around it.

The script is non-interactive (safe under the owner loop: stdin
is never read) and idempotent — re-running reuses the project,
the service account, and any secret already deposited, and only
re-verifies. It also refuses to mint a second key if it finds
one already on the service account with no deposit record —
that goes back to Muse for review instead.

## Your steps (YOU)

**YOU-1 — Create the admin-email file (once).** One line: the
Workspace admin account the service account will impersonate.
This is an email address, not a secret — but it lives on-device
only and is never printed into any log.

```
printf '%s' 'YOUR-ADMIN-EMAIL' > ~/workspace-admin-email.txt
chmod 600 ~/workspace-admin-email.txt
```

**YOU-2 — Make a Cloudflare API token available (once per run).**
The token needs **Workers Scripts Edit** on the account (the
same class the Nov 10 middleware setup used — that one-run
token was revoked, so make a fresh one, e.g. named
`middleware-workspace-sa-deposit`). Either:

- export it in the Termux session before running:
  `export CLOUDFLARE_API_TOKEN='...'`, or
- save it as one line in a file (this is the route that works
  if the script runs unattended under the owner loop):

```
printf '%s' 'YOUR-CF-TOKEN' > ~/cloudflare-api-token.txt
chmod 600 ~/cloudflare-api-token.txt
```

Revoke the token after the run — the script doesn't need it
again unless a secret has to be re-deposited.

**YOU-3 — Run the script.** From the fleet-kit checkout on the
phone:

```
bash middleware/workspace-sa-deposit/workspace-sa-deposit.sh
```

(Or ask Muse to queue it into `owner-queue/pending/` — with
the token in the file from YOU-2 it runs unattended; results
land in `owner-queue/results/` either way. Muse will say in
the main chat when a real job is queued, per the standing rule.)

Google sign-in prerequisite: the script gets its Google token
from a gcloud session or a firebase login on the phone (the
same two paths the Nov 6 play-api job used). If neither exists
it stops and says so — sign in once in Termux and re-run.

Optional: to reuse a project you designate instead of the
default, put its project ID as the only line of
`~/workspace-sa-project-id.txt` before running. (Escape hatch
if the account's project quota ever blocks the create.)

**YOU-4 — Authorize domain-wide delegation (Admin console).**
The script's final block prints the exact values. In
admin.google.com: **Security → Access and data control → API
controls → Domain-wide delegation → Add new**, with:

- Client ID: *(printed by the script)*
- OAuth scope:
  `https://www.googleapis.com/auth/admin.directory.group.member`

That one scope only — group membership only.

## Then (ME)

Tell Muse the delegation is done. Muse runs the verification
read — `groups.get` against
`apps-release-trusted-contacts@googlegroups.com` through the
middleware. A roster coming back (instead of the configuration
error) settles two things at once: the SA leg is live, and the
Admin SDK path can in fact see these `@googlegroups.com`
groups — which is unproven until that moment. If Google
refuses them, that result goes to Andrew as a design decision;
the script deliberately has no fallback path.
