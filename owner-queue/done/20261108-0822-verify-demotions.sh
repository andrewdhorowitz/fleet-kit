#!/usr/bin/env bash
# verify-demotions — READ-ONLY post-change check (Nov 8 2026).
# Andrew demoted fourpshot Owner -> Editor on gen-lang-client-0590645241 and family-routines-app,
# and added fourpshot as Editor on play-publisher-513614. This verifies fourpshot RETAINS practical
# access to the three Firebase projects after the demotions (guard against accidental self-lockout).
# Changes nothing.
set -u
echo "== verify-demotions =="
date
timeout 60 firebase login:list 2>&1 || echo "- login:list failed (exit $?)"
echo "-- firebase projects:list (fourpshot, post-demotion) --"
timeout 120 firebase projects:list 2>&1 || echo "- projects:list failed (exit $?)"
echo "== verify complete (read-only; nothing changed) =="
exit 0
