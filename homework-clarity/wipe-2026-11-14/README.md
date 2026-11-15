# Homework Clarity — full wipe / clean slate (owner-run, 2026-11-14)

**What this does:** deletes **everything stored by the app** in the
Homework Clarity project **gen-lang-client-0590645241** — Andrew
approved a full clean slate on Nov 14, 2026 after the test data
(the jessandandrew membership tangle, the switch-without-clearing
state) made the pilot data impossible to reason about. After the
wipe he signs in fresh and creates the family clean.

**Exactly what gets deleted:**

- **Firestore:** every document in every top-level collection —
  `families`, `registry`, and any others found at runtime —
  including **all subcollections** (members, invites, kids'
  items/days, calendars, proposals, access logs).
- **Firebase Auth:** **every user** in the project.

**What is NOT touched:**

- The app itself — code, shell, hosting, and the Worker and its
  secrets (the Gemini key, the Google client ID/secret) all stay
  exactly as they are.
- The **Firestore rules**, including Andrew's super-admin UID —
  whatever rules state exists (published or not) is unchanged;
  this package does not deploy rules. (The rules publish has its
  own package: `homework-clarity/rules-publish-2026-11-14/`.)
- **Every other fleet project**, including family-routines-app
  (Bridge, Home Helper, Family Board). Users and families are
  per-project in Firebase; this wipe cannot reach them.
- **The Google accounts themselves.** Only their records *inside
  this app* are deleted. fourpshot, jessandandrew, and
  andrewhorowitz3 still exist and sign in everywhere else
  exactly as before.

**Calendar grants:** the Worker's stored calendar grants (KV) are
keyed by family ID. Once the families are gone those entries are
inert orphans — nothing can reach them and they grant access to
nothing. Revoking the Google-side calendar consent is a separate,
optional step in the Google account's own settings (Google
Account → Security → third-party access), not part of this wipe.

**Safety shape:** the script (1) prints a full inventory — every
Auth user and every collection with document counts; (2) exports
all of it to a timestamped `backup-*.json` in this folder and
aborts if the backup can't be written and re-read — **the backup
is the only recovery, this is a one-way door** (a `.gitignore`
here keeps it out of git; don't commit or share it); (3) asks you
to type `WIPE` — anything else aborts with nothing deleted;
(4) deletes; (5) re-lists both stores and reports plainly what's
left, if anything. The target project is pinned in the script;
there is no flag or setting that can retarget it.

**Everything is packaged:** the script first runs the fleet
Termux ensurer (`tools/termux-env/ensure-tools.sh`) so node,
firebase-tools, gcloud, curl and git are all present before the
wipe starts — nothing stops mid-run on a missing dependency.

## YOU — run it in Termux (one line)

```
git -C ~/work/fleet-kit pull -q; bash ~/work/fleet-kit/homework-clarity/wipe-2026-11-14/wipe.sh
```

The only interactive moments: if the Firebase CLI has no live
sign-in, it runs `firebase login --no-localhost` — approve in the
browser as **andrewhorowitz3** and paste the code back — and the
typed `WIPE` confirmation after you've read the inventory.

A good run ends with `=== WIPE COMPLETE — gen-lang-client-0590645241 is empty ===`.

## Fresh start, right after the wipe

1. On the phone: clear the Homework Clarity app's **cache and
   data**, so no stale session or state survives on-device.
2. Open the app and **sign in fresh**.
3. **Create the family** — clean, with only the memberships you
   make this time.

## ME — Muse after your run

- Re-checks the app end-to-end on the fresh family: sign-in
  routing, per-kid blocker calendar picks, and one real scan
  (the Gemini chain proof).
- Updates the status page: the Homework Clarity items that were
  blocked on the tangled test data get re-filed against the
  clean slate.
