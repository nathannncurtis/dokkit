#!/bin/sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
dest="$here/app/src/test/resources/fixtures"
mkdir -p "$dest"
cp "$here/../../spec/phone-cases/sealing.json" "$here/../../spec/phone-cases/snapshot.json" "$dest/"
