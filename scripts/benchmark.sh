#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release --target vscode_diff

run_suite() {
    local suite="$1"
    shift
    VSCODE_DIFF_NO_AUTO_INSTALL=1 nvim --headless --clean -u NONE -l "benchmarks/$suite.lua" "$@" 2>&1 | grep -Ev '^Hunk [0-9]+ of [0-9]+$'
}

if [ $# -eq 0 ]; then
    run_suite diff
    run_suite workflows
elif [ "$1" = "--list" ]; then
    run_suite diff --list
    run_suite workflows --list
elif [ "$1" = "diff" ] || [ "$1" = "workflows" ]; then
    run_suite "$@"
else
    printf 'Usage: %s [--list | diff [benchmark] | workflows [benchmark]]\n' "$0" >&2
    exit 1
fi
