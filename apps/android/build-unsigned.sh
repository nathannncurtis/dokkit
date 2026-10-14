#!/bin/bash
# Runs the unit tests, then builds the release app without signing it and leaves out/dokkit-android-unsigned.apk.
# Whoever installs it signs it with their own key first. Needs JDK 17, the Android SDK and Gradle 8.11 or later.
set -euo pipefail
cd "$(dirname "$0")"
./sync-fixtures.sh
gradle=gradle
[ -x ./gradlew ] && gradle=./gradlew
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
[ -n "$sdk" ] && echo "platforms: $(ls "$sdk/platforms" | tr '\n' ' ')"
rm -rf out
mkdir -p out

rc=0
"$gradle" --console=plain --stacktrace :app:testReleaseUnitTest || rc=$?
cat app/build/test-results/testReleaseUnitTest/*.xml 2>/dev/null | grep -o '<testsuite [^>]*>' |
  sed -E 's/.*tests="([0-9]+)" skipped="([0-9]+)" failures="([0-9]+)" errors="([0-9]+)".*/\1 \3 \4/' |
  awk '{t+=$1; f+=$2; e+=$3} END {printf "tests completed: %d, failed: %d, errors: %d\n", t, f, e}' || true
[ "$rc" -eq 0 ] || { echo "FAILED: unit tests"; exit "$rc"; }

"$gradle" --console=plain --stacktrace :app:assembleRelease
apk=app/build/outputs/apk/release/app-release-unsigned.apk
test -f "$apk"
cp "$apk" out/dokkit-android-unsigned.apk
(cd out && sha256sum dokkit-android-unsigned.apk > dokkit-android-unsigned.apk.sha256)

manifest=$(find app/build/intermediates -path '*merged_manifests*' -path '*elease*' -name AndroidManifest.xml | head -1)
echo "merged manifest: $manifest"
perms=$(tr '\n' ' ' < "$manifest" | grep -o '<uses-permission[^>]*>' | sed -E 's/[[:space:]]+/ /g')
echo "$perms" | sed 's/^/uses-permission: /'
bad=$(echo "$perms" | grep -oE 'android:name="[^"]+"' | grep -vE 'android.permission.(INTERNET|CAMERA|USE_BIOMETRIC|USE_FINGERPRINT)"' || true)
[ -z "$bad" ] || { echo "FAILED: unexpected permission: $bad"; exit 1; }
aapt2=$(ls "$sdk"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1 || true)
[ -z "$aapt2" ] || "$aapt2" dump permissions "$apk" || true
ls -l out
echo "BUILD OK apk=$(stat -c %s out/dokkit-android-unsigned.apk) bytes"
