#!/usr/bin/env bash
# rs-secrets-deposit.sh — owner-queue job (DRAFT — prepared by Muse,
# 2026-11-06; runs only after Andrew approves moving it to pending/).
#
# PURPOSE: deposit the five Actions secrets the Routines & Streaks
# TWA publish job needs on repo andrewdhorowitz/routines-and-streaks:
#   RS_KEYSTORE_BASE64, RS_KEYSTORE_PASSWORD, RS_KEY_ALIAS,
#   RS_KEY_PASSWORD, PLAY_SERVICE_ACCOUNT_JSON
# These names are exactly what .github/workflows/android.yml reads
# (secrets.RS_KEYSTORE_* / secrets.PLAY_SERVICE_ACCOUNT_JSON) and
# android/app/build.gradle.kts consumes via env: signing config "rs"
# takes storePassword/keyAlias/keyPassword from RS_KEYSTORE_PASSWORD /
# RS_KEY_ALIAS / RS_KEY_PASSWORD, store file from RS_KEYSTORE_PATH
# (CI decodes RS_KEYSTORE_BASE64). The alias is NOT hardcoded in the
# build — whatever alias this job creates is what it deposits as
# RS_KEY_ALIAS, so the two always match.
#
# SHAPE: mirrors the Homework Clarity deposit of Nov 3, 2026 — a
# permanent upload keystore generated on the phone (CN=Andrew
# Horowitz, ~/hc-upload.jks there; ~/rs-upload.jks here, phone copy
# only), password generated in-shell, and the play-publisher SA JSON
# read from the phone's Downloads. Differences from the Nov 3 manual
# line, both deliberate: the password comes from /dev/urandom (the
# first HC attempt failed because Termux had no openssl and produced
# an empty password), and one password serves as both store and key
# password so the deposit can never disagree with itself.
#
# SECRECY: this repo is PUBLIC. Secret values live ONLY in shell
# variables / stdin pipes on this device — never printed, never
# written to a file, never committed. This job's output (which the
# loop commits to owner-queue/results/) carries secret NAMES and
# set/not-set verdicts only.
#
# CONTRACT: non-interactive, idempotent — secrets already present are
# reported "✓ already" and left untouched; an existing
# ~/rs-upload.jks is NEVER overwritten. Fails closed: any step that
# cannot complete names its reason in the summary and the job exits
# nonzero; the two halves (keystore / SA JSON) are independent — the
# SA half can fail with its named reason while the keystore half
# still completes, and vice versa.

set -u

TARGET_REPO="andrewdhorowitz/routines-and-streaks"
KS_FILE="$HOME/rs-upload.jks"
KS_ALIAS="rs-upload"
KS_DNAME="CN=Andrew Horowitz"
SA_GLOB="play-publisher-513614-*.json"

now_et() { TZ=America/New_York date '+%Y-%m-%d %H:%M:%S %Z'; }

echo "job: rs-secrets-deposit.sh"
echo "started: $(now_et)"
echo "target repo: $TARGET_REPO"

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR" 2>/dev/null || true
KS_PW=""
KS_B64=""
cleanup() {
  KS_PW=""
  KS_B64=""
  unset KS_PW KS_B64 2>/dev/null || true
  if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then rm -rf "$WORKDIR"; fi
}
trap cleanup EXIT

# Per-secret outcome lines, filled in as we go; printed in the summary.
declare -A OUTCOME=()
for n in RS_KEYSTORE_BASE64 RS_KEYSTORE_PASSWORD RS_KEY_ALIAS RS_KEY_PASSWORD PLAY_SERVICE_ACCOUNT_JSON; do
  OUTCOME[$n]="not attempted"
done
KS_HALF_OK=0
SA_HALF_OK=0

# --- step 0: gh present + authed -----------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "step gh: FAILED (gh CLI not found on this device)"
  echo "result: FAILED (gh CLI missing — nothing deposited)"
  echo "finished: $(now_et)"
  exit 1
fi
if ! gh auth status >/dev/null 2>"$WORKDIR/ghauth.err"; then
  echo "step gh: FAILED (gh is present but not authenticated)"
  echo "result: FAILED (gh not authed — nothing deposited)"
  echo "finished: $(now_et)"
  exit 1
fi
echo "step gh: ✓ applied (gh CLI present and authenticated)"

secret_present() { # $1 = secret name; names only, never values
  gh secret list --repo "$TARGET_REPO" 2>/dev/null \
    | grep -q "^$1[[:space:]]"
}

# --- step 1: keystore half ------------------------------------------
PRESENT_COUNT=0
for n in RS_KEYSTORE_BASE64 RS_KEYSTORE_PASSWORD RS_KEY_ALIAS RS_KEY_PASSWORD; do
  if secret_present "$n"; then PRESENT_COUNT=$((PRESENT_COUNT+1)); fi
done

if [[ $PRESENT_COUNT -eq 4 ]]; then
  for n in RS_KEYSTORE_BASE64 RS_KEYSTORE_PASSWORD RS_KEY_ALIAS RS_KEY_PASSWORD; do
    OUTCOME[$n]="✓ already (present on $TARGET_REPO)"
  done
  KS_HALF_OK=1
  echo "step keystore: ✓ already (all four RS_* secrets present — nothing to deposit)"
