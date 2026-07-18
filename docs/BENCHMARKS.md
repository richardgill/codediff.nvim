# Local benchmarks

CodeDiff includes deterministic `compute_diff()`, rendering, timeout-responsiveness, and workflow benchmarks. Fixture generation, setup, validation, output hashing, and process startup are outside timed regions. The native library is built in Release mode and benchmark processes use `OMP_NUM_THREADS=1`.

Each selected case runs 3 warmups and 20 measured samples in each of 3 fresh Neovim processes. Reports include median, p95, MAD, Lua memory delta, process maximum RSS, and normalized output hashes where output parity applies.

## Run benchmarks

Run every suite:

```bash
./scripts/benchmark.sh
# or
make benchmark
```

List cases, run one suite, or run one case:

```bash
./scripts/benchmark.sh --list
./scripts/benchmark.sh diff sparse-100-blocks
./scripts/benchmark.sh render dense-rerender
./scripts/benchmark.sh timeout timeout-full-rewrite
./scripts/benchmark.sh workflows open-to-render
```

`CODEDIFF_BENCHMARK_PROCESS_RUNS`, `CODEDIFF_BENCHMARK_WARMUPS`, and `CODEDIFF_BENCHMARK_SAMPLES` can shorten exploratory runs. Use the defaults for comparisons.

## Results

Each invocation prints its output locations. By default they are created under:

```text
build/benchmarks/<timestamp>-<pid>/raw/*.json
build/benchmarks/<timestamp>-<pid>/results.json
build/benchmarks/<timestamp>-<pid>/report.md
```

The raw files contain every sample from each process. `results.json` and `report.md` aggregate all processes. Compare normalized hashes before comparing timing across revisions.

Pinned real-world fixtures use CodeDiff files at fixed Git commits, so fixture content is stable across checked-out revisions. Rendering timings measure clearing and applying side-by-side highlights and filler lines, not terminal or GUI drawing. Workflow timings run inside an already-started headless Neovim and do not include Neovim startup.
