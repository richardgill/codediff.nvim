local M = {}
local WARMUP_COUNT = tonumber(vim.env.CODEDIFF_BENCHMARK_WARMUPS) or 3
local SAMPLE_COUNT = tonumber(vim.env.CODEDIFF_BENCHMARK_SAMPLES) or 20
local NS_PER_MS = 1000000
local PROJECT_ROOT = vim.fn.getcwd()

local median = function(sorted)
  local middle = math.floor(#sorted / 2)
  if #sorted % 2 == 1 then
    return sorted[middle + 1]
  end
  return (sorted[middle] + sorted[middle + 1]) / 2
end

local summarize = function(samples)
  table.sort(samples)
  local deviations = {}
  local sample_median = median(samples)
  for index, sample in ipairs(samples) do
    deviations[index] = math.abs(sample - sample_median)
  end
  table.sort(deviations)
  return {
    median = sample_median,
    p95 = samples[math.ceil(#samples * 0.95)],
    mad = median(deviations),
    min = samples[1],
    max = samples[#samples],
  }
end

local run_once = function(config, case)
  local context
  if case.setup then
    context = case.setup()
  elseif config.setup_case then
    context = config.setup_case(case)
  end
  collectgarbage("collect")
  local memory_before_kb = collectgarbage("count")
  local started_at = vim.uv.hrtime()
  local result
  if case.run then
    result = case.run(context)
  else
    result = config.run(case, context)
  end
  local elapsed = vim.uv.hrtime() - started_at
  local memory_delta_kb = collectgarbage("count") - memory_before_kb
  if case.validate then
    case.validate(result, context)
  else
    config.validate(case, result, context)
  end
  local output_hash = config.hash_result and config.hash_result(case, result, context) or nil
  local sample = {
    elapsed_ms = elapsed / NS_PER_MS,
    lua_memory_delta_kb = memory_delta_kb,
    output_hash = output_hash,
  }
  if config.sample_metadata then
    sample.metadata = config.sample_metadata(case, result, context)
  end
  return sample
end

local benchmark = function(config, case)
  for _ = 1, WARMUP_COUNT do
    run_once(config, case)
  end

  local elapsed_samples = {}
  local memory_samples = {}
  local raw_samples = {}
  local output_hash
  for index = 1, SAMPLE_COUNT do
    local sample = run_once(config, case)
    elapsed_samples[index] = sample.elapsed_ms
    memory_samples[index] = sample.lua_memory_delta_kb
    raw_samples[index] = sample
    output_hash = output_hash or sample.output_hash
    assert(not output_hash or sample.output_hash == output_hash, case.name .. ": output hash changed between samples")
  end

  local stats = summarize(elapsed_samples)
  stats.lua_memory_delta_kb = summarize(memory_samples)
  stats.output_hash = output_hash
  stats.samples = raw_samples
  return stats
end

local get_arguments = function(script)
  local arguments = {}
  local found_script = false
  for _, argument in ipairs(vim.v.argv) do
    if found_script then
      table.insert(arguments, argument)
    elseif argument:sub(-#script) == script then
      found_script = true
    end
  end
  return arguments
end

local select_cases = function(cases, name, suite_name)
  if not name then
    return cases
  end
  for _, case in ipairs(cases) do
    if case.name == name then
      return { case }
    end
  end
  error(string.format("unknown %s benchmark %q", suite_name, name))
end

local write_raw_results = function(config, results)
  local path = vim.env.CODEDIFF_BENCHMARK_RAW_FILE
  if not path then
    return
  end
  local usage = vim.uv.getrusage()
  local revision = vim.fn.systemlist({ "git", "-C", PROJECT_ROOT, "rev-parse", "HEAD" })[1]
  local dirty = #vim.fn.systemlist({ "git", "-C", PROJECT_ROOT, "status", "--porcelain" }) > 0
  local payload = {
    schema_version = 1,
    suite = config.suite_name,
    process_index = tonumber(vim.env.CODEDIFF_BENCHMARK_PROCESS_INDEX),
    plugin_revision = revision,
    plugin_dirty = dirty,
    omp_num_threads = tonumber(vim.env.OMP_NUM_THREADS),
    max_rss_kb = usage.maxrss,
    results = results,
  }
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(payload) }, path)
end

function M.run(config)
  local arguments = get_arguments(config.script)
  if arguments[1] == "--list" then
    for _, case in ipairs(config.cases) do
      print(case.name)
    end
    return
  end
  if #arguments > 1 then
    error(config.usage)
  end

  if config.setup then
    config.setup()
  end

  local quiet = vim.env.CODEDIFF_BENCHMARK_QUIET == "1"
  if not quiet then
    io.stdout:write(string.format("%s (%d warmups, %d samples)\n", config.title, WARMUP_COUNT, SAMPLE_COUNT))
    io.stdout:write(config.description .. "\n")
    io.stdout:write(config.header .. "\n")
  end

  local results = {}
  for _, case in ipairs(select_cases(config.cases, arguments[1], config.suite_name)) do
    local stats = benchmark(config, case)
    results[#results + 1] = {
      name = case.name,
      output_hash = stats.output_hash,
      samples = stats.samples,
    }
    if not quiet then
      config.print_result(case, stats)
    end
  end
  write_raw_results(config, results)
end

M.summarize = summarize

return M
