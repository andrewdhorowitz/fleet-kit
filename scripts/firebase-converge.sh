#!/usr/bin/env bash
# firebase-converge.sh — one-shot converger for the Private Section's
# Firebase activation steps (project: family-routines-app).
#
# Runs on Andrew's phone (Termux) under HIS OWN owner sign-in via the
# Firebase CLI — there is deliberately no service-account key and no
# third-party access. Steps:
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
#
# Converger contract: check -> apply what's missing -> report
# "✓ applied" / "✓ already" / "– skipped (reason)" per step, into
# firebase-converge-results.txt at the repo root (flushed per line,
# then committed + pushed by the script). Idempotent; safe to re-run.
#
# PRIVACY: no email addresses are stored in this repo or in the
# results file. Tier addresses arrive as run-time arguments only and
# are reported masked (first two letters + domain).
#
# Usage:
#   bash scripts/firebase-converge.sh --owner <emails...> --family <emails...>

PROJECT="family-routines-app"
TARGET_DOMAIN="private.andrewdhorowitz.com"
TARGET_REFERRER="private.andrewdhorowitz.com/*"
ANCHOR_REFERRER="andrewdhorowitz.github.io/*"
RULES_REPO_PATH="repos/andrewdhorowitz/routines-and-streaks/contents/firestore.rules"

# firebase-tools' public OAuth client constants, embedded in the
# open-source CLI itself (firebase-tools src/api.ts) — not a secret.
FB_CLIENT_ID="563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com"
FB_CLIENT_SECRET="p7hKVjcEkrpPYPcjEzbppN9z"
TOKEN_URL="${FIREBASE_CONVERGE_TOKEN_URL:-https://oauth2.googleapis.com/token}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS="$REPO_ROOT/firebase-converge-results.txt"

OVERALL_OK=1
DID_LOGIN=0
ACCESS_TOKEN=""
API_CODE=""
API_BODY=""
WORKDIR=""
OWNERS=()
FAMILY=()

set -u

log_line() { echo "$1" | tee -a "$RESULTS"; }

mark_incomplete() { OVERALL_OK=0; }

# First error message out of a Google API JSON error body.
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

# api METHOD URL [BODYFILE] -> sets API_CODE (3-digit) and API_BODY (file)
api() {
  local method="$1" url="$2" body="${3:-}"
  API_BODY="$WORKDIR/resp-$$.json"
  local args=(-sS -g -o "$API_BODY" -w '%{http_code}' -X "$method"
              -H "Authorization: Bearer $ACCESS_TOKEN"
              -H 'Content-Type: application/json')
  if [[ -n "$body" ]]; then args+=(--data-binary "@$body"); fi
  API_CODE="$(curl "${args[@]}" "$url" 2>"$WORKDIR/curl.err" || echo 000)"
  API_CODE="${API_CODE:0:3}"
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
  OWNERS=(); FAMILY=()
  local mode=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --owner)  mode="owner" ;;
      --family) mode="family" ;;
      --*) echo "firebase-converge: unknown option: $1" >&2; return 2 ;;
      *)
        case "$mode" in
          owner)  OWNERS+=("$1") ;;
          family) FAMILY+=("$1") ;;
          *) echo "firebase-converge: address before any --owner/--family flag: $1" >&2; return 2 ;;
        esac ;;
    esac
    shift
  done
  return 0
}

# _ensure_pkg CMD PKG -> 0 installed now, 2 already present, 1 failed
_ensure_pkg() {
  if command -v "$1" >/dev/null 2>&1; then return 2; fi
  if command -v pkg >/dev/null 2>&1; then pkg install -y "$2" >/dev/null 2>&1; fi
  if command -v "$1" >/dev/null 2>&1; then return 0; fi
  return 1
}

