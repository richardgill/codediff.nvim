dofile("benchmarks/bootstrap.lua")

local diff = require("codediff.core.diff")
local fixture_data = dofile("benchmarks/fixtures.lua")
local harness = dofile("benchmarks/harness.lua")
local normalize = dofile("benchmarks/normalize.lua")

local validate = function(case, result)
  assert(type(result) == "table", case.name .. ": compute_diff returned no result")
  assert(result.hit_timeout == false, case.name .. ": compute_diff timed out")
  assert(type(result.changes) == "table", case.name .. ": changes are missing")
  assert(type(result.moves) == "table" and #result.moves == 0, case.name .. ": unexpected moves")
  assert(#result.changes == case.expected_changes, string.format("%s: expected %d changes, got %d", case.name, case.expected_changes, #result.changes))
end

local run = function(case)
  return diff.compute_diff(case.original, case.modified, fixture_data.diff_options)
end

local hash_result = function(_, result)
  return normalize.hash_lines_diff(result)
end

local print_result = function(case, stats)
  local line_count = string.format("%d -> %d", #case.original, #case.modified)
  print(
    string.format("%-18s %13s %8d %8.3fms %8.3fms %8.3fms %8.3f .. %8.3fms", case.name, line_count, case.expected_changes, stats.median, stats.p95, stats.mad, stats.min, stats.max)
  )
end

local main = function()
  harness.run({
    script = "benchmarks/diff.lua",
    suite_name = "diff",
    usage = "usage: scripts/benchmark.sh diff [--list | benchmark-name]",
    title = "CodeDiff compute_diff benchmarks",
    description = "Fixtures and validation are outside timed sections. Lower is better.",
    header = string.format("%-18s %13s %8s %10s %10s %10s %19s", "benchmark", "lines", "changes", "median", "p95", "MAD", "min .. max"),
    cases = fixture_data.cases,
    run = run,
    validate = validate,
    hash_result = hash_result,
    print_result = print_result,
  })
end

local ok, err = pcall(main)
if not ok then
  io.stderr:write("Benchmark error: " .. tostring(err) .. "\n")
  os.exit(1)
end
vim.cmd("quit")
