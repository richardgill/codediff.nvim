#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROCESS_RUNS="${CODEDIFF_BENCHMARK_PROCESS_RUNS:-3}"
RESULT_DIR="${CODEDIFF_BENCHMARK_OUTPUT_DIR:-$PROJECT_ROOT/build/benchmarks/$(date -u +%Y%m%dT%H%M%SZ)-$$}"

cd "$PROJECT_ROOT"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release --target vscode_diff

run_suite_process() {
    local suite="$1"
    local process_index="$2"
    shift 2
    local raw_file="$RESULT_DIR/raw/$suite-$process_index.json"
    CODEDIFF_BENCHMARK_PROCESS_INDEX="$process_index" \
    CODEDIFF_BENCHMARK_RAW_FILE="$raw_file" \
    CODEDIFF_BENCHMARK_QUIET=1 \
    OMP_NUM_THREADS=1 \
        nvim --headless --clean -u NONE -l "benchmarks/$suite.lua" "$@" 2>&1 | sed -E '/^Hunk [0-9]+ of [0-9]+$/d'
}

run_suite() {
    local suite="$1"
    shift
    for ((process_index = 1; process_index <= PROCESS_RUNS; process_index++)); do
        run_suite_process "$suite" "$process_index" "$@"
    done
}

list_suite() {
    local suite="$1"
    OMP_NUM_THREADS=1 nvim --headless --clean -u NONE -l "benchmarks/$suite.lua" --list
}

all_suites=(diff render workflows timeout)

if [ "${1:-}" = "--list" ]; then
    for suite in "${all_suites[@]}"; do
        list_suite "$suite"
    done
    exit 0
fi

if [ $# -eq 0 ]; then
    for suite in "${all_suites[@]}"; do
        run_suite "$suite"
    done
elif [ "$1" = "diff" ] || [ "$1" = "render" ] || [ "$1" = "workflows" ] || [ "$1" = "timeout" ]; then
    suite="$1"
    shift
    run_suite "$suite" "$@"
else
    printf 'Usage: %s [--list | diff | render | workflows | timeout] [benchmark]\n' "$0" >&2
    exit 1
fi

nvim --headless --clean -u NONE -l benchmarks/report.lua "$RESULT_DIR"
