#!/usr/bin/env bash
# sonar-token-converge.sh — owner-run in Termux.
#
# Prompts ONCE for a SonarCloud token (hidden input), then sets it as the
# SONAR_TOKEN GitHub Actions secret in the five fleet repos that carry the
# kit's SonarCloud step. The token lives only in memory for this run: it is
# never echoed, logged, written to disk, or committed.
set -u

REPOS=(
  andrewdhorowitz/fleet-kit
  andrewdhorowitz/aimf-protocol
  andrewdhorowitz/andrewdhorowitz.github.io
  andrewdhorowitz/family-cards-demo
  andrewdhorowitz/fleet-ci
)

printf "Paste your SonarCloud token (input hidden), then Enter: "
read -rs TOKEN
echo

if [ -z "${TOKEN:-}" ]; then
  echo "No token entered — nothing changed."
  exit 1
fi

for r in "${REPOS[@]}"; do
  if gh secret set SONAR_TOKEN --repo "$r" --body "$TOKEN" >/dev/null 2>&1; then
    echo "✓ $r — SONAR_TOKEN set"
  else
    echo "✗ $r — FAILED (check gh auth / access)"
  fi
done

unset TOKEN
echo "Done."
