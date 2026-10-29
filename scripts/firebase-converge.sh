#!/usr/bin/env bash
# firebase-converge.sh — one-shot converger for the Private Section's
# Firebase activation steps (project: family-routines-app).
#
# Runs on Andrew's phone (Termux) — TERMUX ONLY, no browser sign-in.
# The credential is the Firebase Admin SDK service-account JSON
# Andrew already downloaded (newest match of
# ~/storage/downloads/family-routines-app-firebase-adminsdk*.json, or
# an explicit path given as the first positional argument / --keyfile).
# The script builds an RS256 JWT from that JSON, exchanges it at
# Google's OAuth2 endpoint for an access token, and does every step
# with that token. Steps:
#   1. Verify private.andrewdhorowitz.com is in Firebase Auth's
#      authorized domains (add it only if missing).
#   2. Add private.andrewdhorowitz.com/* to the app browser API key's
#      HTTP referrer allowlist (existing referrers preserved).
#   3. Publish the section_access Firestore rules block — only if the
#      repo rules (routines-and-streaks/firestore.rules) differ from
#      the live rules by exactly that block; otherwise skip, never
#      force.
#   4. Seat the section_access tier entries ({ tier, enabled: true },
#      document ID = lowercased email).
#   5. Store the SAME service-account JSON as the fleet-kit GitHub
#      secret FIREBASE_SERVICE_ACCOUNT_JSON (via `gh secret set`,
#      straight from the Downloads file), so Muse can run future
#      Firebase steps. Nothing new is minted; the key in Downloads
#      IS the access — do not delete it in Firebase.
#
# Converger contract: check -> apply what's missing -> report
# "✓ applied" / "✓ already" / "– skipped (reason)" per step, into
# firebase-converge-results.txt at the repo root (flushed per line,
# then committed + pushed by the script). Every API failure records
# its HTTP status and the first ~500 chars of the response body in
# the results file; on any skipped/failed step the script also writes
# firebase-converge-errors.txt (the run's stderr + full API error
# bodies) and commits + pushes BOTH files, so the failure can be
# read from GitHub and the script fixed without screenshots.
# Idempotent; safe to re-run. Exits nonzero when INCOMPLETE.
#
# Every pass also writes a machine-readable outcome flag as the
# second line of the results file, directly under the header:
# "flag: SUCCESS" (every step applied/already), "flag: INCOMPLETE"
# (anything else), or "flag: IMPOSSIBLE: <reason>" when the pass
# hit a retry-proof failure — keyfile not found, the service-
# account key rejected at the token exchange (invalid_grant /
# invalid_client), no RSA signer available, or the rules step
# refusing on drift. The flag is reporting only: it never changes
# the loop's attempts, backoff, or exit codes.
#
# Default invocation LOOPS until a pass fully succeeds: each
# attempt re-pulls this repo (picking up script fixes pushed
# mid-loop), runs one pass as a child process (so a replaced
# script file never corrupts a running process), and retries with
# backoff — 60s, 180s, then 300s (FB_LOOP_DELAYS, space-separated,
# overrides) — up to 20 attempts. --once runs a single pass and
# exits with that pass's real status.
#
# PRIVACY: no email addresses are stored in this repo, the results
# file, or the errors file. Tier addresses arrive as run-time
# arguments only and are reported masked (first two letters +
# domain); error text is masked the same way before it is committed.
#
# Usage:
#   bash scripts/firebase-converge.sh [KEYFILE.json] \
#       --owner <emails...> --family <emails...>          (loop)
#   bash scripts/firebase-converge.sh --once [KEYFILE.json] \
#       --owner <emails...> --family <emails...>          (one pass)

PROJECT="family-routines-app"
TARGET_DOMAIN="private.andrewdhorowitz.com"
TARGET_REFERRER="private.andrewdhorowitz.com/*"
ANCHOR_REFERRER="andrewdhorowitz.github.io/*"
RULES_REPO_PATH="repos/andrewdhorowitz/routines-and-streaks/contents/firestore.rules"
SECRET_NAME="FIREBASE_SERVICE_ACCOUNT_JSON"
SECRET_REPO="andrewdhorowitz/fleet-kit"
DOWNLOADS_GLOB="family-routines-app-firebase-adminsdk*.json"

TOKEN_URL="${FIREBASE_CONVERGE_TOKEN_URL:-https://oauth2.googleapis.com/token}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS="$REPO_ROOT/firebase-converge-results.txt"
ERRORS_FILE="$REPO_ROOT/firebase-converge-errors.txt"

OVERALL_OK=1
PERMANENT_REASON=""
ACCESS_TOKEN=""
API_CODE=""
API_BODY=""
AUTH_FAIL_MSG=""
WORKDIR=""
STDERR_LOG="/dev/null"
API_ERR_LOG="/dev/null"
KEYFILE=""
KEYFILE_ARG=""
OWNERS=()
FAMILY=()

set -u

log_line() { echo "$1" | tee -a "$RESULTS"; }

mark_incomplete() { OVERALL_OK=0; }

# Record a permanent (retry-proof) failure of this pass — the
# results flag reports it as IMPOSSIBLE. The first one wins.
mark_permanent() {
  if [[ -z "$PERMANENT_REASON" ]]; then
    PERMANENT_REASON="$1"
  fi
}

