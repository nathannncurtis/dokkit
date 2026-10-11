#!/bin/sh
. "$(dirname "$0")/../../../shell/dokkit.sh"
export DOKKIT_VERSION=9.9.9
dokkit_deploy 9.9.9
dokkit_beat conf-beat 60
dokkit_job conf-job true
dokkit_check conf-check ok 1
dokkit_metric conf.metric 5 n
dokkit_log info "conformance $1"
dokkit_capture ConformanceError x
