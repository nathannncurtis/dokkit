# Dokkit for Android

A read-only view of a Dokkit server, for a server that is not on the internet. It shows what needs attention and the state of every machine and service, from the sealed snapshots a relay holds. It cannot change anything on the server and sends no notifications.

The app is not on Google Play yet. Until it is, you build it and sign it with your own key.

## Build

You need JDK 17, the Android SDK (platform 35 and its build tools) and Gradle 8.11 or later.

```
cd apps/android
./build-unsigned.sh
```

The script runs the unit tests, builds the release app without signing it, and leaves `out/dokkit-android-unsigned.apk` and `out/dokkit-android-unsigned.apk.sha256`. It stops with an error if a test fails or if the merged manifest asks for a permission the app is not meant to have.

The workflow `.github/workflows/android.yml` does the same on a GitHub runner when you start it by hand, and keeps the files as the artifact `phone-android`.

## Sign and install

The unsigned file is already aligned. Make a key once, then sign:

```
keytool -genkeypair -v -keystore dokkit.jks -alias dokkit -keyalg RSA -keysize 4096 -validity 10000
apksigner sign --ks dokkit.jks --out dokkit-android.apk out/dokkit-android-unsigned.apk
apksigner verify dokkit-android.apk
adb install dokkit-android.apk
```

`apksigner` is in the `build-tools` folder of the Android SDK. Keep `dokkit.jks`: an update must be signed with the same key as the app it replaces. To install without a cable, copy `dokkit-android.apk` to the phone and open it; Android asks once to let that app install files.

## Pair it

1. In the Dokkit web interface open Settings, Phones, Add a phone. A QR code is shown once, for two minutes.
2. In the app choose Servers, Add a server, and point the camera at it. If the camera is off, paste the code into the box under it.

Several servers can be paired. Remove one from Servers and its key, token and saved snapshot are deleted from the phone.

## What is in this folder

| Path | What |
|---|---|
| `app/src/main/kotlin/dev/dokkit/phone/core/` | Everything that is not a screen, in plain Kotlin with no Android imports: snapshot models, opening a sealed snapshot, pairing codes, the relay client, the stores, and what each screen shows. |
| `app/src/main/kotlin/dev/dokkit/phone/ui/` | The Jetpack Compose screens and the camera scanner. |
| `app/src/main/kotlin/dev/dokkit/phone/` | The activity with the unlock gate, the view model, and the Keystore-backed storage. |
| `app/src/test/` | JVM unit tests and the spec's fixtures. |
| `sync-fixtures.sh` | Copies the spec's test fixtures into the tests. |
| `build-unsigned.sh` | Tests, then the unsigned release build. |

## Checks

```
./sync-fixtures.sh
gradle :app:testReleaseUnitTest
```

The tests open the spec's sealed snapshots, refuse what must be refused, decode the example snapshot, and exercise the relay client and the stores against a fake transport. The fixtures are copies of `spec/phone-cases/sealing.json` and `snapshot.json`. Run `./sync-fixtures.sh` after the spec's fixtures change.

## What the app does and does not do

- Fetches when opened, when the screen is pulled down, and every 30 seconds while in front. Nothing runs in the background: no service, no scheduled work, no notifications.
- Shows the age of the snapshot at the top of each screen; past five minutes it is a warning. With no network, or when the relay answers an error, the last snapshot stays on screen and the message says what happened.
- Refuses a snapshot whose counter is lower than the newest it has opened.
- Asks for the phone's fingerprint, face or screen lock on every launch and every return from the background. With no screen lock set, it stays locked and says so.
- Keeps the phone key, the fetch token and the last snapshot in the app's private storage, encrypted with a key in the Android Keystore. Nothing is included in a cloud backup or a device transfer.
- Contacts only the paired relays, over https. No account, analytics, crash reporting or third-party networking code.
- Asks for the internet and the camera. The unlock prompt adds the two permissions the AndroidX biometric library declares for itself; the build prints the list and stops if any other appears.
- Uses the system font size, light and dark following the phone.
