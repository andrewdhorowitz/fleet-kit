#!/data/data/com.termux/files/usr/bin/bash
# hh-crash-pull.sh — pull Home Helper crash traces off the phone via wireless ADB.
#
# Run in Termux from the fleet-kit clone:
#   cd ~/work/fleet-kit && git pull && bash scripts/hh-crash-pull.sh
#
# Best run right after reproducing one of the button crashes, while the
# trace is still in the phone's crash buffer.
#
# What it does:
#   1. makes sure adb exists (installs android-tools if missing)
#   2. if a device is already connected, uses it as-is (never re-pairs or
#      reconnects); otherwise connects to the phone's own wireless-debugging
#      adbd (mDNS first, then pairing/connect ports read off the page)
#   3. dumps the crash buffer, dropbox crash entries, recent exit info,
#      and the installed Home Helper version (settles which build is live)
#   4. commits the results into owner-queue/results/ and pushes, for Muse
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$ROOT/owner-queue/results/hh-crash-pull-$STAMP"
mkdir -p "$OUT"
PKG="com.andrewdhorowitz.homehelper"

echo "== Home Helper crash pull $STAMP =="

if ! command -v adb >/dev/null 2>&1; then
  echo "-- adb missing; installing android-tools"
  pkg install -y android-tools || { echo "FAIL: pkg install android-tools"; exit 1; }
fi

connected() { adb devices 2>/dev/null | awk '$2 == "device" { found=1 } END { exit !found }'; }
endpoint() { adb devices 2>/dev/null | awk '$2 == "device" { print $1; exit }'; }

if connected; then
  echo "-- already connected as $(endpoint) — skipping pair/connect"
fi

if ! connected; then
  echo "-- looking for the wireless debugging endpoint (mDNS)..."
  EP="$(adb mdns services 2>/dev/null | awk '/_adb-tls-connect\._tcp/ {print $NF}' | head -1)"
  if [ -n "$EP" ]; then
    echo "-- found $EP, connecting"
    adb connect "$EP" || true
  fi
fi

if ! connected; then
  echo
  echo "Pairing/connect needed. On the phone:"
  echo "Settings > Developer options > Wireless debugging (must be ON)."
  echo "If Termux was never paired, tap 'Pair device with pairing code' there first."
  read -rp "Pairing port (blank if already paired): " PAIRPORT
  if [ -n "${PAIRPORT:-}" ]; then
    read -rp "Pairing code: " PAIRCODE
    adb pair "127.0.0.1:$PAIRPORT" "$PAIRCODE" || { echo "FAIL: adb pair"; exit 1; }
  fi
  read -rp "Connect port (from the main Wireless debugging page): " CONNPORT
  adb connect "127.0.0.1:$CONNPORT" || { echo "FAIL: adb connect"; exit 1; }
fi

adb devices | tee "$OUT/adb-devices.txt"
connected || { echo "FAIL: no device connected"; exit 1; }

echo "-- installed Home Helper version:"
adb shell dumpsys package "$PKG" | grep -E "versionName|versionCode" | head -4 | tee "$OUT/hh-version.txt"

echo "-- recent process exits (crash reasons/times):"
adb shell dumpsys activity exit-info "$PKG" > "$OUT/exit-info.txt" 2>&1
wc -l "$OUT/exit-info.txt"

echo "-- crash buffer:"
adb logcat -d -b crash -v threadtime > "$OUT/logcat-crash.txt" 2>&1
wc -l "$OUT/logcat-crash.txt"
grep -A 40 "FATAL EXCEPTION" "$OUT/logcat-crash.txt" | head -300 > "$OUT/fatal-exceptions.txt" || true

echo "-- dropbox (system crash store):"
adb shell dumpsys dropbox --print > "$OUT/dropbox.txt" 2>&1
wc -l "$OUT/dropbox.txt"

echo "-- main/system log lines mentioning the package:"
adb logcat -d -v threadtime > "$OUT/logcat-all.txt" 2>&1
grep -i "homehelper" "$OUT/logcat-all.txt" | tail -2000 > "$OUT/logcat-homehelper.txt" || true
rm -f "$OUT/logcat-all.txt"

echo "-- results in $OUT:"
ls -la "$OUT"

git add "$OUT" >/dev/null 2>&1
if git commit -m "hh-crash-pull results $STAMP" >/dev/null 2>&1 && git push >/dev/null 2>&1; then
  echo "PUSHED: results committed for Muse"
else
  echo "NOTE: git push did not complete; results are on the phone in $OUT"
fi
echo "DONE"