# First error message out of a Google API JSON error body (file arg).
jerr() {
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    e = d.get("error") or {}
    print(e.get("message") or e.get("status") or "unknown error")
except Exception:
    print("unparseable error body")
' "$1" 2>/dev/null || echo "unknown error"
}

_mask_py='
import os, re, sys
text = sys.stdin.read()
for e in os.environ.get("MASK_EMAILS", "").split("\n"):
    e = e.strip()
    if not e:
        continue
    local, _, dom = e.partition("@")
    head = local[:2] if len(local) >= 2 else local[:1]
    text = re.sub(re.escape(e), head + "•••@" + dom, text, flags=re.I)
sys.stdout.write(text)
'

# Mask supplied tier addresses out of stdin text (used before any
# text is committed to the repo).
mask_stream() {
  MASK_EMAILS="$(printf '%s\n' "${OWNERS[@]}" "${FAMILY[@]}")" \
    python3 -c "$_mask_py"
}

# Masked, single-line, first ~500 chars of a file (API body or an
# stderr capture) — safe to embed in a results line.
file_snippet() {
  [[ -n "${1:-}" && -f "$1" ]] || { echo "no response body"; return; }
  MASK_EMAILS="$(printf '%s\n' "${OWNERS[@]}" "${FAMILY[@]}")" \
    python3 - "$1" <<'PY'
import os, re, sys
try:
    text = open(sys.argv[1], errors="replace").read()
except Exception:
    print("unparseable error body")
    raise SystemExit
for e in os.environ.get("MASK_EMAILS", "").split("\n"):
    e = e.strip()
    if not e:
        continue
    local, _, dom = e.partition("@")
    head = local[:2] if len(local) >= 2 else local[:1]
    text = re.sub(re.escape(e), head + "•••@" + dom, text, flags=re.I)
print(" ".join(text.split())[:500])
PY
}

err_snippet() { file_snippet "$API_BODY"; }

# jerr's message, masked — Google error messages can echo back the
# document address (e.g. Firestore names the section_access doc), so
# the raw message must never reach the results file unmasked.
err_msg() { jerr "$API_BODY" | mask_stream; }

# api METHOD URL [BODYFILE] -> sets API_CODE (3-digit) and API_BODY
# (file). Any non-2xx response is recorded in the API error log with
# its HTTP status, curl stderr, and full body (masked later, when the
# errors file is composed for commit).
api() {
  local method="$1" url="$2" body="${3:-}"
  API_BODY="$WORKDIR/resp-$$.json"
  local args=(-sS -g -o "$API_BODY" -w '%{http_code}' -X "$method"
              -H "Authorization: Bearer $ACCESS_TOKEN"
              -H 'Content-Type: application/json')
  if [[ -n "$body" ]]; then args+=(--data-binary "@$body"); fi
  API_CODE="$(curl "${args[@]}" "$url" 2>"$WORKDIR/curl.err" || echo 000)"
  API_CODE="${API_CODE:0:3}"
  if [[ "$API_CODE" != 2* ]]; then
    {
      echo "=== $(date '+%Y-%m-%d %H:%M:%S %Z') $method $url"
      echo "HTTP $API_CODE"
      if [[ -s "$WORKDIR/curl.err" ]]; then
        echo "-- curl stderr --"
        cat "$WORKDIR/curl.err"
      fi
      echo "-- response body --"
      cat "$API_BODY" 2>/dev/null
      echo ""
    } >> "$API_ERR_LOG"
  fi
}

# jo•••@gmail.com style masking for results output.
mask_email() {
  python3 -c '
import sys
local, _, dom = sys.argv[1].partition("@")
head = local[:2] if len(local) >= 2 else local[:1]
print(head + "•••@" + dom)
' "$1"
}

parse_args() {
  OWNERS=(); FAMILY=(); KEYFILE_ARG=""
  local mode=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)  mode="owner" ;;
      --family) mode="family" ;;
      --keyfile)
        if [[ $# -lt 2 ]]; then
          echo "firebase-converge: --keyfile needs a path" >&2
          return 2
        fi
        KEYFILE_ARG="$2"
        shift ;;
      --*) echo "firebase-converge: unknown option: $1" >&2; return 2 ;;
      *)
        if [[ -z "$mode" && -z "$KEYFILE_ARG" && "$1" != *"@"* ]]; then
          # Optional first positional argument: the keyfile path.
          KEYFILE_ARG="$1"
        else
          case "$mode" in
            owner)  OWNERS+=("$1") ;;
            family) FAMILY+=("$1") ;;
            *) echo "firebase-converge: address before any --owner/--family flag: $1" >&2; return 2 ;;
          esac
        fi ;;
    esac
    shift
  done
  return 0
}

# _ensure_pkg CMD PKG -> 0 installed now, 2 already present, 1 failed.
# pkg output is never swallowed: every pkg run's stdout+stderr is
# captured and appended to the API error log under a header naming
# the command, so a failed install is diagnosable from the committed
# errors file. The first install of a run is preceded by one
# `pkg update` (captured the same way) — stale Termux package lists
# are the classic silent-install-failure cause.
PKG_UPDATED=0
_pkg_run_captured() {
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  {
    echo "=== $* (exit $rc)"
    printf '%s\n' "$out"
    echo ""
  } >> "$API_ERR_LOG"
  return $rc
}
_ensure_pkg() {
  if command -v "$1" >/dev/null 2>&1; then return 2; fi
  if command -v pkg >/dev/null 2>&1; then
    if [[ "$PKG_UPDATED" == "0" ]]; then
      PKG_UPDATED=1
      _pkg_run_captured pkg update
    fi
    _pkg_run_captured pkg install -y "$2"
  fi
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  return 1
}

