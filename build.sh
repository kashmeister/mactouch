#!/bin/bash
# Compile bin/touchbridge and sign it ad hoc.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -o bin/touchbridge touchbridge.swift
# An identifier-based designated requirement (instead of the default per-build cdhash) keeps the
# Input Monitoring and Accessibility grants valid across rebuilds.
codesign --force --sign - --identifier local.touchbridge \
    --requirements '=designated => identifier "local.touchbridge"' bin/touchbridge
echo "built bin/touchbridge"
