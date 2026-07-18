-- FFI wrapper for compute_diff C library
-- Provides LinesDiff data structure from C to Lua

local M = {}
local ffi = require("ffi")

-- Get VERSION from version.lua (single source of truth)
local version = require("codediff.version")
local VERSION = version.VERSION

-- Load the C library with automatic installation
local lib_ext
if ffi.os == "Windows" then
  lib_ext = "dll"
elseif ffi.os == "OSX" then
  lib_ext = "dylib"
else
  lib_ext = "so"
end

-- Build versioned library filename
local path_util = require("codediff.core.path")
local plugin_root = path_util.get_plugin_root()
local lib_name = string.format("libvscode_diff_%s.%s", VERSION, lib_ext)
local lib_path = plugin_root .. "/" .. lib_name

-- Check if library exists or needs update, if so, install/update it
-- Skip auto-installation if explicitly disabled (e.g., in tests where library is already built)
local installer = require("codediff.core.installer")
if not vim.env.VSCODE_DIFF_NO_AUTO_INSTALL and installer.needs_update() then
  local success, err = installer.install({ silent = false })
  if not success then
    error(
      string.format(
        "libvscode-diff not found and automatic installation failed: %s\n"
          .. "Troubleshooting:\n"
          .. "1. Check that curl or wget is installed\n"
          .. "2. Verify internet connectivity to github.com\n"
          .. "3. Try manual install: :CodeDiff install!\n"
          .. "4. Or build from source: run 'make' (Unix) or 'build.cmd' (Windows)\n"
          .. "5. Download manually from: https://github.com/esmuellert/vscode-diff.nvim/releases",
        err or "unknown error"
      )
    )
  end
end

-- Try to load the library - fall back to unversioned name for local builds
local lib
local load_ok, load_err = pcall(function()
  lib = ffi.load(lib_path)
end)

if not load_ok then
  -- Try fallback to unversioned library (for local builds and tests)
  local fallback_lib_name = "libvscode_diff." .. lib_ext
  local fallback_path = plugin_root .. "/" .. fallback_lib_name
  if vim.fn.filereadable(fallback_path) == 1 then
    lib = ffi.load(fallback_path)
  else
    error(load_err)
  end
end

-- FFI type definitions matching C types.h
ffi.cdef([[
  // Basic range types
  typedef struct {
    int seq1_start;
    int seq1_end;
    int seq2_start;
    int seq2_end;
  } SequenceDiff;

  typedef struct {
    SequenceDiff* diffs;
    int count;
    int capacity;
  } SequenceDiffArray;

  typedef struct {
    int start_line;  // 1-based, inclusive
    int end_line;    // 1-based, EXCLUSIVE
  } LineRange;

  typedef struct {
    int start_line;  // 1-based
    int start_col;   // 1-based, inclusive
    int end_line;    // 1-based
    int end_col;     // 1-based, EXCLUSIVE
  } CharRange;

  // Mapping types
  typedef struct {
    CharRange original;
    CharRange modified;
  } RangeMapping;

  typedef struct {
    RangeMapping* mappings;
    int count;
    int capacity;
  } RangeMappingArray;

  typedef struct {
    RangeMappingArray* results;
    int count;
  } RangeMappingBatch;

  typedef struct {
    bool consider_whitespace_changes;
    bool extend_to_subwords;
    int timeout_ms;
  } CharLevelOptions;

  typedef struct {
    LineRange original;
    LineRange modified;
    RangeMapping* inner_changes;
    int inner_change_count;
  } DetailedLineRangeMapping;

  typedef struct {
    DetailedLineRangeMapping* mappings;
    int count;
    int capacity;
  } DetailedLineRangeMappingArray;

  typedef struct {
    LineRange original;
    LineRange modified;
  } MovedText;

  typedef struct {
    MovedText* moves;
    int count;
    int capacity;
  } MovedTextArray;

  // Main diff result
  typedef struct {
    DetailedLineRangeMappingArray changes;
    MovedTextArray moves;
    bool hit_timeout;
  } LinesDiff;

  // Options
  typedef struct {
    bool ignore_trim_whitespace;
    int max_computation_time_ms;
    bool compute_moves;
    bool extend_to_subwords;
  } DiffOptions;

  // API functions
  LinesDiff* compute_diff(
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count,
    const DiffOptions* options
  );

  SequenceDiffArray* compute_line_alignments(
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count,
    int timeout_ms,
    bool* hit_timeout
  );

  RangeMappingBatch* refine_diffs_char_level(
    const SequenceDiffArray* line_diffs,
    const char** original_lines,
    int original_count,
    const char** modified_lines,
    int modified_count,
    const CharLevelOptions* options,
    bool* hit_timeout
  );

  void free_lines_diff(LinesDiff* diff);
  void free_range_mapping_batch(RangeMappingBatch* batch);
  void free_sequence_diff_array(SequenceDiffArray* diff);
  const char* get_version(void);
]])