ensure_tools() {
  local installed=() failed=() rc c p
  # Setup diagnostics: where every tool the script may need resolves
  # (or "missing"), recorded in the error log so any setup failure
  # is self-explaining from the committed errors file.
  {
    echo "=== setup diagnostics (command -v)"
    for c in python3 curl openssl node gh git pkg; do
      p="$(command -v "$c" 2>/dev/null || true)"
      echo "$c: ${p:-missing}"
    done
    echo ""
  } >> "$API_ERR_LOG"
  _ensure_pkg python3 python;   rc=$?; [[ $rc -eq 0 ]] && installed+=(python3); [[ $rc -eq 1 ]] && failed+=(python3)
  _ensure_pkg curl curl;        rc=$?; [[ $rc -eq 0 ]] && installed+=(curl);    [[ $rc -eq 1 ]] && failed+=(curl)
  _ensure_pkg gh gh;            rc=$?; [[ $rc -eq 0 ]] && installed+=(gh);      [[ $rc -eq 1 ]] && failed+=(gh)
  _ensure_pkg git git;          rc=$?; [[ $rc -eq 0 ]] && installed+=(git);     [[ $rc -eq 1 ]] && failed+=(git)
  if [[ ${#failed[@]} -gt 0 ]]; then
    log_line "setup: – skipped (could not install: ${failed[*]})"
    return 1
  fi
  if [[ ${#installed[@]} -gt 0 ]]; then
    log_line "setup: ✓ applied (installed: ${installed[*]})"
  else
    log_line "setup: ✓ already (python3, curl, gh, git present)"
  fi
  return 0
}

# Credential resolution: explicit path (--keyfile / first positional)
# wins; otherwise the newest service-account JSON in Downloads.
resolve_keyfile() {
  KEYFILE=""
  if [[ -n "$KEYFILE_ARG" ]]; then
    [[ -f "$KEYFILE_ARG" ]] || return 1
    KEYFILE="$KEYFILE_ARG"
    return 0
  fi
  local newest="" f
  for f in "$HOME"/storage/downloads/$DOWNLOADS_GLOB; do
    [[ -e "$f" ]] || continue
    if [[ -z "$newest" || "$f" -nt "$newest" ]]; then newest="$f"; fi
  done
  [[ -n "$newest" ]] || return 1
  KEYFILE="$newest"
  return 0
}

# _sign_openssl / _sign_node -> RS256-sign $WORKDIR/jwt-unsigned.txt
# into $WORKDIR/jwt-sig.bin using $WORKDIR/pkey.pem. Node's
# crypto.sign uses PKCS#1 v1.5 padding for RSA keys by default,
# which is exactly what RS256 requires.
_sign_openssl() {
  openssl dgst -sha256 -sign "$WORKDIR/pkey.pem" \
    -out "$WORKDIR/jwt-sig.bin" "$WORKDIR/jwt-unsigned.txt" \
    2>>"$API_ERR_LOG"
}

_sign_node() {
  cat > "$WORKDIR/sign.js" <<'JS'
const fs = require("fs");
const crypto = require("crypto");
const data = fs.readFileSync(process.argv[2]);
const key = fs.readFileSync(process.argv[3], "utf8");
fs.writeFileSync(process.argv[4], crypto.sign("RSA-SHA256", data, key));
JS
  node "$WORKDIR/sign.js" "$WORKDIR/jwt-unsigned.txt" \
    "$WORKDIR/pkey.pem" "$WORKDIR/jwt-sig.bin" 2>>"$API_ERR_LOG"
}

# A usable JWT signer: openssl or node on PATH.
signer_available() {
  command -v openssl >/dev/null 2>&1 || command -v node >/dev/null 2>&1
}

# sign_jwt -> sign the JWT with whichever signer exists. openssl is
# not guaranteed on Termux, so node is a full fallback. If neither
# exists, one openssl install is attempted (its output is captured
# by _ensure_pkg) and the signers re-probed; if there is still no
# signer, AUTH_FAIL_MSG is set and the failure is recorded in the
# error log.
sign_jwt() {
  if ! signer_available; then
    _ensure_pkg openssl openssl
  fi
  if command -v openssl >/dev/null 2>&1; then _sign_openssl; return $?; fi
  if command -v node >/dev/null 2>&1; then _sign_node; return $?; fi
  AUTH_FAIL_MSG="no RSA signer available: openssl and node both missing"
  {
    echo "=== auth signing failed: no RSA signer available (openssl and node both missing)"
    echo ""
  } >> "$API_ERR_LOG"
  return 1
}

# Access token from the service-account JSON: RS256 JWT signed with
# openssl (or node when openssl is absent — see sign_jwt), exchanged
# at Google's OAuth2 endpoint. The extracted PEM lives only in the
# private temp dir, which is wiped on exit.
get_access_token() {
  if ! python3 - "$KEYFILE" "$WORKDIR/pkey.pem" "$WORKDIR/sa-email.txt" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
email = d.get("client_email") or ""
key = d.get("private_key") or ""
if not email or "PRIVATE KEY" not in key:
    sys.exit(1)
open(sys.argv[2], "w").write(key)
open(sys.argv[3], "w").write(email)
PY
  then
    API_CODE=""
    API_BODY=""
    return 1
  fi
  local email jwt_unsigned jwt
  email="$(cat "$WORKDIR/sa-email.txt")"
  jwt_unsigned="$(python3 - "$email" "$TOKEN_URL" <<'PY'
import base64, json, sys, time
def b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
now = int(time.time())
header = {"alg": "RS256", "typ": "JWT"}
claims = {"iss": sys.argv[1],
          "scope": "https://www.googleapis.com/auth/cloud-platform",
          "aud": sys.argv[2], "iat": now, "exp": now + 3600}
print(b64(json.dumps(header).encode()) + "." + b64(json.dumps(claims).encode()))
PY
)" || return 1
  printf '%s' "$jwt_unsigned" > "$WORKDIR/jwt-unsigned.txt"
  if ! sign_jwt; then
    API_CODE=""
    API_BODY=""
    return 1
  fi
  jwt="$(python3 - "$WORKDIR/jwt-unsigned.txt" "$WORKDIR/jwt-sig.bin" <<'PY'
import base64, sys
sig = base64.urlsafe_b64encode(open(sys.argv[2], "rb").read()).rstrip(b"=").decode()
print(open(sys.argv[1]).read().strip() + "." + sig)
PY
)" || return 1
  local resp="$WORKDIR/token.json" code
  code="$(curl -sS -o "$resp" -w '%{http_code}' -X POST "$TOKEN_URL" \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
      --data-urlencode "assertion=$jwt" 2>"$WORKDIR/curl.err" || echo 000)"
  code="${code:0:3}"
  API_BODY="$resp"
  API_CODE="$code"
  if [[ "$code" != "200" ]]; then
    {
      echo "=== $(date '+%Y-%m-%d %H:%M:%S %Z') POST $TOKEN_URL (service-account token exchange)"
      echo "HTTP $code"
      if [[ -s "$WORKDIR/curl.err" ]]; then
        echo "-- curl stderr --"
        cat "$WORKDIR/curl.err"
      fi
      echo "-- response body --"
      cat "$resp" 2>/dev/null
      echo ""
    } >> "$API_ERR_LOG"
    return 1
  fi
  ACCESS_TOKEN="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("access_token", ""))
' "$resp")"
  [[ -n "$ACCESS_TOKEN" ]]
}

# Step 1 — Firebase Auth authorized domains.
step1() {
  local url="https://identitytoolkit.googleapis.com/admin/v2/projects/$PROJECT/config"
  api GET "$url"
  if [[ "$API_CODE" != "200" ]]; then
    local note=""
    if [[ "$API_CODE" == "403" ]]; then
      note=" — note: Andrew already added $TARGET_DOMAIN in the Firebase Console, so the domain itself is confirmed there"
    fi
    log_line "step 1 authorized domain: – skipped (HTTP $API_CODE: $(err_msg) | body: $(err_snippet))$note"
    mark_incomplete; return
  fi
  if python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if sys.argv[2] in (d.get("authorizedDomains") or []) else 1)
' "$API_BODY" "$TARGET_DOMAIN"; then
    log_line "step 1 authorized domain $TARGET_DOMAIN: ✓ already"
    return
  fi
  python3 - "$API_BODY" "$WORKDIR/s1-body.json" "$TARGET_DOMAIN" "$PROJECT" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
domains = list(d.get("authorizedDomains") or [])
if sys.argv[3] not in domains:
    domains.append(sys.argv[3])
body = {"name": d.get("name") or "projects/%s/config" % sys.argv[4],
        "authorizedDomains": domains}
json.dump(body, open(sys.argv[2], "w"))
PY
  api PATCH "$url?updateMask=authorizedDomains" "$WORKDIR/s1-body.json"
  if [[ "$API_CODE" == "200" ]]; then
    log_line "step 1 authorized domain $TARGET_DOMAIN: ✓ applied"
  else
    log_line "step 1 authorized domain: – skipped (HTTP $API_CODE: $(err_msg) | body: $(err_snippet))"
    mark_incomplete
  fi
}

# Step 2 — browser API key HTTP referrer allowlist. The app key is the
# one whose allowlist already carries the app's github.io origin.
step2() {
  local base="https://apikeys.googleapis.com/v2/projects/$PROJECT/locations/global/keys"
  local page_token="" page=0 url
  : > "$WORKDIR/keypages.txt"
  while : ; do
    url="$base?pageSize=100"
    [[ -n "$page_token" ]] && url="$url&pageToken=$page_token"
    api GET "$url"
    if [[ "$API_CODE" != "200" ]]; then
      log_line "step 2 api key referrer: – skipped (HTTP $API_CODE: $(err_msg) | body: $(err_snippet))"
      mark_incomplete; return
    fi
    cp "$API_BODY" "$WORKDIR/keypage-$page.json"
    echo "$WORKDIR/keypage-$page.json" >> "$WORKDIR/keypages.txt"
    page_token="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("nextPageToken", ""))
' "$API_BODY")"
    page=$((page + 1))
    [[ -n "$page_token" && $page -lt 5 ]] || break
  done
  python3 - "$WORKDIR/keypages.txt" "$WORKDIR/s2-verdict.txt" "$WORKDIR/s2-body.json" \
      "$ANCHOR_REFERRER" "$TARGET_REFERRER" <<'PY'
import json, sys
keys = []
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        keys.extend(json.load(open(line)).get("keys") or [])
verdict = open(sys.argv[2], "w")
target_key = None
for k in keys:
    restr = k.get("restrictions") or {}
    referrers = (restr.get("browserKeyRestrictions") or {}).get("allowedReferrers") or []
    if sys.argv[4] in referrers:
        target_key = k
        break
if target_key is None:
    verdict.write("NOTFOUND")
elif sys.argv[5] in ((target_key.get("restrictions") or {}).get("browserKeyRestrictions") or {}).get("allowedReferrers", []):
    verdict.write("ALREADY")
else:
    restr = dict(target_key.get("restrictions") or {})
    browser = dict(restr.get("browserKeyRestrictions") or {})
    refs = list(browser.get("allowedReferrers") or [])
    refs.append(sys.argv[5])
    browser["allowedReferrers"] = refs
    restr["browserKeyRestrictions"] = browser
    json.dump({"name": target_key["name"], "restrictions": restr},
              open(sys.argv[3], "w"))
    verdict.write("PATCH " + target_key["name"])
PY
  local verdict key_name
  verdict="$(cat "$WORKDIR/s2-verdict.txt")"
  case "$verdict" in
    ALREADY)
      log_line "step 2 api key referrer $TARGET_REFERRER: ✓ already" ;;
    NOTFOUND)
      log_line "step 2 api key referrer: – skipped (app browser key not found — no key carries $ANCHOR_REFERRER)"
      mark_incomplete ;;
    PATCH\ *)
      key_name="${verdict#PATCH }"
      api PATCH "https://apikeys.googleapis.com/v2/$key_name?updateMask=restrictions" "$WORKDIR/s2-body.json"
      if [[ "$API_CODE" == "200" ]]; then
        log_line "step 2 api key referrer $TARGET_REFERRER: ✓ applied"
      else
        log_line "step 2 api key referrer: – skipped (HTTP $API_CODE: $(err_msg) | body: $(err_snippet))"
        mark_incomplete
      fi ;;
    *)
      log_line "step 2 api key referrer: – skipped (unexpected key-scan result)"
      mark_incomplete ;;
  esac
}

