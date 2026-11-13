#!/bin/sh
set -eu
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'farpilot 9.8.7'
    exit 0
fi
printf '%s\n' 'fixture invoked'
