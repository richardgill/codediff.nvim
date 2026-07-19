local M = {}

local config = require("codediff.config")
local version = require("codediff.version")

local channel
local next_request_id = 0
local requests = {}
local inflight = {}
local cache = {}
local access_order = {}
local cache_bytes = 0
local cache_generation = 0
local shutting_down = false
local worker_stderr = {}
local module_path = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(module_path, ":h:h:h:h")
local metrics = {
  hits = 0,
  misses = 0,
  deduplicated = 0,
  evictions = 0,
  warm_used = 0,
}

local update_access_order = function(key)
  for index, current in ipairs(access_order) do
    if current == key then
      table.remove(access_order, index)
      return table.insert(access_order, key)
    end
  end
  table.insert(access_order, key)
end

local remove_entry = function(key, evicted)
  local entry = cache[key]
  if not entry then
    return
  end
  cache[key] = nil
  cache_bytes = cache_bytes - entry.bytes
  if evicted then
    metrics.evictions = metrics.evictions + 1
  end
  for index, current in ipairs(access_order) do
    if current == key then
      table.remove(access_order, index)
      return
    end
  end
end

local enforce_budget = function()
  local options = config.options.diff.inline_cache
  while #access_order > options.max_entries or cache_bytes > options.max_bytes do
    remove_entry(access_order[1], true)
  end
end

local put = function(key, value, bytes, warm)
  local options = config.options.diff.inline_cache
  if bytes > options.max_bytes or options.max_entries == 0 then
    return
  end
  remove_entry(key)
  cache[key] = { value = value, bytes = bytes, warm = warm }
  cache_bytes = cache_bytes + bytes
  update_access_order(key)
  enforce_budget()
end

local make_key = function(args)
  local original = table.concat(args.original_lines, "\n")
  local modified = table.concat(args.modified_lines, "\n")
  local options = vim.mpack.encode(args.options or {})
  return table.concat({
    vim.fn.sha256(original),
    vim.fn.sha256(modified),
    args.filetype or "",
    vim.fn.sha256(options),
    version.VERSION,
    vim.fn.sha256(vim.o.runtimepath),
  }, ":")
end

local fail_all = function(err)
  local pending = requests
  requests = {}
  inflight = {}
  for _, request in pairs(pending) do
    for _, callback in ipairs(request.callbacks) do
      callback(nil, err)
    end
  end
end

local start = function()
  if channel and vim.fn.jobwait({ channel }, 0)[1] == -1 then
    return channel
  end
  if shutting_down then
    return nil, "inline worker is shutting down"
  end

  worker_stderr = {}
  channel = vim.fn.jobstart({ vim.v.progpath, "--headless", "--clean", "--embed" }, {
    rpc = true,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if line ~= "" then
          worker_stderr[#worker_stderr + 1] = line
        end
      end
    end,
    on_exit = function(_, code)
      local exited_channel = channel
      channel = nil
      if not shutting_down then
        local details = #worker_stderr > 0 and ": " .. table.concat(worker_stderr, "\n") or ""
        fail_all("inline worker exited with code " .. code .. " (channel " .. tostring(exited_channel) .. ")" .. details)
      end
    end,
  })
  if channel <= 0 then
    local failed_channel = channel
    channel = nil
    return nil, "failed to start inline worker: " .. tostring(failed_channel)
  end

  local ok, err = pcall(
    vim.rpcrequest,
    channel,
    "nvim_exec_lua",
    [[
    local runtimepath = ...
    vim.o.runtimepath = runtimepath
    require("codediff.core.inline_worker_child").setup(1)
    return true
  ]],
    { plugin_root .. "," .. vim.o.runtimepath }
  )
  if not ok then
    vim.fn.jobstop(channel)
    channel = nil
    return nil, tostring(err)
  end
  return channel
end

function M.compute(args)
  assert(type(args.callback) == "function", "inline worker callback is required")

  local key = make_key(args)
  local cached = cache[key]
  if cached then
    metrics.hits = metrics.hits + 1
    if cached.warm and args.kind ~= "warm" then
      cached.warm = false
      metrics.warm_used = metrics.warm_used + 1
    end
    update_access_order(key)
    args.callback(cached.value, nil, true)
    return true
  end

  local active = inflight[key]
  if active then
    metrics.deduplicated = metrics.deduplicated + 1
    if active.warm and args.kind ~= "warm" then
      active.warm = false
      metrics.warm_used = metrics.warm_used + 1
    end
    active.callbacks[#active.callbacks + 1] = args.callback
    return true
  end

  local worker_channel, err = start()
  if not worker_channel then
    return nil, err
  end

  metrics.misses = metrics.misses + 1
  next_request_id = next_request_id + 1
  local request = {
    id = next_request_id,
    key = key,
    callbacks = { args.callback },
    input_bytes = #table.concat(args.original_lines, "\n") + #table.concat(args.modified_lines, "\n"),
    cache_generation = cache_generation,
    warm = args.kind == "warm",
  }
  requests[request.id] = request
  inflight[key] = request

  vim.rpcnotify(worker_channel, "nvim_exec_lua", "return require('codediff.core.inline_worker_child').compute(...)", {
    request.id,
    {
      original_lines = args.original_lines,
      modified_lines = args.modified_lines,
      options = args.options,
      filetype = args.filetype,
    },
  })
  return true
end

function M._complete(request_id, ok, payload)
  local request = requests[request_id]
  if not request then
    return
  end
  requests[request_id] = nil
  inflight[request.key] = nil

  local value
  local err
  if ok then
    local decoded, result = pcall(vim.mpack.decode, payload)
    if decoded then
      value = result
      if request.cache_generation == cache_generation then
        put(request.key, value, request.input_bytes + #payload, request.warm)
      end
    else
      err = tostring(result)
    end
  else
    err = payload
  end

  for _, callback in ipairs(request.callbacks) do
    callback(value, err, false)
  end
end

function M.clear()
  cache_generation = cache_generation + 1
  cache = {}
  access_order = {}
  cache_bytes = 0
end

function M.get_metrics()
  return vim.tbl_extend("force", vim.deepcopy(metrics), {
    entries = #access_order,
    bytes = cache_bytes,
    inflight = vim.tbl_count(inflight),
  })
end

function M.shutdown()
  shutting_down = true
  fail_all("inline worker shut down")
  M.clear()
  if channel then
    pcall(vim.fn.jobstop, channel)
    channel = nil
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("CodeDiffInlineWorkerShutdown", { clear = true }),
  callback = M.shutdown,
})

return M
