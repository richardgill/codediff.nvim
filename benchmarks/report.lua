local harness = dofile("benchmarks/harness.lua")

local get_result_dir = function()
  local found_script = false
  for _, argument in ipairs(vim.v.argv) do
    if found_script then
      return argument
    end
    if argument:sub(-#"benchmarks/report.lua") == "benchmarks/report.lua" then
      found_script = true
    end
  end
  error("usage: nvim -l benchmarks/report.lua <result-directory>")
end

local read_json = function(path)
  local lines = vim.fn.readfile(path)
  return vim.json.decode(table.concat(lines, "\n"))
end

local sorted_keys = function(values)
  local keys = {}
  for key in pairs(values) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

local aggregate = function(raw_files)
  local groups = {}
  for _, path in ipairs(raw_files) do
    local payload = read_json(path)
    for _, result in ipairs(payload.results) do
      local key = payload.suite .. "/" .. result.name
      local group = groups[key]
        or {
          suite = payload.suite,
          name = result.name,
          elapsed = {},
          memory = {},
          hashes = {},
          max_rss_kb = 0,
          process_count = 0,
          hit_timeout_count = 0,
          timeout_observation_count = 0,
        }
      group.process_count = group.process_count + 1
      group.max_rss_kb = math.max(group.max_rss_kb, payload.max_rss_kb or 0)
      if result.output_hash then
        group.hashes[result.output_hash] = true
      end
      for _, sample in ipairs(result.samples) do
        group.elapsed[#group.elapsed + 1] = sample.elapsed_ms
        group.memory[#group.memory + 1] = sample.lua_memory_delta_kb
        if sample.metadata and sample.metadata.hit_timeout ~= nil then
          group.timeout_observation_count = group.timeout_observation_count + 1
          if sample.metadata.hit_timeout then
            group.hit_timeout_count = group.hit_timeout_count + 1
          end
        end
      end
      groups[key] = group
    end
  end

  local results = {}
  for _, key in ipairs(sorted_keys(groups)) do
    local group = groups[key]
    local hashes = sorted_keys(group.hashes)
    assert(#hashes <= 1, string.format("%s: output hashes differ between processes", key))
    local elapsed_stats = harness.summarize(group.elapsed)
    local memory_stats = harness.summarize(group.memory)
    results[#results + 1] = {
      suite = group.suite,
      name = group.name,
      process_count = group.process_count,
      sample_count = #group.elapsed,
      median_ms = elapsed_stats.median,
      p95_ms = elapsed_stats.p95,
      mad_ms = elapsed_stats.mad,
      lua_memory_delta_kb = memory_stats.median,
      process_max_rss_kb = group.max_rss_kb,
      output_hash = hashes[1],
      hit_timeout_count = group.hit_timeout_count,
      timeout_observation_count = group.timeout_observation_count,
    }
  end
  return results
end

local markdown = function(results, raw_count, generated_at)
  local lines = {
    "# CodeDiff benchmark report",
    "",
    string.format("Generated: %s", generated_at),
    string.format("Raw process results: %d", raw_count),
    "",
    "| Suite | Benchmark | Median | p95 | MAD | Lua delta | Output hash |",
    "|---|---|---:|---:|---:|---:|---|",
  }
  for _, result in ipairs(results) do
    local hash = result.output_hash and result.output_hash:sub(1, 12) or "-"
    lines[#lines + 1] = string.format(
      "| %s | %s | %.3f ms | %.3f ms | %.3f ms | %.1f KiB | `%s` |",
      result.suite,
      result.name,
      result.median_ms,
      result.p95_ms,
      result.mad_ms,
      result.lua_memory_delta_kb,
      hash
    )
  end

  local suite_rss = {}
  for _, result in ipairs(results) do
    suite_rss[result.suite] = math.max(suite_rss[result.suite] or 0, result.process_max_rss_kb)
  end
  vim.list_extend(lines, { "", "## Process maximum RSS", "", "| Suite | Max RSS |", "|---|---:|" })
  for _, suite in ipairs(sorted_keys(suite_rss)) do
    lines[#lines + 1] = string.format("| %s | %.1f MiB |", suite, suite_rss[suite] / 1024)
  end

  local timeout_results = {}
  for _, result in ipairs(results) do
    if result.timeout_observation_count > 0 then
      timeout_results[#timeout_results + 1] = result
    end
  end
  if #timeout_results > 0 then
    vim.list_extend(lines, { "", "## Timeout responses", "", "| Benchmark | Hit timeout |", "|---|---:|" })
    for _, result in ipairs(timeout_results) do
      lines[#lines + 1] = string.format("| %s | %d / %d |", result.name, result.hit_timeout_count, result.timeout_observation_count)
    end
  end
  return lines
end

local main = function()
  local result_dir = get_result_dir()
  local raw_files = vim.fn.globpath(result_dir .. "/raw", "*.json", false, true)
  table.sort(raw_files)
  assert(#raw_files > 0, "no raw benchmark results found")

  local results = aggregate(raw_files)
  local generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local report_lines = markdown(results, #raw_files, generated_at)
  vim.fn.writefile({ vim.json.encode({ schema_version = 1, generated_at = generated_at, raw_files = raw_files, results = results }) }, result_dir .. "/results.json")
  vim.fn.writefile(report_lines, result_dir .. "/report.md")
  print(table.concat(report_lines, "\n"))
  print("")
  print("Raw results: " .. result_dir .. "/raw")
  print("Machine report: " .. result_dir .. "/results.json")
  print("Markdown report: " .. result_dir .. "/report.md")
end

local ok, err = pcall(main)
if not ok then
  io.stderr:write("Benchmark report error: " .. tostring(err) .. "\n")
  os.exit(1)
end
vim.cmd("quit")