---@class DiffOptions
---@field ignore_trim_whitespace boolean
---@field max_computation_time_ms integer
---@field compute_moves boolean
---@field extend_to_subwords boolean

-- Convert Lua string array to C string array
local function lua_to_c_strings(lines)
  local count = #lines
  local c_array = ffi.new("const char*[?]", count)

  for i = 1, count do
    c_array[i - 1] = lines[i]
  end

  return c_array, count
end

-- Convert C CharRange to Lua table
local function char_range_to_lua(c_range)
  return {
    start_line = c_range.start_line,
    start_col = c_range.start_col,
    end_line = c_range.end_line,
    end_col = c_range.end_col,
  }
end

-- Convert C LineRange to Lua table
local function line_range_to_lua(c_range)
  return {
    start_line = c_range.start_line,
    end_line = c_range.end_line,
  }
end

-- Convert C RangeMapping to Lua table
local function range_mapping_to_lua(c_mapping)
  return {
    original = char_range_to_lua(c_mapping.original),
    modified = char_range_to_lua(c_mapping.modified),
  }
end

-- Convert C DetailedLineRangeMapping to Lua table
local function detailed_mapping_to_lua(c_mapping)
  local inner_changes = {}

  if c_mapping.inner_changes ~= nil then
    for i = 0, c_mapping.inner_change_count - 1 do
      table.insert(inner_changes, range_mapping_to_lua(c_mapping.inner_changes[i]))
    end
  end

  return {
    original = line_range_to_lua(c_mapping.original),
    modified = line_range_to_lua(c_mapping.modified),
    inner_changes = inner_changes,
  }
end

-- Convert C MovedText to Lua table
local function moved_text_to_lua(c_moved)
  return {
    original = line_range_to_lua(c_moved.original),
    modified = line_range_to_lua(c_moved.modified),
  }
end

-- Convert C LinesDiff to Lua table
local function lines_diff_to_lua(c_diff)
  if c_diff == nil then
    return nil
  end

  local changes = {}
  for i = 0, c_diff.changes.count - 1 do
    table.insert(changes, detailed_mapping_to_lua(c_diff.changes.mappings[i]))
  end

  local moves = {}
  for i = 0, c_diff.moves.count - 1 do
    table.insert(moves, moved_text_to_lua(c_diff.moves.moves[i]))
  end

  return {
    changes = changes,
    moves = moves,
    hit_timeout = c_diff.hit_timeout,
  }
end

local function compute_native_diff(original_lines, modified_lines, options)
  -- Convert Lua lines to C arrays
  local c_orig, orig_count = lua_to_c_strings(original_lines)
  local c_mod, mod_count = lua_to_c_strings(modified_lines)

  -- Create options struct
  ---@type DiffOptions
  ---@diagnostic disable-next-line: assign-type-mismatch
  local c_options = ffi.new("DiffOptions")
  c_options.ignore_trim_whitespace = options.ignore_trim_whitespace or false
  c_options.max_computation_time_ms = options.max_computation_time_ms or 5000
  c_options.compute_moves = options.compute_moves or false
  c_options.extend_to_subwords = options.extend_to_subwords or false

  -- Call C function
  local c_diff = lib.compute_diff(c_orig, orig_count, c_mod, mod_count, c_options)
  if c_diff == nil then
    error("compute_diff returned NULL")
  end

  -- Convert to Lua table
  local lua_diff = lines_diff_to_lua(c_diff)

  -- Free C memory
  lib.free_lines_diff(c_diff)
  return lua_diff
end

