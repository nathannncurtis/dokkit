<?php
// Runs the library against a small local server and exits 1 when something is wrong.
//     php test.php
// Served by PHP's own web server, this same file is the server: it writes down what it is sent.
if (PHP_SAPI !== 'cli') {
    file_put_contents(__DIR__ . '/out/got.txt', $_SERVER['REQUEST_URI'] . ' ' . ($_SERVER['HTTP_AUTHORIZATION'] ?? '') . ' batch=' . ($_SERVER['HTTP_DOKKIT_BATCH'] ?? '') . "\n" . file_get_contents('php://input') . "\n", FILE_APPEND);
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
if (!preg_match('/^\/api\/v1\/report .* batch=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/m', $all)) {
    $missing[] = 'dashed Dokkit-Batch';
}
if ($missing || str_contains($all, '4411') || str_contains($all, 'ignored')) {
    echo "FAIL\nmissing: " . implode(' | ', $missing) . "\n$all";
    exit(1);
}
echo "ok\n";
