local M = {}
local WARMUP_COUNT = 3
local SAMPLE_COUNT = 20
local NS_PER_MS = 1000000

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
  local started_at = vim.uv.hrtime()
  local result
  if case.run then
    result = case.run(context)
  else
    result = config.run(case, context)
  end
  local elapsed = vim.uv.hrtime() - started_at
  if case.validate then
    case.validate(result, context)
  else
    config.validate(case, result, context)
  end
  return elapsed / NS_PER_MS
end

local benchmark = function(config, case)
  for _ = 1, WARMUP_COUNT do
    run_once(config, case)
  end

  local samples = {}
  for index = 1, SAMPLE_COUNT do
    samples[index] = run_once(config, case)
  end
  return summarize(samples)
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

  print(string.format("%s (%d warmups, %d samples)", config.title, WARMUP_COUNT, SAMPLE_COUNT))
  print(config.description)
  print(config.header)

  for _, case in ipairs(select_cases(config.cases, arguments[1], config.suite_name)) do
    config.print_result(case, benchmark(config, case))
  end
end

return M
