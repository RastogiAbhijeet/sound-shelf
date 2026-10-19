#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/diagnostics .build/clang-cache
swiftc -module-cache-path .build/clang-cache scripts/diagnose-call-audio.swift -o .build/diagnostics/diagnose-call-audio
printf 'Built .build/diagnostics/diagnose-call-audio\n'
