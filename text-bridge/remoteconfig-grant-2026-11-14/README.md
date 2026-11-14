# Remote Config grant converger — 2026-11-14 (owner-run)

**What this does:** it removes the one blocker on the version-policy
Remote Config fallback. The text-bridge-receiver Worker mirrors the
apps' version policy into Firebase Remote Config (the fallback the
apps read when the Worker is unreachable), but its Firebase service
account gets **HTTP 403** from the Remote Config API on project
**family-routines-app** (826159679918), so the mirror can't seed.
A 403 doesn't say which piece is missing, so this converger fixes
both, under your own gcloud login, on that one project only:

1. Enables the **Firebase Remote Config API**
   (`firebaseremoteconfig.googleapis.com`) — verified by read-back.
2. Grants **Firebase Remote Config Admin**
   (`roles/cloudconfig.admin`) to the project's
   **firebase-adminsdk-\*** service account — the account whose key
   the Worker holds — verified in the project IAM policy read-back.

Nothing else is touched: no other project, no other API, no other
role, no other member. The account is discovered from the project
side (the credential itself lives only as a Worker secret): the
script lists the project's service accounts and picks the
firebase-adminsdk-\* one. If there are zero or several candidates
it **stops and prints the list** rather than guessing. The chosen
account's email is printed in the output — it's an identifier, not
a secret.

**Who runs what:** YOU run one line in Termux. ME (Muse) does the
rest after you relay the DONE line.

---

## YOU — Run the converger in Termux

Prerequisite: `gcloud` installed in Termux and signed in
(`gcloud auth login`) as an account with owner/editor access to
family-routines-app — andrewhorowitz3 is the project's owner. If
gcloud is missing or signed out, the script says so and stops;
it never guesses.

```
mkdir -p ~/work; if [ -d ~/work/fleet-kit/.git ]; then git -C ~/work/fleet-kit pull -q; else git clone -q https://github.com/andrewdhorowitz/fleet-kit ~/work/fleet-kit; fi; bash ~/work/fleet-kit/text-bridge/remoteconfig-grant-2026-11-14/remoteconfig-grant-converge.sh
```

The script babysits itself: it re-pulls this repo before every
attempt (so a fix Muse pushes mid-run lands on its own), applies
each change only if missing, verifies each by read-back, and
pauses between the two provider changes. It is idempotent — if
everything is already in place it reports "✓ already" for each
step and succeeds without changing anything. Per-step progress
prints as it goes, and the full record lands in
`remoteconfig-grant-results.txt` in this directory (the script
commits and pushes it when git allows).

Success ends with:

```
=== DONE — Remote Config access granted and verified ===
```

If it stops with a `flag: IMPOSSIBLE` line instead, it names the
one thing only you can clear (no gcloud, no login, or an ambiguous
service-account list) — relay that line to Muse.

## ME — Muse's steps after your run

- Re-run `tb_client.py version-policy-set` (re-asserting the
  current values): the Worker's write now mirrors all four Remote
  Config parameters (`bridge_min_version_code`,
  `bridge_latest_version_code`, `homehelper_min_version_code`,
  `homehelper_latest_version_code`) into family-routines-app and
  reads them back. The raise counts complete only with
  `remote_config_synced: true` and matching values.
- Confirm the apps' fallback leg now finds the parameters (until
  this run, it found none and failed open, as designed — the
  Worker policy, the authoritative source, was never affected).

**Safety notes:** the grant is one role on one project for one
service account — the minimum that carries
`cloudconfig.configs.get` + `cloudconfig.configs.update` as a
single standard role. It is revocable at any time in the Cloud
console (IAM → family-routines-app → remove the
`roles/cloudconfig.admin` binding for that account);
removing it returns the mirror to its current 403 state and
changes nothing else.

**Role-name note (Nov 14, 2026):** the first converger run failed
at the grant step — `add-iam-policy-binding` rejects the legacy
role name `roles/firebaseremoteconfig.admin` with "not supported
for this resource". Google's current predefined Remote Config
role is `roles/cloudconfig.admin`; the script now grants that
(a pre-existing legacy-name binding still counts as satisfied).
