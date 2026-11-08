#!/usr/bin/env bash
# audit-gcp-accounts — READ-ONLY inventory for the fourpshot -> andrewhorowitz3 ownership verification (Andrew's request, Nov 8 2026).
# Lists which Google accounts the on-device CLIs know and which Firebase/GCP projects + billing links each account can see.
# Touches nothing: no creates, no deletes, no config changes, no auth changes.
set -u
echo "== audit-gcp-accounts =="
date
echo "-- tool inventory --"
for t in gcloud firebase node python3; do
  if command -v "$t" >/dev/null 2>&1; then echo "present: $t -> $(command -v $t)"; else echo "missing: $t"; fi
done
if command -v gcloud >/dev/null 2>&1; then
  echo "-- gcloud auth list --"
  timeout 45 gcloud auth list --format='value(account,status)' 2>&1 || echo "- gcloud auth list failed (exit $?)"
  echo "-- gcloud projects list (default account) --"
  timeout 90 gcloud projects list --format='value(projectId,projectNumber,lifecycleState)' 2>&1 || echo "- failed (exit $?)"
  for acct in fourpshot@gmail.com andrewhorowitz3@gmail.com; do
    echo "-- gcloud projects list --account=$acct --"
    timeout 90 gcloud projects list --account="$acct" --format='value(projectId,projectNumber,lifecycleState)' 2>&1 || echo "- failed for $acct (exit $?)"
    echo "-- gcloud billing projects list --account=$acct --"
    timeout 90 gcloud billing projects list --account="$acct" --format='value(name,billingAccountName,billingEnabled)' 2>&1 || echo "- failed for $acct (exit $?)"
  done
  echo "-- gcloud billing accounts list (default account) --"
  timeout 45 gcloud billing accounts list --format='value(name,displayName,open)' 2>&1 || echo "- failed (exit $?)"
fi
if command -v firebase >/dev/null 2>&1; then
  echo "-- firebase login:list --"
  timeout 60 firebase login:list 2>&1 || echo "- firebase login:list failed (exit $?)"
  echo "-- firebase projects:list (default account) --"
  timeout 120 firebase projects:list 2>&1 || echo "- failed (exit $?)"
  for acct in fourpshot@gmail.com andrewhorowitz3@gmail.com; do
    echo "-- firebase projects:list --account=$acct --"
    timeout 120 firebase --account="$acct" projects:list 2>&1 || echo "- failed for $acct (exit $?)"
  done
fi
echo "== audit complete (read-only; nothing changed) =="
exit 0
