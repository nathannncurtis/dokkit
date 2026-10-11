<?php
require __DIR__ . '/../../../php/Dokkit.php';

class ConformanceError extends Exception {}

$tag = $argv[1];
Dokkit::start('9.9.9');
Dokkit::beat('conf-beat', 60);
Dokkit::job('conf-job', fn () => null);
Dokkit::check('conf-check', 'ok', 1);
Dokkit::metric('conf.metric', 5, 'n');
Dokkit::log('info', 'conformance ' . $tag, ['tag' => $tag, 'n' => 1]);
try {
    throw new ConformanceError('x');
} catch (ConformanceError $e) {
    Dokkit::capture($e);
}
Dokkit::flush();
