# QuillSend — owner setup package (2026-11-16)

One owner-run Termux script that does every Google-side and
key-side setup step for QuillSend that Muse cannot reach from its
own sandbox, so Andrew's manual work shrinks to what only he can do.

## Run it (YOU — Andrew, ~5–10 minutes, mostly waiting)

```bash
cd ~/work/fleet-kit && git pull
bash quillsend-setup-2026-11-16/quillsend-setup.sh
```

The script may pause twice to ask you to paste an OAuth **client ID**
(public identifiers — safe to paste and to send to Muse). If the
Google APIs refuse the automated OAuth brand/client creation, it
prints the exact console step with every value filled in — still one
sitting, no hunting.

When it finishes, send Muse the contents of
`quillsend-setup-results.txt` (same folder). It contains no secrets —
project ID, client IDs, and key fingerprints are public identifiers.

## What it does

1. Creates/reuses the GCP project `quillsend-app`, enables the Gmail
   API (paced, one create at a time; a failed create stops the
   script for diagnosis instead of minting siblings).
2. Creates the OAuth consent brand + Web client via `gcloud alpha
   iap` where the APIs allow; the Android OAuth client is a printed
   console step (no public API creates Android-type clients) with
   package name + SHA-1 filled in.
3. Generates the permanent upload keystore on the phone (passwords
   stay in `~/quillsend-keystore-credentials.txt`, mode 600, and in
   the GitHub repo secrets — never in any committed file).
4. Deposits the repo secrets CI needs: `QS_KEYSTORE_BASE64`,
   `QS_KEYSTORE_PASSWORD`, `QS_KEY_ALIAS`, `QS_KEY_PASSWORD`, and
   `QS_OAUTH_WEB_CLIENT_ID` / `QS_OAUTH_ANDROID_CLIENT_ID` when
   known; plus `PLAY_SERVICE_ACCOUNT_JSON` if
   `~/play-service-account.json` is present.

Idempotent: re-running after fixing anything (e.g. `gh auth login`)
picks up where it left off.

## Still yours after this (not scriptable)

- **Play Console app entry** for `com.andrewdhorowitz.quillsend`
  (~5 min; Google offers no API for creating the entry; the package
  name is set at creation). Publishing stays inert until this exists
  AND the secrets above are deposited.
- **Play App Signing SHA-1**: once the app is on Play, add the Play
  App Signing certificate's SHA-1 as a second fingerprint on the
  Android OAuth client (the fleet's hard-learned sign-in lesson:
  register both the upload key and the Play signing key).
- **Register quillsend.app** (and bymyhand.app) when ready — Andrew's
  purchase; the app does not block on it.
- **Confirm the S/MIME certificate is installed on the phone** — at
  first run, the app's Link certificate picker will show it (or not);
  nothing Muse's side can check this.
