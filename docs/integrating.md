# Wiring an app into Docket

Five steps. The first four need no code change in the app.

1. **Declare it.** In the app's repo, run `davit init`. It asks what the app is and writes `docket.toml`. The file format is in `spec/docket-toml.md`.
2. **Check it.** Run `davit check`. It runs every check once on this machine and shows what Docket would receive. No server is involved.
3. **Try it locally.** Run the app with its environment set to `dev`. It shows up in Docket and never alerts.
4. **Ship it.** Commit the file. On deploy, Davit on the machine picks it up from the app's folder, or CI runs `davit apply`.
5. **Add the library only when the app needs to say something about its own insides:** a beat from its main loop, job progress, its own checks, errors. See `spec/library.md`.

## What each step gets you

| The app does | Docket shows |
|---|---|
| Nothing | Up, down, version and resources, watched from outside. |
| Has a `docket.toml` | Its checks, its jobs and their schedules, its log files. |
| Serves the stats document | Traffic, response times and error rates. |
| Wraps a job in `davit run` | Each run's start, finish, exit code, duration and last output. |
| Uses the library | Stuck-but-alive, job progress, its own checks, errors with stack traces. |

## Things that can only make a web request

A cron job on a box with no Davit reports with one line:

```
curl -fsS https://<docket address>/api/v1/in/<app key>/job/nightly-backup/ok
```

## Rules for the file

- No secrets in it. Name the environment variable that holds one.
- The service `id` never changes once it is in use.
- A task in the file is only a proposal until it is accepted in the interface.