elif [[ -e "$KS_FILE" ]]; then
  # A keystore exists but its RS secrets are incomplete. Its password
  # was generated in-shell by whatever created it and is not
  # recoverable here; never overwrite the keystore to force our way.
  for n in RS_KEYSTORE_BASE64 RS_KEYSTORE_PASSWORD RS_KEY_ALIAS RS_KEY_PASSWORD; do
    if secret_present "$n"; then OUTCOME[$n]="✓ already (present on $TARGET_REPO)"; fi
  done
  echo "step keystore: FAILED (~/rs-upload.jks already exists but only $PRESENT_COUNT of 4 RS_* secrets are set, and the existing keystore's password cannot be recovered in this run — keystore NOT overwritten; needs Muse/Andrew review)"
elif [[ $PRESENT_COUNT -gt 0 ]]; then
  # Partial RS secrets with no local keystore: a keystore exists
  # somewhere else with an unknown password. Refuse to mint a second
  # upload key that would disagree with the deposited base64.
  for n in RS_KEYSTORE_BASE64 RS_KEYSTORE_PASSWORD RS_KEY_ALIAS RS_KEY_PASSWORD; do
    if secret_present "$n"; then OUTCOME[$n]="✓ already (present on $TARGET_REPO)"; fi
  done
  echo "step keystore: FAILED ($PRESENT_COUNT of 4 RS_* secrets are already set but no ~/rs-upload.jks exists on this phone — refusing to generate a second, mismatched upload keystore; needs Muse/Andrew review)"
