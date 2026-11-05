# Wiring an app into Dokkit

Five steps. The first four need no code change in the app.

1. **Declare it.** In the app's repo, run `dokkit init`. It asks what the app is and writes `dokkit.toml`. The file format is in `dokkit-toml.md`. An app that runs as many processes of a program shared with other apps (`python.exe`) is told apart by a `process` check with `command_has`, a piece of the executable path on Windows or of the command line elsewhere.
2. **Check it.** Run `dokkit check`. It runs every check once on this machine and shows what Dokkit would receive. No server is involved.
3. **Try it locally.** Run the app with its environment set to `dev`. While the service has no `dokkit.toml` declaration, it shows up in Dokkit as its own service, next to the production one, and never alerts; a declared service keeps the environment its file gives it. An app that only uses a library does this with `DOKKIT_ENV=dev`.
4. **Ship it.** Commit the file. On deploy, `dokkit` on the machine picks it up from the app's folder, or CI runs `dokkit apply` with the app's key (`DOKKIT_URL` and `DOKKIT_KEY`), which may declare that app only, with `beat` and `custom` checks and jobs.
5. **Add the library only when the app needs to say something about its own insides:** a beat from its main loop, job progress, its own checks, errors.

## What each step gets you

| The app does | Dokkit shows |
|---|---|
| Nothing | Up, down, version and resources, watched from outside. |
| Has a `dokkit.toml` | Its checks, its jobs and their schedules, its log files. |
| Serves the stats document | Traffic, response times and error rates. |
| Wraps a job in `dokkit run` | Each run's start, finish, exit code, duration and last output. |
| Uses the library | Stuck-but-alive, job progress, its own checks, errors with stack traces. |

## Things that can only make a web request

A cron job on a box with no `dokkit` reports with one line:

```
curl -fsS https://<dokkit address>/api/v1/in/<app key>/job/nightly-backup/ok
```

## Rules for the file

- No secrets in it. Name the environment variable that holds one.
- The service `id` never changes once it is in use.

## GitHub security alerts by email

`POST /hooks/github` takes GitHub webhook deliveries (content type `application/json`) for `dependabot_alert` and `code_scanning_alert`, and answers `ping`. The `X-Hub-Signature-256` header is checked against `github_secret` before the body is read; a missing or wrong signature is a 401. A new or reopened alert that is critical, or high with a CVE on CISA's known exploited list (fetched at most twice a day), is mailed once. Every other delivery is a 202 with no mail. Each alert (repository, number, kind) is mailed only once, however often it is delivered, so a separate job can forward missed alerts to the same address with the same signature.

These are alert settings (`PUT /api/v1/alerts`, or `set_alert_settings`), next to the mail server settings the alerts already use (`smtp_host`, `smtp_port`, `smtp_user`, `smtp_password`, `mail_from`):

| Setting | Meaning |
|---|---|
| `github_secret` | The webhook secret. Required; without it every delivery is refused. |
| `github_org` | Organisations to accept, with commas between. Empty accepts any repository. |
| `github_mail_to` | Who is mailed, with commas between. Empty uses `email_to`. |
