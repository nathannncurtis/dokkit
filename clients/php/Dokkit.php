<?php
// The Dokkit client library for PHP. One file, no packages or extensions. PHP 8.0 or later.
//
//     require 'Dokkit.php';
//     Dokkit::start('2.3.0');                 // reads DOKKIT_URL and DOKKIT_KEY; blank means off
//     Dokkit::beat('worker');                 // from the main loop of a worker
//     Dokkit::job('nightly-purge', function ($progress) { $progress(4000, 9000); });
//     Dokkit::check('queue-age', 'degraded', 14, 'oldest item is 14 minutes old');
//     Dokkit::capture($exception);
//
// Nothing here throws into the app. Lines wait in a list of fixed size and are sent when the
// request or script ends, after the response has gone out where PHP allows it. A long-running
// worker calls Dokkit::flush() from its loop. Error message text is never sent.

final class Dokkit
{
    private const QUEUE = 1000;
    private static ?array $on = null;
    private static array $lines = [];
    private static array $errors = [];
    /** How many lines were dropped because the list was full. */
    public static int $dropped = 0;

    /** Turns the library on. With no address or key it stays off and every call does nothing. */
    public static function start(?string $version = null, ?string $url = null, ?string $key = null): void
    {
        $url = $url ?: (getenv('DOKKIT_URL') ?: '');
        $key = $key ?: (getenv('DOKKIT_KEY') ?: '');
        if ($url === '' || $key === '' || self::$on) {
            return;
        }
        self::$on = [
            'url' => rtrim($url, '/'),
            'key' => $key,
            'version' => $version,
            'environment' => getenv('DOKKIT_ENV') ?: null,
            'host' => gethostname() ?: 'unknown',
            // The folder the app was started from: frames under it are the app's own.
            'root' => getcwd() ?: '',
        ];
        register_shutdown_function(function () {
            if (function_exists('fastcgi_finish_request')) {
                fastcgi_finish_request();
            }
            self::flush();
        });
        if ($version !== null) {
            self::add(['type' => 'deploy', 'version' => $version]);
        }
    }

    public static function beat(string $name, int $everySeconds = 60): void
    {
        self::add(['type' => 'beat', 'name' => $name, 'every_seconds' => $everySeconds]);
    }

    /** $state is "ok", "degraded" or "down". */
    public static function check(string $name, string $state, int|float|null $value = null, ?string $note = null): void
    {
        self::add(['type' => 'custom', 'check' => $name, 'state' => $state, 'value' => $value, 'note' => $note]);
    }

    public static function metric(string $name, int|float $value, ?string $unit = null): void
    {
        self::add(['type' => 'metric', 'name' => $name, 'value' => $value, 'unit' => $unit]);
    }

    /** $level is trace, debug, info, warn, error or fatal. */
    public static function log(string $level, string $message, ?array $fields = null): void
    {
        self::add(['type' => 'log', 't' => self::now(), 'level' => $level, 'msg' => $message, 'fields' => $fields]);
    }

    /** Sends a stats document, for an app dokkit cannot reach. */
    public static function stats(array $document): void
    {
        self::add(['type' => 'stats', 'document' => $document]);
    }

    /** Reports a run of a job: its start, its progress, and how it ended. Returns what the work returns. */
    public static function job(string $name, callable $work): mixed
    {
        $run = bin2hex(random_bytes(16));
        $began = hrtime(true);
        $send = fn (string $event, array $more = []) => self::add(['type' => 'job', 'name' => $name, 'run' => $run, 'event' => $event] + $more);
        $took = fn () => intdiv(hrtime(true) - $began, 1000000);
        $send('start');
        try {
            $result = $work(fn (int $done, ?int $total = null) => $send('progress', ['done' => $done, 'total' => $total]));
            $send('ok', ['exit_code' => 0, 'duration_ms' => $took()]);
            return $result;
        } catch (Throwable $error) {
            $send('fail', ['exit_code' => 1, 'duration_ms' => $took()]);
            self::capture($error, false);
            throw $error;
        }
    }

    /** Sends an error: its type and stack, never its message. */
    public static function capture(Throwable $error, bool $handled = true, array $tags = []): void
    {
        if (!self::$on || count(self::$errors) >= 100) {
            return;
        }
        $own = fn (?string $file) => $file !== null && str_starts_with($file, self::$on['root']) && !str_contains($file, 'vendor');
        // The trace says where each call was made from; the place the error was raised comes first.
        $frames = [['file' => $error->getFile(), 'function' => $error->getTrace()[0]['function'] ?? '(main)', 'line' => $error->getLine(), 'own' => $own($error->getFile())]];
        foreach ($error->getTrace() as $i => $f) {
            $frames[] = ['file' => $f['file'] ?? '(internal)', 'function' => $error->getTrace()[$i + 1]['function'] ?? '(main)', 'line' => $f['line'] ?? null, 'own' => $own($f['file'] ?? null)];
        }
        self::$errors[] = [
            'at' => self::now(),
            'type' => get_class($error),
            'handled' => $handled,
            'release' => self::$on['version'],
            'environment' => self::$on['environment'],
            'host' => self::$on['host'],
            // Innermost last, as the format asks.
            'frames' => array_reverse($frames),
            'tags' => (object) array_map('strval', $tags),
        ];
    }

    /** Also reports errors nothing caught, then hands them to whatever handled them before. */
    public static function catchUnhandled(): void
    {
        $before = set_exception_handler(function (Throwable $error) use (&$before) {
            self::capture($error, false);
            if ($before) {
                $before($error);
            } else {
                throw $error;
            }
        });
    }

    /** Sends what is waiting. Called for you when the request or script ends. */
    public static function flush(): void
    {
        if (!self::$on) {
            return;
        }
        [$errors, $lines] = [self::$errors, self::$lines];
        [self::$errors, self::$lines] = [[], []];
        foreach ($errors as $error) {
            self::post('/api/v1/errors', json_encode($error), 'application/json');
        }
        foreach (array_chunk($lines, 500) as $batch) {
            self::post('/api/v1/report', implode("\n", array_map('json_encode', $batch)), 'application/x-ndjson');
        }
    }

    // What cannot be sent is dropped. The app is never told.
    private static function post(string $path, string $body, string $kind): void
    {
        $headers = ['Authorization: Bearer ' . self::$on['key'], "Content-Type: $kind", 'Dokkit-Batch: ' . bin2hex(random_bytes(16))];
        $context = stream_context_create(['http' => ['method' => 'POST', 'header' => implode("\r\n", $headers), 'content' => $body, 'timeout' => 5, 'ignore_errors' => true]]);
        @file_get_contents(self::$on['url'] . $path, false, $context);
    }

    private static function add(array $line): void
    {
        if (!self::$on) {
            return;
        }
        if (count(self::$lines) >= self::QUEUE) {
            array_shift(self::$lines);
            self::$dropped++;
        }
        self::$lines[] = array_filter($line + ['at' => self::now(), 'host' => self::$on['host']], fn ($v) => $v !== null);
    }

    private static function now(): string
    {
        return gmdate('Y-m-d\TH:i:s\Z');
    }
}
