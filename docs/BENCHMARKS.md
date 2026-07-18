# Local benchmarks

CodeDiff includes warmed `compute_diff()` microbenchmarks, side-by-side rendering benchmarks, and workflow benchmarks for opening a diff, switching files, `gf`, and hunk navigation. They use deterministic generated inputs, exclude fixture setup and validation from timing, and build the native library in Release mode. Each case performs 3 warmups followed by 20 measured samples timed with `vim.uv.hrtime()` and reported in milliseconds.

## Run benchmarks

Run every case:

```bash
./scripts/benchmark.sh
# or
make benchmark
```

List case names, run one suite, or run one case:

```bash
./scripts/benchmark.sh --list
./scripts/benchmark.sh diff
./scripts/benchmark.sh diff sparse-edits
./scripts/benchmark.sh render
./scripts/benchmark.sh render dense-rerender
./scripts/benchmark.sh workflows
./scripts/benchmark.sh workflows open-to-render
```

Rendering timings precompute the diff and measure only clearing and applying side-by-side highlights and filler lines to buffers. They cover both first-render and rerender states, but not terminal or GUI drawing because Neovim runs headlessly.

Workflow timings run inside an already-started headless Neovim. Opening and file switching include Git operations, diff computation, and rendering; they do not include Neovim process startup. Run benchmarks on an otherwise idle machine and compare results from the same machine and configuration.
