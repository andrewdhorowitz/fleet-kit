#!/usr/bin/env bash
# Read-back job (queued by Muse at Andrew's request, Nov 16, 2026):
# print the QuillSend setup script's results file into this job's log so
# Muse can read it from the repo. The results file contains NO secrets
# by design - project id, OAuth client IDs, and certificate fingerprints
# (all public identifiers), plus the names of the secrets deposited.
set -u
SRC="$HOME/quillsend-setup-results.txt"
if [ -f "$SRC" ]; then
  echo "✓ applied - quillsend-setup-results.txt contents follow:"
  echo "----- BEGIN quillsend-setup-results.txt -----"
  cat "$SRC"
  echo "----- END quillsend-setup-results.txt -----"
  exit 0
else
  echo "- skipped (results file not found at $SRC)"
  exit 1
fi
