#!/data/data/com.termux/files/usr/bin/bash
# strip-admin-extra-read.sh — OWNER ONLY, one-off. Removes the undeclared
# "Account API Tokens Read" permission group from the admin token ITSELF
# ("Token Admin — owner only", user token). The admin is edited by this
# script because the converger (scripts/cf_token_converge.py) is hard-guarded
# to never modify the admin token — so this one-off exists.
# Ruled by Andrew 2026-11-05: strip the extra read; the admin's declared
# policy in scripts/tokens.json is "API Tokens Write" only.
# The admin token value is read from ~/cf-token-admin.txt (run
# scripts/token-capture.sh first, pasting from 1Password). The value is
# never printed.
# Safety: verifies the token first, requires its live permission groups to
# be EXACTLY {"API Tokens Write", "Account API Tokens Read"} before touching
# anything, aborts on any other set, and re-reads after the edit to confirm.
# Method: token updates are PUT (full-object replace), so the PUT body
# carries the full preserved token — name, status, expires_on, not_before
# and condition copied verbatim from the read — plus the filtered policies.
# PATCH is not available on /user/tokens/{id}: Andrew's first run
# (2026-11-05) failed with error 7001, "Method PATCH not available for
# that URI."
# If the API refuses to let a token edit itself, do it in the dashboard:
# My Profile → API Tokens → Token Admin — owner only → Edit → uncheck
# Account API Tokens Read → Update (the token value does not change).

set -u

if [ ! -f "$HOME/cf-token-admin.txt" ]; then
  echo "No ~/cf-token-admin.txt — run scripts/token-capture.sh first (paste the admin token from 1Password)."
  exit 1
fi
tok=$(tr -d '\r\n ' < "$HOME/cf-token-admin.txt")
if [ -z "$tok" ]; then
  echo "~/cf-token-admin.txt is empty — run scripts/token-capture.sh first (paste the admin token from 1Password)."
  exit 1
fi

# Step 1: verify the token, require status "active", get its own id.
own_id=$(python3 -c '
import json, sys, urllib.request, urllib.error
req = urllib.request.Request("https://api.cloudflare.com/client/v4/user/tokens/verify")
req.add_header("Authorization", "Bearer " + sys.argv[1])
try:
    resp = json.load(urllib.request.urlopen(req, timeout=30))
except urllib.error.HTTPError as e:
    print("Verify request failed: " + e.read().decode("utf-8", "replace"), file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print("Verify request failed: " + str(e), file=sys.stderr)
    sys.exit(1)
if not resp.get("success"):
    print("Token did not verify: " + json.dumps(resp), file=sys.stderr)
    sys.exit(1)
result = resp.get("result") or {}
if result.get("status") != "active":
    print("Token status is " + repr(result.get("status")) + ", not \"active\" — aborting.", file=sys.stderr)
    sys.exit(1)
if not result.get("id"):
    print("Verify response carried no token id — aborting.", file=sys.stderr)
    sys.exit(1)
print(result["id"])
' "$tok")
if [ -z "$own_id" ]; then
  echo "Admin token did not verify — nothing changed."
  unset tok
  exit 1
fi
echo "Admin token verified active (id $own_id)."

# Steps 2-5: read policies, require the exact expected group set, drop the
# policy carrying "Account API Tokens Read", PUT, re-read and confirm.
python3 -c '
import json, sys, urllib.request, urllib.error

API = "https://api.cloudflare.com/client/v4"
tok, own_id = sys.argv[1], sys.argv[2]
url = API + "/user/tokens/" + own_id
EXPECTED = {"API Tokens Write", "Account API Tokens Read"}
REMOVE = "Account API Tokens Read"

def call(method, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + tok)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    return json.load(urllib.request.urlopen(req, timeout=30))

def group_names(policies):
    names = set()
    for p in policies:
        for g in p.get("permission_groups", []):
            names.add(g.get("name"))
    return names

try:
    resp = call("GET")
except Exception as e:
    print("Could not read the token: " + str(e))
    sys.exit(1)
if not resp.get("success"):
    print("Could not read the token: " + json.dumps(resp))
    sys.exit(1)
result = resp.get("result") or {}
policies = result.get("policies") or []
found = group_names(policies)
if found != EXPECTED:
    print("Live permission groups are " + json.dumps(sorted(found)) +
          ", not the expected " + json.dumps(sorted(EXPECTED)) +
          " — aborting WITHOUT changes.")
    sys.exit(1)

new_policies = []
for p in policies:
    names = {g.get("name") for g in p.get("permission_groups", [])}
    if REMOVE in names:
        continue
    new_policies.append(p)
remaining = group_names(new_policies)
if remaining != {"API Tokens Write"}:
    print("After removal the remaining groups would be " + json.dumps(sorted(remaining)) +
          ", not exactly {\"API Tokens Write\"} — aborting WITHOUT changes.")
    sys.exit(1)

put_body = {"name": result.get("name"), "policies": new_policies}
for key in ("status", "expires_on", "not_before", "condition"):
    if key in result:
        put_body[key] = result[key]

print("Removing the policy carrying \"" + REMOVE + "\"...")
try:
    presp = call("PUT", put_body)
except urllib.error.HTTPError as e:
    print("PUT rejected by the API — nothing was changed. API response verbatim:")
    print(e.read().decode("utf-8", "replace"))
    sys.exit(1)
except Exception as e:
    print("PUT failed: " + str(e))
    sys.exit(1)
if not presp.get("success"):
    print("PUT rejected by the API — nothing was changed. API response verbatim:")
    print(json.dumps(presp))
    sys.exit(1)

try:
    vresp = call("GET")
except Exception as e:
    print("PUT succeeded but the re-read failed: " + str(e))
    sys.exit(1)
vresult = vresp.get("result") or {}
now = group_names(vresult.get("policies") or [])
if now != {"API Tokens Write"}:
    print("Re-read shows permission groups " + json.dumps(sorted(now)) +
          ", not exactly {\"API Tokens Write\"} — the edit did NOT land as intended.")
    sys.exit(1)
print("Success: removed \"" + REMOVE + "\" from \"" + (vresult.get("name") or own_id) +
      "\" (" + own_id + "). Remaining permission groups: API Tokens Write.")
' "$tok" "$own_id"
rc=$?
unset tok
exit $rc