# Remove the Private Section match blocks (section_access,
# section_passes_bearer, section_passes_bound) — including the comment
# block directly above each — from a rules source. $1 in, $2 out.
rules_strip_section() {
  python3 - "$1" "$2" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split("\n")
pat = re.compile(r"^\s*match\s+/section_(access|passes_bearer|passes_bound)/")
out, i = [], 0
while i < len(lines):
    if pat.match(lines[i]):
        while out and out[-1].strip().startswith("//"):
            out.pop()
        depth, started = 0, False
        while i < len(lines):
            depth += lines[i].count("{") - lines[i].count("}")
            if "{" in lines[i]:
                started = True
            i += 1
            if started and depth <= 0:
                break
        if i < len(lines) and lines[i].strip() == "":
            i += 1
        continue
    out.append(lines[i])
    i += 1
open(sys.argv[2], "w").write("\n".join(out))
PY
}

# Canonical form for rules comparison: trimmed lines, blanks dropped.
rules_canonical() {
  python3 - "$1" <<'PY'
import sys
lines = [ln.strip() for ln in open(sys.argv[1]).read().split("\n")]
print("\n".join(ln for ln in lines if ln))
PY
}

# Step 3 — publish the section rules, guarded: the repo source may
# differ from live ONLY by the Private Section blocks.
step3() {
  gh api "$RULES_REPO_PATH" --jq .content > "$WORKDIR/repo.b64" 2>"$WORKDIR/gh.err"
  if [[ ! -s "$WORKDIR/repo.b64" ]]; then
    {
      echo "=== $(date '+%Y-%m-%d %H:%M:%S %Z') gh api $RULES_REPO_PATH (repo rules fetch)"
      cat "$WORKDIR/gh.err"
      echo ""
    } >> "$API_ERR_LOG"
    log_line "step 3 firestore rules: – skipped (could not fetch repo rules source via gh | detail: $(file_snippet "$WORKDIR/gh.err"))"
    mark_incomplete; return
  fi
  if ! base64 -d < "$WORKDIR/repo.b64" > "$WORKDIR/repo.rules" 2>/dev/null || [[ ! -s "$WORKDIR/repo.rules" ]]; then
    log_line "step 3 firestore rules: – skipped (repo rules source did not decode)"
    mark_incomplete; return
  fi
  local rel_url="https://firebaserules.googleapis.com/v1/projects/$PROJECT/releases/cloud.firestore"
  api GET "$rel_url"
  if [[ "$API_CODE" != "200" ]]; then
    log_line "step 3 firestore rules: – skipped (HTTP $API_CODE reading release: $(err_msg) | body: $(err_snippet))"
    mark_incomplete; return
  fi
  local ruleset_name
  ruleset_name="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("rulesetName", ""))
' "$API_BODY")"
  if [[ -z "$ruleset_name" ]]; then
    log_line "step 3 firestore rules: – skipped (live release names no ruleset)"
    mark_incomplete; return
  fi
  api GET "https://firebaserules.googleapis.com/v1/$ruleset_name"
  if [[ "$API_CODE" != "200" ]]; then
    log_line "step 3 firestore rules: – skipped (HTTP $API_CODE reading live ruleset: $(err_msg) | body: $(err_snippet))"
    mark_incomplete; return
  fi
  python3 - "$API_BODY" "$WORKDIR/live.rules" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
files = ((d.get("source") or {}).get("files")) or []
content = "\n".join(f.get("content", "") for f in files)
open(sys.argv[2], "w").write(content)
PY
  if grep -q 'section_access' "$WORKDIR/live.rules"; then
    log_line "step 3 firestore rules (section_access block): ✓ already"
    return
  fi
  rules_strip_section "$WORKDIR/repo.rules" "$WORKDIR/repo-stripped.rules"
  rules_canonical "$WORKDIR/repo-stripped.rules" > "$WORKDIR/repo.canon"
  rules_canonical "$WORKDIR/live.rules" > "$WORKDIR/live.canon"
  if ! cmp -s "$WORKDIR/repo.canon" "$WORKDIR/live.canon"; then
    mark_permanent "live rules differ beyond the section blocks"
    log_line "step 3 firestore rules: – skipped (live rules differ from the repo source by more than the section block — not publishing)"
    mark_incomplete; return
  fi
  python3 - "$WORKDIR/repo.rules" "$WORKDIR/s3-body.json" <<'PY'
import json, sys
content = open(sys.argv[1]).read()
body = {"source": {"files": [{"name": "firestore.rules", "content": content}]}}
json.dump(body, open(sys.argv[2], "w"))
PY
  api POST "https://firebaserules.googleapis.com/v1/projects/$PROJECT/rulesets" "$WORKDIR/s3-body.json"
  if [[ "$API_CODE" != "200" ]]; then
    log_line "step 3 firestore rules: – skipped (HTTP $API_CODE creating ruleset: $(err_msg) | body: $(err_snippet))"
    mark_incomplete; return
  fi
  local new_ruleset
  new_ruleset="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("name", ""))
' "$API_BODY")"
  python3 - "$WORKDIR/s3-patch.json" "$PROJECT" "$new_ruleset" <<'PY'
import json, sys
body = {"name": "projects/%s/releases/cloud.firestore" % sys.argv[2],
        "rulesetName": sys.argv[3]}
json.dump(body, open(sys.argv[1], "w"))
PY
  api PATCH "$rel_url?updateMask=rulesetName" "$WORKDIR/s3-patch.json"
  if [[ "$API_CODE" != "200" ]]; then
    log_line "step 3 firestore rules: – skipped (HTTP $API_CODE updating release: $(err_msg) | body: $(err_snippet))"
    mark_incomplete; return
  fi
  api GET "$rel_url"
  local verify_name=""
  if [[ "$API_CODE" == "200" ]]; then
    verify_name="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1])).get("rulesetName", ""))
' "$API_BODY")"
  fi
  if [[ -n "$new_ruleset" && "$verify_name" == "$new_ruleset" ]]; then
    log_line "step 3 firestore rules (section_access block): ✓ applied"
  else
    log_line "step 3 firestore rules: – skipped (release did not verify after publish)"
    mark_incomplete
  fi
}

