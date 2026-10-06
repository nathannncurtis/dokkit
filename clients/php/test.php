<?php
// Runs the library against a small local server and exits 1 when something is wrong.
//     php test.php
// Served by PHP's own web server, this same file is the server: it writes down what it is sent.
if (PHP_SAPI !== 'cli') {
    file_put_contents(__DIR__ . '/out/got.txt', $_SERVER['REQUEST_URI'] . ' ' . ($_SERVER['HTTP_AUTHORIZATION'] ?? '') . "\n" . file_get_contents('php://input') . "\n", FILE_APPEND);
    echo '{}';
    return;
}

require __DIR__ . '/Dokkit.php';
@mkdir(__DIR__ . '/out');
file_put_contents(__DIR__ . '/out/got.txt', '');
$port = 47913;
$server = proc_open([PHP_BINARY, '-S', "127.0.0.1:$port", __FILE__], [['pipe', 'r'], ['file', __DIR__ . '/out/server.log', 'w'], ['file', __DIR__ . '/out/server.log', 'a']], $pipes);
for ($i = 0; $i < 50 && !@fsockopen('127.0.0.1', $port); $i++) {
    usleep(100000);
}

Dokkit::beat('ignored');
Dokkit::start('2.3.0', "http://127.0.0.1:$port/", 'dka_test');
Dokkit::beat('worker', 30);
Dokkit::check('queue-age', 'degraded', 14, 'oldest item is "14" minutes old');
Dokkit::log('error', 'Upload failed');
function purge(callable $progress): void
{
    $progress(4000, 9000);
    throw new DomainException('patient 4411');
}
try {
    Dokkit::job('nightly-purge', 'purge');
} catch (DomainException) {
}
Dokkit::flush();
proc_terminate($server);

$all = file_get_contents(__DIR__ . '/out/got.txt');
$want = [
    '/api/v1/report Bearer dka_test', '"type":"deploy","version":"2.3.0"', '"every_seconds":30', '"state":"degraded","value":14',
    'oldest item is \"14\" minutes old', '"level":"error","msg":"Upload failed"', '"event":"start"', '"event":"progress","done":4000,"total":9000',
    '"event":"fail","exit_code":1', '/api/v1/errors Bearer dka_test', '"type":"DomainException","handled":false', '"function":"purge","line":28,"own":true}]',
];
$missing = array_filter($want, fn ($w) => !str_contains($all, $w));
// What the library does with its own pieces, and when the server cannot be reached.
$call = fn (string $name, ...$args) => (new ReflectionMethod('Dokkit', $name))->invoke(null, ...$args);
$bad = [];
if (!preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/', $call('uuid'))) {
    $bad[] = 'batch id is not a dashed uuid';
}
if (!preg_match('/\.\d{3}Z$/', $call('now'))) {
    $bad[] = 'times carry no milliseconds';
}
if (!str_contains($call('encode', ['msg' => "bad ± byte"]), '"msg"')) {
    $bad[] = 'a line with invalid UTF-8 vanished';
}
if (str_contains($all, '"type":"deploy"') !== (PHP_SAPI === 'cli')) {
    $bad[] = 'deploy line is for the command line only';
}
$on = new ReflectionProperty('Dokkit', 'on');
$state = $on->getValue();
$on->setValue(null, ['url' => 'http://127.0.0.1:1'] + $state);
Dokkit::beat('a');
Dokkit::beat('b');
$began = microtime(true);
Dokkit::flush();
$retry = (new ReflectionProperty('Dokkit', 'retry'))->getValue();
if (!$retry || count($retry['lines']) !== 2 || microtime(true) - $began > 3) {
    $bad[] = 'a failed batch is not kept for one more try, or the flush did not stop';
}
Dokkit::flush();
if ((new ReflectionProperty('Dokkit', 'retry'))->getValue() !== null || Dokkit::$dropped !== 2) {
    $bad[] = 'a batch that failed twice is not counted as dropped';
}
if (str_contains($all, trim(json_encode(__DIR__), '"'))) {
    $bad[] = 'a stack frame carries an absolute path';
}
if ($bad) {
    echo "FAIL
" . implode("
", $bad) . "
";
    exit(1);
}
if ($missing || str_contains($all, '4411') || str_contains($all, 'ignored')) {
    echo "FAIL\nmissing: " . implode(' | ', $missing) . "\n$all";
    exit(1);
}
echo "ok\n";
