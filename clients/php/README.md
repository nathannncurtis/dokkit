# Dokkit for PHP

One file, no packages or extensions, PHP 8.0 or later. `Dokkit::beat`, `job`, `check`, `capture`, `log`.

## Install

Nothing is published to a registry yet. In `composer.json`, point a path repository at a clone of the repo:

```
"repositories": [{ "type": "path", "url": "path/to/dokkit/clients/php" }],
"require": { "dokkit/dokkit": "*" }
```

## Options

`Dokkit::start($version, $url, $key, $announceVersion, $environment)`. With a version, a command-line process announces it once as a deploy line; the server records a deploy only when the version changes. `announceVersion: false` turns that off. An environment other than `production` (this argument or `DOKKIT_ENV`) is put on every line.

Report bodies are gzipped when the zlib extension is loaded and sent plain when it is not. A log line over 64 KB is cut and ends with ` [cut]`. Stack paths are relative to the app folder (the one holding `composer.json`); files outside it carry only their name, or the part after `vendor/`.

## Logging

`new DokkitLogger()` has the PSR-3 logger methods and sends them through `Dokkit::log`. It implements `Psr\Log\LoggerInterface` when `psr/log` is installed, and needs nothing when it is not.

## Test

`php test.php`
