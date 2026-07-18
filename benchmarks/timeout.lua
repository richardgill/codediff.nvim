dofile("benchmarks/bootstrap.lua")

local diff = require("codediff.core.diff")
local fixture_data = dofile("benchmarks/fixtures.lua")
local harness = dofile("benchmarks/harness.lua")
local timeout_options = vim.deepcopy(fixture_data.diff_options)
timeout_options.max_computation_time_ms = 25

local make_unrelated_lines = function(side)
  local lines = {}
  local character = side == "original" and "a" or "Z"
  for index = 1, 200 do
    lines[index] = string.format("%s-%04d-%s", side, index, string.rep(character, 96))
  end
  return lines
end

local make_repetitive_lines = function(changed)
  local lines = {}
  local suffix = changed and " changed" or ""
  for index = 1, 200 do
    lines[index] = "local value = repeated_pattern + shared" .. suffix
  end
  return lines
end

local cases = {
  {
    name = "timeout-full-rewrite",
    original = fixture_data.by_name["full-rewrite"].original,
    modified = fixture_data.by_name["full-rewrite"].modified,
  },
  {
    name = "timeout-unrelated-200",
    original = make_unrelated_lines("original"),
    modified = make_unrelated_lines("modified"),
  },
  {
    name = "timeout-repetitive-200",
    original = make_repetitive_lines(false),
    modified = make_repetitive_lines(true),
  },
}

local run = function(case)
  return diff.compute_diff(case.original, case.modified, timeout_options)
end

local validate = function(case, result)
  assert(type(result) == "table", case.name .. ": compute_diff returned no result")
  assert(type(result.hit_timeout) == "boolean", case.name .. ": timeout status is missing")
  assert(type(result.changes) == "table", case.name .. ": changes are missing")
end

local sample_metadata = function(_, result)
  return { hit_timeout = result.hit_timeout }
end

local print_result = function(case, stats)
  local line_count = string.format("%d -> %d", #case.original, #case.modified)
  print(
    string.format(
      "%-24s %13s %8.3fms %8.3fms %8.3fms %8.1fKiB %8.3f .. %8.3fms",
      case.name,
      line_count,
      stats.median,
      stats.p95,
      stats.mad,
      stats.lua_memory_delta_kb.median,
      stats.min,
      stats.max
    )
  )
end

local main = function()
  harness.run({
    script = "benchmarks/timeout.lua",
    suite_name = "timeout",
    usage = "usage: scripts/benchmark.sh timeout [--list | benchmark-name]",
    title = "CodeDiff short-timeout responsiveness benchmarks",
    description = "Each computation has a 25ms algorithm timeout. Lower is better.",
    header = string.format("%-24s %13s %10s %10s %10s %10s %19s", "benchmark", "lines", "median", "p95", "MAD", "Lua delta", "min .. max"),
    cases = cases,
    run = run,
    validate = validate,
    sample_metadata = sample_metadata,
    print_result = print_result,
  })
end

local ok, err = pcall(main)
if not ok then
  io.stderr:write("Timeout benchmark error: " .. tostring(err) .. "\n")
  os.exit(1)
end
vim.cmd("quit")