ensure_tools() {
  local installed=() failed=() rc
  _ensure_pkg python3 python; rc=$?; [[ $rc -eq 0 ]] && installed+=(python3); [[ $rc -eq 1 ]] && failed+=(python3)
  _ensure_pkg node nodejs;    rc=$?; [[ $rc -eq 0 ]] && installed+=(node);    [[ $rc -eq 1 ]] && failed+=(node)
  _ensure_pkg curl curl;      rc=$?; [[ $rc -eq 0 ]] && installed+=(curl);    [[ $rc -eq 1 ]] && failed+=(curl)
  if ! command -v firebase >/dev/null 2>&1; then
    if command -v npm >/dev/null 2>&1; then
      echo "firebase-converge: installing firebase-tools (one-time, can take a few minutes)…"
      npm install -g firebase-tools >/dev/null 2>&1
    fi
    if command -v firebase >/dev/null 2>&1; then installed+=(firebase-tools); else failed+=(firebase-tools); fi
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    log_line "setup: – skipped (could not install: ${failed[*]})"
    return 1
  fi
  if [[ ${#installed[@]} -gt 0 ]]; then
    log_line "setup: ✓ applied (installed: ${installed[*]})"
  else
    log_line "setup: ✓ already (python3, node, firebase-tools, curl present)"
  fi
  return 0
}

# Access token from the Firebase CLI's own sign-in
# (~/.config/configstore/firebase-tools.json): reuse the stored token
# while fresh, otherwise exchange the refresh token. If nobody is
# signed in, run the CLI's interactive login once (Andrew completes
# Google sign-in in his browser); later runs are silent.
get_access_token() {
  local cfg="$HOME/.config/configstore/firebase-tools.json"
  if [[ ! -f "$cfg" ]]; then
    if [[ "${FIREBASE_CONVERGE_SKIP_LOGIN:-}" == "1" ]]; then return 1; fi
    command -v firebase >/dev/null 2>&1 || return 1
    echo "firebase-converge: no Firebase sign-in found — starting one-time login…"
    firebase login --no-localhost || return 1
    DID_LOGIN=1
  fi
  [[ -f "$cfg" ]] || return 1
  local parsed stored_at refresh resp code
  parsed="$(python3 - "$cfg" <<'PY'
import json, sys, time
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(3)
t = d.get("tokens") or {}
at = t.get("access_token") or ""
exp = t.get("expires_at") or 0
try:
    exp = int(exp)
except Exception:
    exp = 0
now_ms = int(time.time() * 1000)
print(at if at and exp > now_ms + 60000 else "")
print(t.get("refresh_token") or "")
PY
)" || return 1
  stored_at="$(printf '%s\n' "$parsed" | sed -n '1p')"
  refresh="$(printf '%s\n' "$parsed" | sed -n '2p')"
  if [[ -n "$stored_at" ]]; then ACCESS_TOKEN="$stored_at"; return 0; fi
  [[ -n "$refresh" ]] || return 1
  resp="$WORKDIR/token.json"
  local token_url="${FIREBASE_CONVERGE_TOKEN_URL:-$TOKEN_URL}"
  code="$(curl -sS -o "$resp" -w '%{http_code}' -X POST "$token_url" \
      --data-urlencode "client_id=$FB_CLIENT_ID" \
      --data-urlencode "client_secret=$FB_CLIENT_SECRET" \
      --data-urlencode "refresh_token=$refresh" \
      --data-urlencode "grant_type=refresh_token" || echo 000)"
  [[ "${code:0:3}" == "200" ]] || return 1
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
    log_line "step 1 authorized domain: – skipped (HTTP $API_CODE: $(jerr "$API_BODY"))"
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
  python3 - "$API_BODY" "$WORKDIR/s1-body.json" "$TARGET_DOMAIN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
domains = list(d.get("authorizedDomains") or [])
if sys.argv[3] not in domains:
    domains.append(sys.argv[3])
body = {"name": d.get("name") or "projects/%s/config" % "family-routines-app",
        "authorizedDomains": domains}
json.dump(body, open(sys.argv[2], "w"))
PY
  api PATCH "$url?updateMask=authorizedDomains" "$WORKDIR/s1-body.json"
  if [[ "$API_CODE" == "200" ]]; then
    log_line "step 1 authorized domain $TARGET_DOMAIN: ✓ applied"
  else
    log_line "step 1 authorized domain: – skipped (HTTP $API_CODE: $(jerr "$API_BODY"))"
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
      log_line "step 2 api key referrer: – skipped (HTTP $API_CODE: $(jerr "$API_BODY"))"
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
        log_line "step 2 api key referrer: – skipped (HTTP $API_CODE: $(jerr "$API_BODY"))"
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
    log_line "step 3 firestore rules: – skipped (could not fetch repo rules source via gh)"
    mark_incomplete; return
  fi
  if ! base64 -d < "$WORKDIR/repo.b64" > "$WORKDIR/repo.rules" 2>/dev/null || [[ ! -s "$WORKDIR/repo.rules" ]]; then
    log_line "step 3 firestore rules: – skipped (repo rules source did not decode)"
    mark_incomplete; return
  fi
  local rel_url="https://firebaserules.googleapis.com/v1/projects/$PROJECT/releases/cloud.firestore"
  api GET "$rel_url"
  if [[ "$API_CODE" != "200" ]]; then
    log_line "step 3 firestore rules: – skipped (HTTP $API_CODE reading release: $(jerr "$API_BODY"))"
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
    log_line "step 3 firestore rules: – skipped (HTTP $API_CODE reading live ruleset: $(jerr "$API_BODY"))"
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
    log_line "step 3 firestore rules: – skipped (HTTP $API_CODE creating ruleset: $(jerr "$API_BODY"))"
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
    log_line "step 3 firestore rules: – skipped (HTTP $API_CODE updating release: $(jerr "$API_BODY"))"
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
    log_line "step 4 $tier seat $masked: – skipped (HTTP $API_CODE: $(jerr "$API_BODY"))"
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
    log_line "step 4 $tier seat $masked: – skipped (HTTP $API_CODE: $(jerr "$API_BODY"))"
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

commit_results() {
  (
    cd "$REPO_ROOT" || return
    git add -- firebase-converge-results.txt 2>/dev/null || return
    if git diff --cached --quiet -- firebase-converge-results.txt 2>/dev/null; then
      echo "results: unchanged — nothing to commit"
      return
    fi
    if ! git commit -q -m "firebase-converge results $(date '+%Y-%m-%d %H:%M')" -- firebase-converge-results.txt 2>/dev/null; then
      echo "results: commit failed (file is saved locally at $RESULTS)"
      return
    fi
    if git push -q origin HEAD 2>/dev/null; then
      echo "results: committed and pushed"
    else
      echo "results: committed locally — push failed, will ride the next push"
    fi
  )
}

finalize() {
  if [[ "$OVERALL_OK" == "1" ]]; then
    log_line "summary: OK — every step applied or already in place"
  else
    log_line "summary: INCOMPLETE — one or more steps skipped (see above)"
  fi
  commit_results
}

main() {
  if ! parse_args "$@"; then
    echo "usage: bash scripts/firebase-converge.sh --owner <emails...> --family <emails...>" >&2
    exit 2
  fi
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"' EXIT
  : > "$RESULTS"
  log_line "firebase-converge results — $(date '+%Y-%m-%d %H:%M:%S %Z')"
  if ! ensure_tools; then
    finalize
    exit 1
  fi
  if ! get_access_token; then
    log_line "auth: – skipped (no usable Firebase sign-in — run: firebase login --no-localhost)"
    mark_incomplete
    finalize
    exit 1
  fi
  if [[ "$DID_LOGIN" == "1" ]]; then
    log_line "setup: ✓ applied (firebase login completed)"
  fi
  step1
  step2
  step3
  step4
  finalize
  exit $((1 - OVERALL_OK))
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