local function append_change(changes, original_start, original_end, modified_start, modified_end)
  local line_block = {
    original = { start_line = original_start, end_line = original_end },
    modified = { start_line = modified_start, end_line = modified_end },
  }
  local previous = changes[#changes]
  if previous and previous.original.end_line >= original_start and previous.modified.end_line >= modified_start then
    previous.original.end_line = math.max(previous.original.end_line, original_end)
    previous.modified.end_line = math.max(previous.modified.end_line, modified_end)
    previous.line_blocks[#previous.line_blocks + 1] = line_block
    return
  end

  changes[#changes + 1] = {
    original = { start_line = original_start, end_line = original_end },
    modified = { start_line = modified_start, end_line = modified_end },
    inner_changes = {},
    line_mappings = {},
    line_blocks = { line_block },
  }
end

local function append_whitespace_changes(changes, original_lines, modified_lines, starts, count)
  for offset = 0, count - 1 do
    local original_index = starts.original + offset
    local modified_index = starts.modified + offset
    if original_lines[original_index] ~= modified_lines[modified_index] then
      append_change(changes, original_index, original_index + 1, modified_index, modified_index + 1)
    end
  end
end

local function compute_line_changes(original_lines, modified_lines, options)
  local c_orig, orig_count = lua_to_c_strings(original_lines)
  local c_mod, mod_count = lua_to_c_strings(modified_lines)
  local hit_timeout = ffi.new("bool[1]")
  local c_diffs = lib.compute_line_alignments(c_orig, orig_count, c_mod, mod_count, options.max_computation_time_ms or 5000, hit_timeout)
  if c_diffs == nil then
    error("compute_line_alignments returned NULL")
  end

  local changes = {}
  local previous_original = 0
  local previous_modified = 0

  for index = 0, c_diffs.count - 1 do
    local line_diff = c_diffs.diffs[index]
    if not options.ignore_trim_whitespace then
      append_whitespace_changes(changes, original_lines, modified_lines, {
        original = previous_original + 1,
        modified = previous_modified + 1,
      }, line_diff.seq1_start - previous_original)
    end

    append_change(changes, line_diff.seq1_start + 1, line_diff.seq1_end + 1, line_diff.seq2_start + 1, line_diff.seq2_end + 1)
    previous_original = line_diff.seq1_end
    previous_modified = line_diff.seq2_end
  end

  if not options.ignore_trim_whitespace then
    append_whitespace_changes(changes, original_lines, modified_lines, {
      original = previous_original + 1,
      modified = previous_modified + 1,
    }, math.min(orig_count - previous_original, mod_count - previous_modified))
  end

  lib.free_sequence_diff_array(c_diffs)
  return changes, hit_timeout[0]
end

local function slice_lines(lines, start_index, end_index)
  local result = {}
  for index = start_index, end_index - 1 do
    result[#result + 1] = lines[index]
  end
  return result
end

local function validate_line_range(range, line_count, label)
  if type(range) ~= "table" then
    error(label .. " must be a table")
  end
  if type(range.start_index) ~= "number" or range.start_index % 1 ~= 0 then
    error(label .. ".start_index must be an integer")
  end
  if type(range.end_index) ~= "number" or range.end_index % 1 ~= 0 then
    error(label .. ".end_index must be an integer")
  end
  if range.start_index < 1 or range.end_index < range.start_index or range.end_index > line_count + 1 then
    error(label .. " is out of bounds")
  end
end

-- Validate that matcher output contains ordered, non-overlapping ranges within the changed block.
local function validate_line_mappings(mappings, context)
  if type(mappings) ~= "table" then
    error("line matcher must return a table")
  end

  local previous
  for index, mapping in ipairs(mappings) do
    local label = "line mapping " .. index
    if type(mapping) ~= "table" then
      error(label .. " must be a table")
    end
    validate_line_range(mapping.original, #context.original_lines, label .. ".original")
    validate_line_range(mapping.modified, #context.modified_lines, label .. ".modified")

    local original_empty = mapping.original.start_index == mapping.original.end_index
    local modified_empty = mapping.modified.start_index == mapping.modified.end_index
    if original_empty and modified_empty then
      error(label .. " cannot be empty on both sides")
    end
    if previous and (mapping.original.start_index < previous.original.end_index or mapping.modified.start_index < previous.modified.end_index) then
      error("line mappings must be ordered and non-overlapping")
    end
    previous = mapping
  end
end

local function absolute_line_range(range, start_line)
  return {
    start_line = start_line + range.start_index - 1,
    end_line = start_line + range.end_index - 1,
  }
end

local function collect_line_mappings(change, line_block, original_lines, modified_lines, matcher, selected)
  local context = {
    original_lines = slice_lines(original_lines, line_block.original.start_line, line_block.original.end_line),
    modified_lines = slice_lines(modified_lines, line_block.modified.start_line, line_block.modified.end_line),
    original_start_line = line_block.original.start_line,
    modified_start_line = line_block.modified.start_line,
  }
  local mappings = matcher(context)
  validate_line_mappings(mappings, context)

  for _, mapping in ipairs(mappings) do
    local refined_mapping = {
      original = absolute_line_range(mapping.original, line_block.original.start_line),
      modified = absolute_line_range(mapping.modified, line_block.modified.start_line),
      inner_changes = {},
    }
    change.line_mappings[#change.line_mappings + 1] = refined_mapping
    selected[#selected + 1] = { change = change, mapping = refined_mapping }
  end
end

local function refine_line_mappings(selected, original_lines, modified_lines, options)
  if #selected == 0 then
    return false
  end

  local c_orig, orig_count = lua_to_c_strings(original_lines)
  local c_mod, mod_count = lua_to_c_strings(modified_lines)
  local c_mappings = ffi.new("SequenceDiff[?]", #selected)
  for index, selected_mapping in ipairs(selected) do
    c_mappings[index - 1].seq1_start = selected_mapping.mapping.original.start_line - 1
    c_mappings[index - 1].seq1_end = selected_mapping.mapping.original.end_line - 1
    c_mappings[index - 1].seq2_start = selected_mapping.mapping.modified.start_line - 1
    c_mappings[index - 1].seq2_end = selected_mapping.mapping.modified.end_line - 1
  end
  local c_mapping_array = ffi.new("SequenceDiffArray", { diffs = c_mappings, count = #selected, capacity = #selected })
  local c_options = ffi.new("CharLevelOptions", {
    consider_whitespace_changes = not options.ignore_trim_whitespace,
    extend_to_subwords = options.extend_to_subwords or false,
    timeout_ms = options.max_computation_time_ms or 5000,
  })
  local hit_timeout = ffi.new("bool[1]")
  local batch = lib.refine_diffs_char_level(c_mapping_array, c_orig, orig_count, c_mod, mod_count, c_options, hit_timeout)
  if batch == nil then
    error("refine_diffs_char_level returned NULL")
  end
  if batch.count ~= #selected then
    lib.free_range_mapping_batch(batch)
    error("refine_diffs_char_level returned an unexpected result count")
  end

  for index, selected_mapping in ipairs(selected) do
    local result = batch.results[index - 1]
    for mapping_index = 0, result.count - 1 do
      selected_mapping.mapping.inner_changes[#selected_mapping.mapping.inner_changes + 1] = range_mapping_to_lua(result.mappings[mapping_index])
    end
    vim.list_extend(selected_mapping.change.inner_changes, selected_mapping.mapping.inner_changes)
  end
  lib.free_range_mapping_batch(batch)
  return hit_timeout[0]
end

-- Main API: Compute diff between two sets of lines
-- Returns Lua table representation of LinesDiff
function M.compute_diff(original_lines, modified_lines, options)
  options = options or {}
  local changes, hit_timeout = compute_line_changes(original_lines, modified_lines, options)
  local matcher = options.line_matcher
  if matcher == nil then
    matcher = require("codediff.config").options.diff.line_matcher
  end

  local selected = {}
  for _, change in ipairs(changes) do
    for _, line_block in ipairs(change.line_blocks) do
      collect_line_mappings(change, line_block, original_lines, modified_lines, matcher, selected)
    end
    change.line_blocks = nil
  end
  hit_timeout = refine_line_mappings(selected, original_lines, modified_lines, options) or hit_timeout

  local moves = {}
  if options.compute_moves then
    local move_diff = compute_native_diff(original_lines, modified_lines, options)
    moves = move_diff.moves
    hit_timeout = hit_timeout or move_diff.hit_timeout
  end

  return {
    changes = changes,
    moves = moves,
    hit_timeout = hit_timeout,
  }
end

M._compute_native_diff = compute_native_diff

-- Get library version
function M.get_version()
  return ffi.string(lib.get_version())
end

return M