else
  if ! command -v keytool >/dev/null 2>&1; then
    echo "step keystore: FAILED (keytool not found on this device — install a JDK in Termux, e.g. pkg install openjdk-17, then re-run)"
  else
    # Password from /dev/urandom only — no openssl dependency (the
    # Nov 3 HC lesson), never written to any file.
    KS_PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
    if [[ ${#KS_PW} -lt 16 ]]; then
      echo "step keystore: FAILED (could not generate a keystore password from /dev/urandom)"
      KS_PW=""
    elif ! keytool -genkeypair -keystore "$KS_FILE" \
          -alias "$KS_ALIAS" -keyalg RSA -keysize 2048 -validity 10000 \
          -storepass "$KS_PW" -keypass "$KS_PW" \
          -dname "$KS_DNAME" >"$WORKDIR/keytool.out" 2>"$WORKDIR/keytool.err"; then
      echo "step keystore: FAILED (keytool -genkeypair failed; no keystore created)"
      rm -f "$KS_FILE"
      KS_PW=""
    elif ! keytool -list -keystore "$KS_FILE" -storepass "$KS_PW" \
          -alias "$KS_ALIAS" >/dev/null 2>"$WORKDIR/keytool2.err"; then
      echo "step keystore: FAILED (new keystore does not verify with its password/alias)"
      KS_PW=""
    else
      echo "step keystore: ✓ applied (permanent upload keystore generated at ~/rs-upload.jks, alias $KS_ALIAS, CN=Andrew Horowitz — phone copy only)"
      KS_B64="$(base64 < "$KS_FILE" | tr -d '\n')"
      KS_SET_OK=1
      if [[ -z "$KS_B64" ]]; then KS_SET_OK=0; fi
      if [[ $KS_SET_OK -eq 1 ]]; then
        printf '%s' "$KS_B64" | gh secret set RS_KEYSTORE_BASE64 --repo "$TARGET_REPO" \
          2>"$WORKDIR/gh1.err" || KS_SET_OK=0
      fi
      if [[ $KS_SET_OK -eq 1 ]]; then
        printf '%s' "$KS_PW" | gh secret set RS_KEYSTORE_PASSWORD --repo "$TARGET_REPO" \
          2>"$WORKDIR/gh2.err" || KS_SET_OK=0
      fi
      if [[ $KS_SET_OK -eq 1 ]]; then
        printf '%s' "$KS_ALIAS" | gh secret set RS_KEY_ALIAS --repo "$TARGET_REPO" \
          2>"$WORKDIR/gh3.err" || KS_SET_OK=0
      fi
      if [[ $KS_SET_OK -eq 1 ]]; then
        printf '%s' "$KS_PW" | gh secret set RS_KEY_PASSWORD --repo "$TARGET_REPO" \
          2>"$WORKDIR/gh4.err" || KS_SET_OK=0
      fi
      KS_B64=""
      if [[ $KS_SET_OK -eq 1 ]]; then
        ALL_OK=1
        for n in RS_KEYSTORE_BASE64 RS_KEYSTORE_PASSWORD RS_KEY_ALIAS RS_KEY_PASSWORD; do
          if secret_present "$n"; then
            OUTCOME[$n]="✓ applied (set on $TARGET_REPO; verified in the secret list)"
          else
            ALL_OK=0
            OUTCOME[$n]="FAILED (set was attempted but the name did not appear in gh secret list)"
          fi
        done
        [[ $ALL_OK -eq 1 ]] && KS_HALF_OK=1
        [[ $ALL_OK -eq 1 ]] \
          && echo "step rs-secrets: ✓ applied (all four RS_* secrets set and verified by name)" \
          || echo "step rs-secrets: FAILED (one or more RS_* secrets missing after set — see summary)"
      else
        for n in RS_KEYSTORE_BASE64 RS_KEYSTORE_PASSWORD RS_KEY_ALIAS RS_KEY_PASSWORD; do
          if secret_present "$n"; then
            OUTCOME[$n]="✓ applied (set on $TARGET_REPO; verified in the secret list)"
          else
            OUTCOME[$n]="FAILED (gh secret set failed for this name)"
          fi
        done
        echo "step rs-secrets: FAILED (gh secret set failed — see summary; keystore itself is safe at ~/rs-upload.jks and a re-run will report the state it finds)"
      fi
      KS_PW=""
    fi
  fi
fi

# --- step 2: Play service-account half -------------------------------
if secret_present "PLAY_SERVICE_ACCOUNT_JSON"; then
  OUTCOME[PLAY_SERVICE_ACCOUNT_JSON]="✓ already (present on $TARGET_REPO)"
  SA_HALF_OK=1
  echo "step play-sa: ✓ already (PLAY_SERVICE_ACCOUNT_JSON present — nothing to deposit)"
else
  # Same discovery as scripts/firebase-converge.sh and the Oct 30
  # owner-loop job: the newest glob match, searched across the
  # shared-storage Downloads bridge first (where the Nov 3 HC deposit
  # found play-publisher-513614-*.json), then ~/Downloads, then $HOME.
  SA_FILE=""
  newest=""
  for dir in "$HOME/storage/downloads" "$HOME/Downloads" "$HOME"; do
    [[ -d "$dir" ]] || continue
    for f in "$dir"/$SA_GLOB; do
      [[ -e "$f" ]] || continue
      if [[ -z "$newest" || "$f" -nt "$newest" ]]; then newest="$f"; fi
    done
  done
  if [[ -z "$newest" ]]; then
    OUTCOME[PLAY_SERVICE_ACCOUNT_JSON]="not set (SA key file not found on phone)"
    echo "step play-sa: – skipped (PLAY_SERVICE_ACCOUNT_JSON not set: SA key file not found on phone — no $SA_GLOB in ~/storage/downloads, ~/Downloads, or ~)"
  else
    SA_FILE="$newest"
    # Validate shape only (service-account JSON with the two fields
    # the key must carry). Field VALUES are never printed.
    if ! python3 - "$SA_FILE" <<'PY' >/dev/null 2>&1
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if d.get("type") != "service_account":
    sys.exit(1)
if not d.get("client_email") or "PRIVATE KEY" not in (d.get("private_key") or ""):
    sys.exit(1)
PY
    then
      OUTCOME[PLAY_SERVICE_ACCOUNT_JSON]="not set (candidate file found but it is not a valid service-account JSON)"
      echo "step play-sa: – skipped (PLAY_SERVICE_ACCOUNT_JSON not set: a $SA_GLOB file was found but is not a valid service-account JSON — refusing to deposit it)"
    elif ! gh secret set PLAY_SERVICE_ACCOUNT_JSON --repo "$TARGET_REPO" < "$SA_FILE" \
        2>"$WORKDIR/gh5.err"; then
      OUTCOME[PLAY_SERVICE_ACCOUNT_JSON]="FAILED (gh secret set failed)"
      echo "step play-sa: FAILED (gh secret set PLAY_SERVICE_ACCOUNT_JSON failed)"
    elif secret_present "PLAY_SERVICE_ACCOUNT_JSON"; then
      OUTCOME[PLAY_SERVICE_ACCOUNT_JSON]="✓ applied (set on $TARGET_REPO; verified in the secret list)"
      SA_HALF_OK=1
      echo "step play-sa: ✓ applied (PLAY_SERVICE_ACCOUNT_JSON set from the play-publisher SA JSON found on the phone; verified by name)"
    else
      OUTCOME[PLAY_SERVICE_ACCOUNT_JSON]="FAILED (set was attempted but the name did not appear in gh secret list)"
      echo "step play-sa: FAILED (PLAY_SERVICE_ACCOUNT_JSON did not appear in gh secret list after set)"
    fi
  fi
fi

# --- summary ---------------------------------------------------------
echo "summary (names + status only; no values were printed or stored):"
for n in RS_KEYSTORE_BASE64 RS_KEYSTORE_PASSWORD RS_KEY_ALIAS RS_KEY_PASSWORD PLAY_SERVICE_ACCOUNT_JSON; do
  echo "  $n: ${OUTCOME[$n]}"
done

if [[ $KS_HALF_OK -eq 1 && $SA_HALF_OK -eq 1 ]]; then
  echo "result: SUCCESS (all five secrets present on $TARGET_REPO)"
  echo "finished: $(now_et)"
  exit 0
fi
echo "result: FAILED (deposit incomplete — see summary lines above for the named reason)"
echo "finished: $(now_et)"
exit 1
