# Updates

A machine is updated without anyone going to it. One elevated command per machine, once, installs **the updater**. After that an update is approved in the interface and the updater does the rest. It installs only a release signed with the project's release key.

The program never replaces its own file, and its service stays an ordinary account. The updater is a separate small piece whose only job is updating.

## A release

The release workflow builds the files, then writes two more:

- `SHA256SUMS`: the first line is `version v1.2.3`, then one line per file, `<sha-256 in lower-case hex><two spaces><file name>`, the way `sha256sum` writes it. Line endings are `\n`.
- `SHA256SUMS.sig`: the Ed25519 signature of the exact bytes of `SHA256SUMS`, in base64, on one line.

The private key is the repository secret `RELEASE_SIGNING_KEY` (PEM, PKCS#8) and exists nowhere else. The public key is 32 bytes, in base64:

```
xX87EOVIFN9AkYL7vMj40ivpQ36bRyvJGLOMIbgAmRk=
```

It is a constant in the program's source. A version is `v` and three numbers. Every built file knows its version: the program prints it with `dokkit version`, and the server's is in its release.

## The server holds releases

An owner, or a token with `admin`, puts a release's files on the server. The server stores them and serves them back; it does not check them, because the updater does.

| Call | Who | What |
|---|---|---|
| `PUT /api/v1/releases/<version>/<file>` | `admin` | The body is the file, as is. Up to 200 MB. Replaces a file of that name. |
| `GET /api/v1/releases` | `read` | The versions held, each with its file names and whether it has both `SHA256SUMS` and `SHA256SUMS.sig`. |
| `DELETE /api/v1/releases/<version>` | `admin` | Removes that version's files. |
| `GET /api/v1/releases/<version>/<file>` | a machine key | The file. |

Files live in a `releases` folder beside the server's settings (`DOKKIT_RELEASES` names another place), one folder per version. A version or file name that is anything but letters, digits, dots, dashes and underscores is refused.

## Approving

Each machine has a wanted version, empty until someone asks. `POST /api/v1/machines/<id>/update` with `{"version": "v1.2.3"}` sets it (`admin`), and only to a version the server holds completely. `POST /api/v1/update-all` with the same body sets it on every machine that has an updater. In the interface these are **Update** on a machine and **Update all**, shown to the owner when the server holds a version newer than the machine reports. The machine's row says what it is on, what it was asked to move to, and the last result.

Nothing updates until someone asks. There is no automatic following of new releases.

## What the updater asks

It uses the program's own address, machine key and certificate pin, from the program's configuration.

`GET /api/v1/update?program=<version>&server=<version>&updater=<version>&os=<os>&arch=<arch>`

- `program` and `updater` are the versions installed. `server` is the server's installed version when this machine runs the server, and is left out otherwise.
- The server remembers these as what the machine is on, and that it has an updater (and whether it hosts the server).
- The answer is `204` when the machine has no wanted version or is already on it. Otherwise `200` with `{"version": "v1.2.3"}`.

`POST /api/v1/update/result` with `{"version": "v1.2.3", "ok": true, "note": "program, updater"}` or `{"version": "v1.2.3", "ok": false, "note": "<what went wrong, at most 2000 characters>"}`. The server keeps the last result for the machine and clears the wanted version when `ok` is true.

## What the updater does with an answer

1. Fetches `SHA256SUMS` and `SHA256SUMS.sig` for that version from `GET /api/v1/releases/<version>/<file>`.
2. Checks the signature with the built-in public key. If it does not check, it stops and reports that.
3. Checks the first line names the version it was told, and that the version is not older than anything installed. It never goes backwards.
4. For each part this machine has, fetches the file for its system, checks its SHA-256 against the list, and installs it:
   - **the server**, on the machine that runs it: `dokkit-windows-x64.zip`. It is unpacked into the updater's own folder and its `install.ps1` is run with no arguments, which upgrades in place. It is done when the server answers again.
   - **the program**: `dokkit-<os>-<arch>` (with `.exe` on Windows). The service is stopped, the file replaced, the service started, and it is done when the service is running. If it does not start, the old file is put back and started.
   - **the updater itself**, last: the same program file, copied over the updater's own copy.
5. Reports the result. A result that cannot be sent, because the server it just restarted is not answering yet, is kept and sent on the next run.

A file it has fetched lives in a folder only administrators and the system account can write. Nothing in it is run before its hash is checked against the signed list.

## On Windows

`dokkit updater install`, from an administrator prompt, once:

- copies the program to `Program Files\DokkitUpdater\dokkit-updater.exe`;
- makes `ProgramData\DokkitUpdater`, for administrators and the system account only, for its state, its log and fetched files;
- registers a scheduled task, **Dokkit updater**, that runs `dokkit-updater.exe updater run` as the system account every five minutes and at start-up. It is not a service and listens on nothing;
- runs it once and prints what it found.

`dokkit updater status` prints the installed versions, the last check and the last result. `dokkit updater run` is what the task runs; from an administrator prompt it does one check now. `dokkit updater uninstall` removes the task and the copied file.

Linux and macOS are not built yet.

## What a takeover can do

- **The server:** it can ask a machine to move to a version, but only a signed release installs, and never an older one.
- **The program's own account:** it cannot write the updater, its folder or its task.
- **The release workflow or its key:** it can sign anything. That is the one place to protect.
