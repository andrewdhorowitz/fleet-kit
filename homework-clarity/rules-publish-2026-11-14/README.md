# Homework Clarity — Firestore rules publish (owner-run, 2026-11-14)

**What this does:** publishes the current `firestore.rules` to the
Homework Clarity project **gen-lang-client-0590645241** with the
Firebase CLI — the scripted route around the new Firebase console,
whose Rules tab shows the editor and "Develop and test" but no
Publish button (Andrew hit exactly that on Nov 14 and parked it).

The rules in this package are the live file from the
homework-clarity project (Nov 14 version): the personal-space
seating clause and the run-as parent grant on kids'
items/days/profile. Until they publish, "Open in edit mode" writes
its access-log entry but the kid's list stays locked, and the
private-space create button stays inert.

**Everything is packaged:** the script first runs the fleet
Termux ensurer (`tools/termux-env/ensure-tools.sh`) so node,
firebase-tools, gcloud, curl and git are all present before the
deploy starts — nothing stops mid-run on a missing dependency.

## YOU — run it in Termux (one line)

```
git -C ~/work/fleet-kit pull -q; bash ~/work/fleet-kit/homework-clarity/rules-publish-2026-11-14/publish-rules.sh
```

The only possible interactive moment: if the Firebase CLI has no
live sign-in, it runs `firebase login --no-localhost` — approve in
the browser as **andrewhorowitz3** and paste the code back. (The
Nov 4 sign-in may still be live; then this step is skipped
entirely.)

A good run ends with `=== RULES PUBLISHED ===` plus a verify line
naming the newest live ruleset and its create time.

## ME — Muse after your run

- Re-checks the app end-to-end: edit mode opens Alexis's list,
  a scan lands items on it (the Gemini chain proof), and the
  private-space button is live.
- Updates the status page: rules republish leaves "Blocked on
  Andrew."
