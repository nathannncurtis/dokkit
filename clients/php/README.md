# Dokkit for PHP

One file, no packages or extensions, PHP 8.0 or later. `Dokkit::beat`, `job`, `check`, `capture`, `log`.

## Install

Nothing is published to a registry yet. In `composer.json`, point a path repository at a clone of the repo:

```
"repositories": [{ "type": "path", "url": "path/to/dokkit/clients/php" }],
"require": { "dokkit/dokkit": "*" }
```

## Logging

`new DokkitLogger()` has the PSR-3 logger methods and sends them through `Dokkit::log`. It implements `Psr\Log\LoggerInterface` when `psr/log` is installed, and needs nothing when it is not.

## Test

`php test.php`
