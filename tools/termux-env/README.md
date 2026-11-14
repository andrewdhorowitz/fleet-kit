# Fleet Termux environment — tools that just live there (Nov 14, 2026)

Andrew's ask: the things the fleet keeps needing in Termux —
**Node.js, the Firebase CLI, gcloud, curl, git, wget, jq, python** —
should natively live in his Termux every time, guaranteed on
startup, instead of each owner-run package discovering one missing
mid-run ("oh that's missing — no it's not").

## Pieces

- `ensure-tools.sh` — the guarantee. Fast no-op when everything is
  present (command -v checks + a 24h stamp, no network); when
  something IS missing it installs the **whole set up front**:
  one `pkg install` (git curl wget which nodejs-lts npm python jq
  unzip openssh ca-certificates), `npm install -g firebase-tools`,
  and the Google Cloud SDK by Andrew's proven Nov 14 recipe
  (installer to `$PREFIX/google-cloud-sdk`, then
  `install.sh --override-components`). Ends with a version +
  sign-in report; it **never forces a login** — a shell startup
  must not block on one.
- `install-bashrc.sh` — one-time wiring. Appends one guarded block
  to `~/.bashrc`: gcloud on PATH + run `ensure-tools.sh` at shell
  start (which no-ops in well under a second when healthy).

## YOU — one-time setup (one line)

```
git -C ~/work/fleet-kit pull -q; bash ~/work/fleet-kit/tools/termux-env/install-bashrc.sh; source ~/.bashrc
```

The first `source` may take a few minutes if it has to install
firebase-tools or the Cloud SDK; every later shell starts clean.

## Notes

- gcloud was already installed Nov 14, 2026 (signed in as
  andrewhorowitz3, project family-routines-app) — the ensurer just
  keeps it that way and puts it on PATH in every shell.
- The Firebase CLI sign-in persists across sessions once done
  (`firebase login --no-localhost`, done Nov 4 as
  andrewhorowitz3); packages that need it check and only prompt
  when it's actually missing.
- Re-run `ensure-tools.sh --force` any time to re-verify everything.
