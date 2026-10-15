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
    private const MAX_BYTES = 4000000;
    private const MAX_LINE = 65536;
    private static ?array $on = null;
    private static array $lines = [];
    private static array $errors = [];
    private static int $bytes = 0;
    private static int $retried = 0;
    private static bool $sending = false;
    /** How many lines were dropped because the list was full. */
    public static int $dropped = 0;

    /** Turns the library on. With no address or key it stays off and every call does nothing. */
    public static function start(?string $version = null, ?string $url = null, ?string $key = null, bool $announceVersion = true, ?string $environment = null): void
    {
        $url = $url ?: (getenv('DOKKIT_URL') ?: '');
        $key = $key ?: (getenv('DOKKIT_KEY') ?: '');
        if ($url === '' || $key === '' || self::$on) {
            return;
        }
        if (preg_match('#^http://#i', $url) && !preg_match('#^http://(localhost|127(\.\d+){3}|\[::1\])([:/]|$)#i', $url) && getenv('DOKKIT_INSECURE') !== '1') {
            fwrite(STDERR, "dokkit: http:// address to a non-local host; set DOKKIT_INSECURE=1 to allow it. Staying off.\n");
            return;
        }
        self::$on = [
            'url' => rtrim($url, '/'),
            'key' => $key,
            'version' => $version,
            'environment' => $environment ?: (getenv('DOKKIT_ENV') ?: null),
            'host' => gethostname() ?: 'unknown',
            // The folder the app was started from, or above public/ under a web server: frames under it are the app's own.
            'root' => self::root(),
        ];
        register_shutdown_function(function () {
            if (function_exists('fastcgi_finish_request')) {
                fastcgi_finish_request();
            }
            self::flush();
        });
        if ($version !== null && $announceVersion && PHP_SAPI === 'cli') {
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
        $run = self::uuid();
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
        $root = rtrim(self::$on['root'], '/\\') . DIRECTORY_SEPARATOR;
        $own = fn (?string $file) => $file !== null && self::$on['root'] !== '' && str_starts_with($file, $root) && !str_starts_with($file, $root . 'vendor' . DIRECTORY_SEPARATOR);
        $rel = function (string $file) use ($root): string {
            if (str_starts_with($file, $root)) {
                return substr($file, strlen($root));
            }
            $i = strrpos($file, DIRECTORY_SEPARATOR . 'vendor' . DIRECTORY_SEPARATOR);
            return $i === false ? basename($file) : substr($file, $i + 1);
        };
        // The trace says where each call was made from; the place the error was raised comes first.
        $frames = [['file' => $rel($error->getFile()), 'function' => $error->getTrace()[0]['function'] ?? '(main)', 'line' => $error->getLine(), 'own' => $own($error->getFile())]];
        foreach ($error->getTrace() as $i => $f) {
            $frames[] = ['file' => isset($f['file']) ? $rel($f['file']) : '(internal)', 'function' => $error->getTrace()[$i + 1]['function'] ?? '(main)', 'line' => $f['line'] ?? null, 'own' => $own($f['file'] ?? null)];
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

    /** Sends what is waiting, and stops at the first request that fails. Called for you when the request or script ends. */
    public static function flush(): void
    {
        if (!self::$on) {
            return;
        }
        $pending = self::$errors;
        self::$errors = [];
        $retried = 0;
        foreach ($pending as $i => $error) {
            $result = self::post('/api/v1/errors', self::encode($error), 'application/json', self::uuid());
            if ($result === 'failed') {
                $retried = $i >= self::$retried ? 1 : 0;
                self::$dropped += 1 - $retried;
                self::$errors = array_slice($pending, $i + 1 - $retried);
                break;
            }
            if ($result !== 'ok') {
                self::$dropped++;
            }
        }
        self::$retried = $retried;
        while (self::$lines) {
            $batch = array_splice(self::$lines, 0, 500);
            self::$bytes -= array_sum(array_map('strlen', $batch));
            $id = self::uuid();
            $body = implode("
", $batch);
            // A failed batch gets one more try with the same id; after that it is dropped and counted.
            $result = self::post('/api/v1/report', $body, 'application/x-ndjson', $id);
            if ($result === 'failed') {
                $result = self::post('/api/v1/report', $body, 'application/x-ndjson', $id);
            }
            if ($result !== 'ok') {
                self::$dropped += count($batch);
                if ($result === 'failed') {
                    return;
                }
            }
        }
    }

    private static function root(): string
    {
        $cwd = getcwd() ?: '';
        for ($d = $cwd; ; $d = dirname($d)) {
            if (is_file($d . DIRECTORY_SEPARATOR . 'composer.json')) {
                return $d;
            }
            if (dirname($d) === $d) {
                break;
            }
        }
        return basename($cwd) === 'public' ? dirname($cwd) : $cwd;
    }

    private static function uuid(): string
    {
        $b = random_bytes(16);
        $b[6] = chr(ord($b[6]) & 0x0f | 0x40);
        $b[8] = chr(ord($b[8]) & 0x3f | 0x80);
        return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
    }

    // Text that is not valid UTF-8 is repaired rather than losing the line.
    private static function encode(array $line): string
    {
        return json_encode($line, JSON_INVALID_UTF8_SUBSTITUTE | JSON_PARTIAL_OUTPUT_ON_ERROR) ?: '{}';
    }

    // 'failed' (no answer, 429 or a server error) is tried again; 'refused' (any other 4xx) is dropped. The app is never told.
    private static function post(string $path, string $body, string $kind, string $batch): string
    {
        $headers = ['Authorization: Bearer ' . self::$on['key'], "Content-Type: $kind", "Dokkit-Batch: $batch"];
        if ($path === '/api/v1/report' && function_exists('gzencode')) {
            $body = gzencode($body);
            $headers[] = 'Content-Encoding: gzip';
        }
        $context = stream_context_create(['http' => ['method' => 'POST', 'header' => implode("\r\n", $headers), 'content' => $body, 'timeout' => 2, 'ignore_errors' => true]]);
        // An error handler that logs the warning from a failed send must not feed it back in.
        self::$sending = true;
        try {
            $reply = @file_get_contents(self::$on['url'] . $path, false, $context);
        } finally {
            self::$sending = false;
        }
        $status = (int) substr($http_response_header[0] ?? '', 9, 3);
        if ($reply === false) {
            return 'failed';
        }
        return $status < 400 ? 'ok' : ($status === 429 || $status >= 500 ? 'failed' : 'refused');
    }

    /** Whether the library is on. */
    public static function active(): bool
    {
        return self::$on !== null;
    }

    private static function add(array $line): void
    {
        if (!self::$on || self::$sending) {
            return;
        }
        $text = self::fit(array_filter($line + ['at' => self::now(), 'host' => self::$on['host']], fn ($v) => $v !== null) + (self::$on['environment'] !== null && self::$on['environment'] !== 'production' ? ['environment' => self::$on['environment']] : []));
        if ($text === null) {
            self::$dropped++;
            return;
        }
        while (self::$lines && (count(self::$lines) >= self::QUEUE || self::$bytes + strlen($text) > self::MAX_BYTES)) {
            self::$bytes -= strlen(array_shift(self::$lines));
            self::$dropped++;
        }
        self::$lines[] = $text;
        self::$bytes += strlen($text);
    }

    // A line over the size limit has its message cut, then its fields dropped; one that still does not fit is dropped.
    private static function fit(array $line): ?string
    {
        $text = self::encode($line);
        if (strlen($text) <= self::MAX_LINE || !is_string($line['msg'] ?? null)) {
            return strlen($text) <= self::MAX_LINE ? $text : null;
        }
        $msg = $line['msg'];
        foreach ([true, false] as $keepFields) {
            if (!$keepFields) {
                unset($line['fields']);
            }
            for ($k = strlen($msg);;) {
                $head = substr($msg, 0, $k);
                while ($head !== '' && !preg_match('//u', $head)) {
                    $head = substr($head, 0, -1);
                }
                $line['msg'] = $head . ' [cut]';
                $text = self::encode($line);
                $over = strlen($text) - self::MAX_LINE;
                if ($over <= 0) {
                    return $text;
                }
                if ($k === 0) {
                    break;
                }
                $k = max(0, $k - $over);
            }
        }
        return null;
    }

    private static function now(): string
    {
        $t = microtime(true);
        return gmdate('Y-m-d\TH:i:s', (int) $t) . sprintf('.%03dZ', (int) (fmod($t, 1) * 1000));
    }
}

// A PSR-3 logger that sends through Dokkit::log. It has PSR-3's methods without needing psr/log,
// and implements Psr\Log\LoggerInterface when that package is loaded.
//     $logger = new DokkitLogger();
class DokkitLoggerMethods
{
    private const LEVELS = ['emergency' => 'fatal', 'alert' => 'fatal', 'critical' => 'fatal', 'error' => 'error', 'warning' => 'warn', 'notice' => 'info', 'info' => 'info', 'debug' => 'debug'];

    public function emergency($message, array $context = []): void { $this->log('emergency', $message, $context); }
    public function alert($message, array $context = []): void { $this->log('alert', $message, $context); }
    public function critical($message, array $context = []): void { $this->log('critical', $message, $context); }
    public function error($message, array $context = []): void { $this->log('error', $message, $context); }
    public function warning($message, array $context = []): void { $this->log('warning', $message, $context); }
    public function notice($message, array $context = []): void { $this->log('notice', $message, $context); }
    public function info($message, array $context = []): void { $this->log('info', $message, $context); }
    public function debug($message, array $context = []): void { $this->log('debug', $message, $context); }

    public function log($level, $message, array $context = []): void
    {
        try {
            if (!Dokkit::active()) {
                return;
            }
            $text = (string) $message;
            foreach ($context as $key => $value) {
                if (is_scalar($value) || $value === null || $value instanceof Stringable) {
                    $text = str_replace('{' . $key . '}', (string) $value, $text);
                }
            }
            Dokkit::log(self::LEVELS[$level] ?? 'info', $text);
        } catch (Throwable) {
        }
    }
}

if (interface_exists('Psr\Log\LoggerInterface')) {
    class DokkitLogger extends DokkitLoggerMethods implements Psr\Log\LoggerInterface
    {
    }
} else {
    class DokkitLogger extends DokkitLoggerMethods
    {
    }
}