# Step 4 — one section_access seat.
step4_one() {
  local email="${1,,}" tier="$2" masked url
  masked="$(mask_email "$email")"
  url="https://firestore.googleapis.com/v1/projects/$PROJECT/databases/(default)/documents/section_access/$email"
  api GET "$url"
  if [[ "$API_CODE" == "200" ]]; then
    if python3 -c '
import json, sys
f = (json.load(open(sys.argv[1])).get("fields") or {})
tier = (f.get("tier") or {}).get("stringValue")
enabled = (f.get("enabled") or {}).get("booleanValue")
sys.exit(0 if tier == sys.argv[2] and enabled is True else 1)
' "$API_BODY" "$tier"; then
      log_line "step 4 $tier seat $masked: ✓ already"
      return
    fi
  elif [[ "$API_CODE" != "404" ]]; then
    log_line "step 4 $tier seat $masked: – skipped (HTTP $API_CODE: $(err_msg) | body: $(err_snippet))"
    mark_incomplete; return
  fi
  python3 - "$WORKDIR/s4-body.json" "$PROJECT" "$email" "$tier" <<'PY'
import json, sys
name = ("projects/%s/databases/(default)/documents/section_access/%s"
        % (sys.argv[2], sys.argv[3]))
body = {"name": name,
        "fields": {"tier": {"stringValue": sys.argv[4]},
                   "enabled": {"booleanValue": True}}}
json.dump(body, open(sys.argv[1], "w"))
PY
  api PATCH "$url?updateMask.fieldPaths=tier&updateMask.fieldPaths=enabled" "$WORKDIR/s4-body.json"
  if [[ "$API_CODE" != "200" ]]; then
    log_line "step 4 $tier seat $masked: – skipped (HTTP $API_CODE: $(err_msg) | body: $(err_snippet))"
    mark_incomplete; return
  fi
  api GET "$url"
  if [[ "$API_CODE" == "200" ]] && python3 -c '
import json, sys
f = (json.load(open(sys.argv[1])).get("fields") or {})
tier = (f.get("tier") or {}).get("stringValue")
enabled = (f.get("enabled") or {}).get("booleanValue")
sys.exit(0 if tier == sys.argv[2] and enabled is True else 1)
' "$API_BODY" "$tier"; then
    log_line "step 4 $tier seat $masked: ✓ applied"
  else
    log_line "step 4 $tier seat $masked: – skipped (seat did not verify after write)"
    mark_incomplete
  fi
}

