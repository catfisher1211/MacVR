#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
swiftc -O Sources/Encoder.swift Tests/EncoderQueueTest.swift -o "$D/encoder-test"
"$D/encoder-test"
swiftc -O Sources/TrackingCadence.swift Tests/TrackingCadenceTest.swift -o "$D/cadence-test"
"$D/cadence-test"
