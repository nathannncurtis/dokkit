# Dokkit for the desktop

A desktop app for a Dokkit server. Its window is the server's own web app, so everything you can do at `https://<name>.dokkit.page` you can do here. On top of that it sits in the notification area, shows the worst state across your servers, and sends a notification when a new issue needs you.

- One window per server, with its size and position remembered. You sign in through the server's own login; the window keeps you signed in between launches.
- Tray icon: green when everything is fine, red when something needs you, grey when a server cannot be reached. The menu lists each server with how many things need you (click to open it), pauses notifications for an hour, opens Settings, and quits. Closing a window leaves the app running in the tray.
- Notifications for new things that need you, matching the inbox's Needs you tab. Clicking one opens that issue's page in the server's window.
- Starts at login. Launching it again focuses the running app.
- A certificate that is not publicly trusted (a self-signed one) can be pinned when you add the server. The app shows its SHA-256 fingerprint, in the same `sha256:<hex>` form the machine agent uses, and from then on accepts only that certificate. The poller and the server window (Windows and Linux) both honour the pin.
- Settings, each with its default and a Reset: check every 60 seconds, notifications for new things that need you (or everything, or off), start at login on, and notifications on or off per server.

## Add a server

1. On the server, open Settings, then Keys, and make a user token with the read scope. It starts with `dku_`.
2. In the app's Settings window, enter the server's address, paste the token and choose Add server.

The token is kept in the operating system's keychain. Other settings are a JSON file in the app's config folder. Server addresses must be `https`; plain `http` is accepted only for localhost and local network addresses, and only when you tick the box.

## Build

You need Rust and the Tauri CLI (`cargo install tauri-cli --version "^2" --locked`). On Windows, WebView2 must be installed. On Linux, install `libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev libsecret-1-dev libdbus-1-dev`; the build makes a `.deb`, an `.rpm` and an AppImage.

```
cd apps/desktop/src-tauri
cargo test
cargo tauri build
```

The installers land in `src-tauri/target/release/bundle/`. `icons/make.py` redraws the app and tray icons from `server/priv/static/favicon.svg`; `cargo tauri icon icons/app.png -o src-tauri/icons` rebuilds the bundle icons.

The server windows are plain web content: only the bundled settings page can call the app's commands (see `src-tauri/capabilities/`).

## Linux notes

- Tokens go in the Secret Service (GNOME Keyring, KeePassXC). Without one running, adding a server fails with a message saying so.
- The tray uses AppIndicator, which ignores left-click, so everything is in the tray menu. Some desktops (GNOME) need an AppIndicator extension to show tray icons.
- Notifications use the desktop's notification service; clicking one opens the issue.
- Start at login writes an XDG autostart entry.
