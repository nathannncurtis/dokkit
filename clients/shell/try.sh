# What the test runs against its local server.
cd "$(dirname "$0")" || exit 1
DOKKIT_URL="" . ./dokkit.sh
DOKKIT_URL="" dokkit_beat ignored
export DOKKIT_URL="http://127.0.0.1:$1/" DOKKIT_KEY=dka_test
dokkit_beat worker 30
dokkit_check queue-age degraded 14 'oldest item is "14" minutes \ old'
dokkit_metric queue.depth 7
dokkit_log error "Upload failed"
dokkit_job nightly-purge sh -c 'exit 3'
echo "code=$?"
