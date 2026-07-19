local M = {}

local uv = vim.uv or vim.loop
local mpack = vim.mpack
local requests = {}
local owner_requests = {}
local next_request_id = 0
local shutting_down = false
local metrics = {
  worker_queued = 0,
  coalesced = 0,
}

-- uv.new_work serializes this function into an isolated Lua state, so worker helpers cannot use module upvalues.
local async_worker = function(request_id, library_path, ffi_definitions, payload)
  local ffi
  local loaded_lib
  local c_diff

  local line_range_to_lua = function(range)
    return { start_line = range.start_line, end_line = range.end_line }
  end

  local char_range_to_lua = function(range)
    return {
      start_line = range.start_line,
      start_col = range.start_col,
      end_line = range.end_line,
      end_col = range.end_col,
    }
  end

  local detailed_mapping_to_lua = function(mapping)
    local inner_changes = {}
    for index = 0, mapping.inner_change_count - 1 do
      local inner = mapping.inner_changes[index]
      inner_changes[#inner_changes + 1] = {
        original = char_range_to_lua(inner.original),
        modified = char_range_to_lua(inner.modified),
      }
    end
    local line_mappings = {}
    for index = 0, mapping.line_mapping_count - 1 do
      local line_mapping = mapping.line_mappings[index]
      line_mappings[#line_mappings + 1] = {
        original = line_range_to_lua(line_mapping.original),
        modified = line_range_to_lua(line_mapping.modified),
      }
    end
    return {
      original = line_range_to_lua(mapping.original),
      modified = line_range_to_lua(mapping.modified),
      inner_changes = inner_changes,
      line_mappings = line_mappings,
    }
  end

  local lines_diff_to_lua = function(diff)
    local result = { changes = {}, moves = {}, hit_timeout = diff.hit_timeout }
    for index = 0, diff.changes.count - 1 do
      result.changes[#result.changes + 1] = detailed_mapping_to_lua(diff.changes.mappings[index])
    end
    for index = 0, diff.moves.count - 1 do
      local move = diff.moves.moves[index]
      result.moves[#result.moves + 1] = {
        original = line_range_to_lua(move.original),
        modified = line_range_to_lua(move.modified),
      }
    end
    return result
  end

  local traceback = function(err)
    return debug.traceback(tostring(err), 2)
  end

  local ok, result = xpcall(function()
    ffi = require("ffi")
    if not pcall(ffi.typeof, "CodeDiffLinesDiff") then
      ffi.cdef(ffi_definitions)
    end
    loaded_lib = ffi.load(library_path)

    local args = vim.mpack.decode(payload)
    local original_lines = args.original_lines
    local modified_lines = args.modified_lines
    local options = args.options
    local c_original = ffi.new("const char*[?]", #original_lines)
    local c_modified = ffi.new("const char*[?]", #modified_lines)
    for index, line in ipairs(original_lines) do
      c_original[index - 1] = line
    end
    for index, line in ipairs(modified_lines) do
      c_modified[index - 1] = line
    end

    local c_options = ffi.new("CodeDiffDiffOptions")
    c_options.ignore_trim_whitespace = options.ignore_trim_whitespace
    c_options.max_computation_time_ms = options.max_computation_time_ms
    c_options.compute_moves = options.compute_moves
    c_options.extend_to_subwords = options.extend_to_subwords
    c_options.line_matcher_strategy = options.line_matcher_strategy
    c_options.line_matcher_threshold = options.line_matcher_threshold

    c_diff = loaded_lib.compute_diff(c_original, #original_lines, c_modified, #modified_lines, c_options)
    assert(c_diff ~= nil, "compute_diff returned NULL")
    return vim.mpack.encode(lines_diff_to_lua(c_diff))
  end, traceback)

  if c_diff ~= nil then
    loaded_lib.free_lines_diff(c_diff)
  end
  return request_id, ok and result or "", ok and "" or tostring(result)
end

local work_context

local fail_request = function(request, err)
  requests[request.id] = nil
  if request.owner ~= nil then
    owner_requests[request.owner] = nil
  end
  return nil, tostring(err)
end

local start_request = function(request)
  local encoded, payload = pcall(mpack.encode, request.payload)
  if not encoded then
    return fail_request(request, payload)
  end
  local queued, err = work_context:queue(request.id, request.library_path, request.ffi_definitions, payload)
  if not queued then
    return fail_request(request, err)
  end
  if request.owner ~= nil then
    owner_requests[request.owner] = { active = request.id }
  end
  metrics.worker_queued = metrics.worker_queued + 1
  return true
end

local finish_request = function(request_id, encoded_result, worker_error)
  local request = requests[request_id]
  if not request then
    return
  end
  requests[request_id] = nil

  local pending
  if request.owner ~= nil then
    local owner_state = owner_requests[request.owner]
    if owner_state and owner_state.active == request_id then
      pending = owner_state.pending and requests[owner_state.pending] or nil
      owner_requests[request.owner] = nil
    end
  end
  if pending then
    local started, start_error = start_request(pending)
    if not started then
      pending.callback(nil, start_error)
    end
  end
  if not request.callback then
    return
  end
  if worker_error ~= "" then
    request.callback(nil, worker_error)
    return
  end

  local ok, result = pcall(mpack.decode, encoded_result)
  if ok then
    request.callback(result, nil)
  else
    request.callback(nil, tostring(result))
  end
end

local complete_request = function(request_id, encoded_result, worker_error)
  vim.schedule(function()
    finish_request(request_id, encoded_result, worker_error)
  end)
end

work_context = uv.new_work(async_worker, complete_request)

function M.compute(args)
  if shutting_down then
    return nil, "async diff worker is shutting down"
  end
  assert(type(args.callback) == "function", "async diff callback is required")

  next_request_id = next_request_id + 1
  local request = {
    id = next_request_id,
    callback = args.callback,
    owner = args.owner,
    payload = {
      original_lines = args.original_lines,
      modified_lines = args.modified_lines,
      options = args.options,
    },
    library_path = args.library_path,
    ffi_definitions = args.ffi_definitions,
  }
  requests[request.id] = request

  local owner_state = request.owner ~= nil and owner_requests[request.owner] or nil
  if owner_state then
    local active = assert(requests[owner_state.active], "active async diff request is missing")
    -- new_work:queue() exposes no uv_work_t to cancel, so superseded work must finish and its result is discarded.
    active.callback = nil
    if owner_state.pending then
      requests[owner_state.pending] = nil
    end
    owner_state.pending = request.id
    metrics.coalesced = metrics.coalesced + 1
    return true
  end

  local started, err = start_request(request)
  if not started then
    return nil, err
  end
  return true
end

function M.get_metrics()
  return vim.deepcopy(metrics)
end

function M.reset_metrics()
  metrics = {
    worker_queued = 0,
    coalesced = 0,
  }
end

function M.shutdown()
  shutting_down = true
  requests = {}
  owner_requests = {}
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("CodeDiffAsyncDiffShutdown", { clear = true }),
  callback = M.shutdown,
})

return M
