#!/usr/bin/env bash
# delete-clarity-orphans — shut down the four empty GCP orphan projects from
# the Nov 4, 2026 converger burst (clarity-horowitz, andrewdhorowitz-clarity,
# clarity-andrewdhorowitz, adhorowitz-clarity). All four are compliance-
# suspended, were never appealed, and never held anything: Firebase was only
# ever added to the keeper.
#
# The keeper clarity-family (project number 56094110439) is NEVER a target:
# it is not in the target list, every target must pass a not-the-keeper guard,
# and the keeper is re-verified ACTIVE at the end.
#
# Non-interactive, idempotent: already-gone or already-shutting-down projects
# report "already" and are skipped. Exit 0 only if every target ends in
# DELETE_REQUESTED (or gone) and the keeper verifies ACTIVE.

set -u

TARGETS="clarity-horowitz andrewdhorowitz-clarity clarity-andrewdhorowitz adhorowitz-clarity"
KEEPER="clarity-family"
KEEPER_NUMBER="56094110439"
EXPECTED_ACCOUNT="andrewhorowitz3@gmail.com"
START_TS=$(date +%s)
FAIL=0

echo "== delete-clarity-orphans =="
date

# --- preflight -------------------------------------------------------------
if ! command -v gcloud >/dev/null 2>&1; then
  echo "- skipped (gcloud is not installed in this Termux environment; nothing touched)"
  exit 1
fi
ACCT="$(timeout 60 gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)"
if [ "$ACCT" != "$EXPECTED_ACCOUNT" ]; then
  echo "- skipped (active gcloud account is '${ACCT:-none}', expected $EXPECTED_ACCOUNT; nothing touched)"
  exit 1
fi
echo "v preflight: gcloud authed as $ACCT"

elapsed() { echo $(( $(date +%s) - START_TS )); }

