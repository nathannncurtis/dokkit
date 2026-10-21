# Contributing

Thanks for your interest in contributing.

## Getting Started

1. Fork the repository
2. Create a branch for your change
3. Make your changes
4. Test your changes locally
5. Open a pull request

## Pull Requests

- Keep PRs focused on a single change
- Write a clear description of what you changed and why
- Reference any related issues
- Make sure existing functionality isn't broken
- Write commit messages and descriptions in plain words, with no employer names or hosts

## What runs on a pull request

`.github/workflows/ci.yml` runs one job per area that the change touches, and a single `ci-ok` job that passes only when all of them did. A pull request has to be green on `ci-ok`.

- `rules`: names and workflow rules (`.github/scripts/rules.sh`) and gitleaks over the commits.
- `server`: compile with warnings as errors, format check, tests against Postgres, retired and vulnerable packages, and Sobelow.
- `program`: gofmt, tests on Linux, Windows and macOS, and known vulnerabilities in reachable code.
- `clients` and `clients-swift`: each library's tests, the shared conformance cases and the server log check.
- `apps-ios`, `apps-android` and `apps-desktop`: checks and an unsigned build of each app; the desktop app on Windows, macOS and Linux.
- `site`, `zap-site` and `zap-server`: the site checks, and a ZAP scan of the site and of the server running on the sample company. A High finding fails.
- `deps-owasp`: OSV-Scanner and Dependency-Check.

`codeql.yml` scans the languages a change touches, and all of them weekly. Dependabot opens one grouped version-bump PR per ecosystem each month.

## Reporting Bugs

Open an issue with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- Your environment (OS, language version, etc.)

## Questions

Open an issue. There are no bad questions.