step4() {
  if [[ ${#OWNERS[@]} -eq 0 && ${#FAMILY[@]} -eq 0 ]]; then
    log_line "step 4 section_access seats: – skipped (no --owner/--family addresses supplied)"
    mark_incomplete; return
  fi
  local email
  for email in "${OWNERS[@]}"; do step4_one "$email" owner; done
  for email in "${FAMILY[@]}"; do step4_one "$email" family; done
}

# Step 5 — Muse's Firebase access: store the SAME service-account
# JSON this run authenticated with (the Downloads file) as the
# fleet-kit secret. A service account cannot mint new keys for
# itself, so nothing is created — the file is piped straight into
# `gh secret set` and verified with `gh secret list`.
step5() {
  if ! gh secret set "$SECRET_NAME" -R "$SECRET_REPO" < "$KEYFILE" 2>"$WORKDIR/gh5.err"; then
    {
      echo "=== $(date '+%Y-%m-%d %H:%M:%S %Z') step 5: gh secret set $SECRET_NAME -R $SECRET_REPO"
      cat "$WORKDIR/gh5.err"
      echo ""
    } >> "$API_ERR_LOG"
    log_line "step 5 Muse firebase access: – skipped (gh secret set failed | detail: $(file_snippet "$WORKDIR/gh5.err"))"
    mark_incomplete
    log_line "step 5 note: the Downloads JSON was not stored as the fleet-kit secret — Muse has no Firebase access until a run stores it."
    return
  fi
  if gh secret list -R "$SECRET_REPO" 2>"$WORKDIR/gh5.err" | grep -q "^$SECRET_NAME"; then
    log_line "step 5 Muse firebase access: ✓ applied — the service-account JSON from Downloads is now the fleet-kit secret $SECRET_NAME; do NOT delete that key in Firebase or this access breaks; revocable anytime in Firebase Console → Project settings → Service accounts."
  else
    {
      echo "=== $(date '+%Y-%m-%d %H:%M:%S %Z') step 5: gh secret list -R $SECRET_REPO (verification)"
      cat "$WORKDIR/gh5.err"
      echo ""
    } >> "$API_ERR_LOG"
    log_line "step 5 Muse firebase access: – skipped (secret $SECRET_NAME did not verify in gh secret list)"
    mark_incomplete
    log_line "step 5 note: the Downloads JSON was not verified as the fleet-kit secret — Muse has no Firebase access until a run stores it."
  fi
}

# Compose firebase-converge-errors.txt from the run's stderr and the
# API error log, masking tier addresses before it is committed.
compose_errors() {
  {
    echo "firebase-converge errors — $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""
    echo "== run stderr =="
    cat "$STDERR_LOG" 2>/dev/null
    echo ""
    echo "== api errors =="
    cat "$API_ERR_LOG" 2>/dev/null
  } | mask_stream > "$ERRORS_FILE"
}

commit_results() {
  (
    cd "$REPO_ROOT" || return
    local files=(firebase-converge-results.txt)
    git add -- firebase-converge-results.txt 2>/dev/null || return
    if [[ "$OVERALL_OK" == "0" ]]; then
      git add -- firebase-converge-errors.txt 2>/dev/null
      files+=(firebase-converge-errors.txt)
    elif [[ -f firebase-converge-errors.txt ]]; then
      # Green run: a stale errors file from an earlier failed run
      # must not linger — remove it so the repo state reads clean.
      rm -f firebase-converge-errors.txt
      git add -A -- firebase-converge-errors.txt 2>/dev/null
      files+=(firebase-converge-errors.txt)
    fi
    if git diff --cached --quiet -- "${files[@]}" 2>/dev/null; then
      echo "results: unchanged — nothing to commit"
      return
    fi
    if ! git commit -q -m "firebase-converge results $(date '+%Y-%m-%d %H:%M')" -- "${files[@]}" 2>/dev/null; then
      echo "results: commit failed (files are saved locally at $RESULTS)"
      return
    fi
    if git push -q origin HEAD 2>/dev/null; then
      if [[ "$OVERALL_OK" == "0" ]]; then
        echo "results: committed and pushed (results + errors)"
      else
        echo "results: committed and pushed"
      fi
    else
      echo "results: committed locally — push failed, will ride the next push"
    fi
  )
}

# Insert the outcome flag as line 2 of the results file (directly
# under the header) and echo it to the terminal like every other
# results line. SUCCESS = every step applied/already; IMPOSSIBLE =
# a permanent failure was recorded (first one wins); anything else
# is INCOMPLETE. Reporting only — no behavior depends on it.
write_flag() {
  local flag_line="$1"
  { head -n 1 "$RESULTS"; echo "$flag_line"; tail -n +2 "$RESULTS"; } \
    > "$RESULTS.flagtmp" && mv "$RESULTS.flagtmp" "$RESULTS"
  echo "$flag_line"
}

finalize() {
  local flag_line
  if [[ "$OVERALL_OK" == "1" ]]; then
    flag_line="flag: SUCCESS"
  elif [[ -n "$PERMANENT_REASON" ]]; then
    flag_line="flag: IMPOSSIBLE: $PERMANENT_REASON"
  else
    flag_line="flag: INCOMPLETE"
  fi
  write_flag "$flag_line"
  if [[ "$OVERALL_OK" == "1" ]]; then
    log_line "summary: OK — every step applied or already in place"
  else
    log_line "summary: INCOMPLETE — one or more steps skipped (see above); full error detail in firebase-converge-errors.txt"
    compose_errors
  fi
  commit_results
}

main() {
  if ! parse_args "$@"; then
    echo "usage: bash scripts/firebase-converge.sh [KEYFILE.json] --owner <emails...> --family <emails...>"
    exit 2
  fi
  : > "$RESULTS"
  log_line "firebase-converge results — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  if ! ensure_tools; then
    mark_incomplete
    finalize
    exit 1
  fi
  if ! resolve_keyfile; then
    if [[ -n "$KEYFILE_ARG" ]]; then
      mark_permanent "keyfile not found at the given path"
      log_line "auth: – skipped (service-account JSON not found at $KEYFILE_ARG)"
    else
      mark_permanent "keyfile not found in Downloads"
      log_line "auth: – skipped (no service-account JSON found in ~/storage/downloads)"
    fi
    mark_incomplete
    finalize
    exit 1
  fi
  if ! get_access_token; then
    if [[ -n "$API_CODE" ]]; then
      # A dead/revoked key is permanent: the token endpoint says
      # so in the response body (invalid_grant / invalid_client).
      if [[ -f "$API_BODY" ]] && grep -q "invalid_grant" "$API_BODY"; then
        mark_permanent "service-account key rejected (invalid_grant)"
      elif [[ -f "$API_BODY" ]] && grep -q "invalid_client" "$API_BODY"; then
        mark_permanent "service-account key rejected (invalid_client)"
      fi
      log_line "auth: – skipped (HTTP $API_CODE exchanging the service-account key: $(err_msg) | body: $(err_snippet))"
    elif [[ -n "$AUTH_FAIL_MSG" ]]; then
      # AUTH_FAIL_MSG is set only by sign_jwt's no-signer path.
      mark_permanent "no RSA signer available (openssl and node both missing)"
      log_line "auth: – skipped ($AUTH_FAIL_MSG)"
    else
      log_line "auth: – skipped (service-account JSON unreadable or signing failed — see firebase-converge-errors.txt)"
    fi
    mark_incomplete
    finalize
    exit 1
  fi
  log_line "auth: ✓ applied (service-account token from Downloads JSON)"
  step1
  step2
  step3
  step4
  step5
  finalize
  exit $((1 - OVERALL_OK))
}

# Loop wrapper (default mode): Andrew runs one command and the
# script babysits itself. Each attempt re-pulls the repo — so a
# fix pushed mid-loop is picked up automatically — then runs one
# full pass as a CHILD invocation of the freshly pulled script
# (`--once`), which commits+pushes its own results/errors as the
# audit trail. A failed git pull (offline, conflict) never kills
# the loop: it is noted and the local copy runs. The wrapper only
# prints to the terminal; it writes no files of its own.
loop_main() {
  local delays=(${FB_LOOP_DELAYS:-60 180 300})
  local max_attempts=20 attempt delay idx
  local self="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if ! git -C "$REPO_ROOT" pull -q >/dev/null 2>&1; then
      echo "--- git pull failed — continuing with the local copy ---"
    fi
    if bash "$self" --once "$@"; then
      echo "--- firebase-converge: SUCCESS on attempt $attempt/$max_attempts ---"
      return 0
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      idx=$((attempt - 1))
      if [[ $idx -ge ${#delays[@]} ]]; then idx=$((${#delays[@]} - 1)); fi
      delay="${delays[$idx]}"
      echo "--- attempt $attempt/$max_attempts — incomplete, retrying in ${delay}s (script re-pulled) ---"
      sleep "$delay"
    fi
  done
  echo "summary: INCOMPLETE after $max_attempts attempts — stopping loop"
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ONCE=0
  PASS_ARGS=()
  for _arg in "$@"; do
    if [[ "$_arg" == "--once" ]]; then
      ONCE=1
    else
      PASS_ARGS+=("$_arg")
    fi
  done
  if [[ $ONCE -eq 0 ]]; then
    loop_main "${PASS_ARGS[@]}"
    exit $?
  fi
  WORKDIR="$(mktemp -d)"
  STDERR_LOG="$WORKDIR/stderr.log"
  API_ERR_LOG="$WORKDIR/api-errors.log"
  : > "$STDERR_LOG"
  : > "$API_ERR_LOG"
  trap 'rm -rf "$WORKDIR"' EXIT
  main "${PASS_ARGS[@]}" 2>>"$STDERR_LOG"
fi