for PID in $TARGETS; do
  # time guard: stay well inside the loop's per-job timeout; a rerun finishes
  # whatever is left because every step is idempotent.
  if [ "$(elapsed)" -gt 900 ]; then
    echo "- skipped ($PID and any remaining: time guard hit at $(elapsed)s; rerun this job to finish)"
    FAIL=1
    break
  fi

  DESC_ERR="$(mktemp)"
  STATE="$(timeout 60 gcloud projects describe "$PID" --format='value(lifecycleState)' 2>"$DESC_ERR")"
  if [ -z "$STATE" ]; then
    if grep -qi "not_found\|not found" "$DESC_ERR"; then
      echo "v already ($PID no longer exists)"
      rm -f "$DESC_ERR"
      continue
    fi
    echo "- skipped ($PID: describe failed: $(head -c 300 "$DESC_ERR"))"
    rm -f "$DESC_ERR"
    FAIL=1
    break
  fi
  rm -f "$DESC_ERR"

  if [ "$STATE" = "DELETE_REQUESTED" ] || [ "$STATE" = "DELETE_IN_PROGRESS" ]; then
    echo "v already ($PID shutdown already in progress: $STATE)"
    continue
  fi

  # --- safety guards -------------------------------------------------------
  NUMBER="$(timeout 60 gcloud projects describe "$PID" --format='value(projectNumber)' 2>/dev/null)"
  CREATED="$(timeout 60 gcloud projects describe "$PID" --format='value(createTime)' 2>/dev/null)"
  if [ "$PID" = "$KEEPER" ] || [ "$NUMBER" = "$KEEPER_NUMBER" ]; then
    echo "- skipped ($PID failed the keeper guard: number $NUMBER; refusing to touch the keeper)"
    FAIL=1
    break
  fi
  case "$CREATED" in
    2026-11-04*) : ;;
    *)
      echo "- skipped ($PID failed the creation-date guard: createTime '$CREATED', expected the 2026-11-04 burst)"
      FAIL=1
      break
      ;;
  esac

  # --- emptiness checks ----------------------------------------------------
  SVC_ERR="$(mktemp)"
  SERVICES="$(timeout 90 gcloud services list --enabled --project="$PID" --format='value(config.name)' 2>"$SVC_ERR")"
  if [ -z "$SERVICES" ] && [ -s "$SVC_ERR" ]; then
    if grep -qi "suspend" "$SVC_ERR"; then
      echo "- note ($PID: enabled-services check blocked by the compliance suspension; proceeding on guards + the Nov 4 creation record)"
    else
      echo "- skipped ($PID: services check failed: $(head -c 300 "$SVC_ERR"))"
      rm -f "$SVC_ERR"
      FAIL=1
      break
    fi
  else
    NOTEMPTY=""
    for S in $SERVICES; do
      case "$S" in
        firebase.googleapis.com|firebase*.googleapis.com|firestore.googleapis.com|compute.googleapis.com|storage.googleapis.com|sqladmin.googleapis.com|run.googleapis.com|cloudfunctions.googleapis.com|artifactregistry.googleapis.com|appengine.googleapis.com)
          NOTEMPTY="$NOTEMPTY $S" ;;
      esac
    done
    if [ -n "$NOTEMPTY" ]; then
      echo "- skipped ($PID is NOT empty: resource-bearing APIs enabled:$NOTEMPTY)"
      rm -f "$SVC_ERR"
      FAIL=1
      break
    fi
    SAS="$(timeout 90 gcloud iam service-accounts list --project="$PID" --format='value(email)' 2>/dev/null)"
    if [ -n "$SAS" ]; then
      echo "- skipped ($PID is NOT empty: service accounts exist: $SAS)"
      rm -f "$SVC_ERR"
      FAIL=1
      break
    fi
    echo "v verified empty ($PID: no resource-bearing APIs enabled, no service accounts)"
  fi
  rm -f "$SVC_ERR"

  # --- delete ---------------------------------------------------------------
  DEL_OUT="$(timeout 180 gcloud projects delete "$PID" --quiet 2>&1)"
  if [ $? -ne 0 ]; then
    echo "- skipped ($PID: delete refused: $(echo "$DEL_OUT" | head -c 400))"
    echo "- note (a refusal here is most likely the compliance suspension or a lien; the remaining targets would refuse the same way, so stopping)"
    FAIL=1
    break
  fi
  NEWSTATE="$(timeout 60 gcloud projects describe "$PID" --format='value(lifecycleState)' 2>/dev/null)"
  if [ "$NEWSTATE" = "DELETE_REQUESTED" ] || [ "$NEWSTATE" = "DELETE_IN_PROGRESS" ] || [ -z "$NEWSTATE" ]; then
    echo "v applied ($PID shutdown requested; state now ${NEWSTATE:-gone}; 30-day pending-deletion window started)"
  else
    echo "- skipped ($PID: delete ran but state is '$NEWSTATE', not DELETE_REQUESTED)"
    FAIL=1
    break
  fi

  # --- pacing pause before the next project ---------------------------------
  REMAINING=""
  for T in $TARGETS; do [ "$T" != "$PID" ] && REMAINING="yes"; done
  if [ -n "$REMAINING" ]; then
    PAUSE=$(( 60 + RANDOM % 31 ))
    echo "  (pacing pause ${PAUSE}s before the next project)"
    sleep "$PAUSE"
  fi
done

# --- keeper re-verification ---------------------------------------------------
KSTATE="$(timeout 60 gcloud projects describe "$KEEPER" --format='value(lifecycleState)' 2>/dev/null)"
if [ "$KSTATE" = "ACTIVE" ]; then
  echo "v keeper $KEEPER verified ACTIVE and untouched"
else
  echo "- WARNING (keeper $KEEPER state is '${KSTATE:-unreadable}', expected ACTIVE)"
  FAIL=1
fi

echo "== delete-clarity-orphans finished with exit $FAIL after $(elapsed)s =="
exit $FAIL
