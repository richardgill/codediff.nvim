-- Inline diff rendering: single-buffer view with virtual line overlays
-- Shows modified buffer with deleted lines as virt_lines extmarks
local M = {}

local config = require("codediff.config")
local highlights = require("codediff.ui.highlights")
local char_ranges = require("codediff.ui.char_ranges")

-- Dedicated namespace for inline diff (separate from side-by-side namespaces)
M.ns_inline = vim.api.nvim_create_namespace("codediff-inline")

-- Allow deleted-line virt_lines to scroll horizontally with the window
local virt_lines_overflow = vim.fn.has("nvim-0.11") == 1 and "scroll" or nil

-- Cache for merged highlight groups (syntax fg + diff bg)
local merged_hl_cache = {}

-- ============================================================================
-- Syntax highlighting for virt_lines via treesitter
-- ============================================================================

-- Get or create a merged highlight group combining syntax fg with diff bg
-- @param syntax_hl string: treesitter highlight group (e.g., "@keyword")
-- @param diff_hl string: diff background group ("CodeDiffLineDelete" or "CodeDiffCharDelete")
-- @return string: merged highlight group name
local function get_merged_hl(syntax_hl, diff_hl)
  local key = syntax_hl .. "+" .. diff_hl
  if merged_hl_cache[key] then
    return merged_hl_cache[key]
  end

  -- Resolve the actual highlight values
  local syntax_def = vim.api.nvim_get_hl(0, { name = syntax_hl, link = false })
  local diff_def = vim.api.nvim_get_hl(0, { name = diff_hl, link = false })

  if not syntax_def.fg and not syntax_def.bold and not syntax_def.italic then
    -- Syntax group has no useful styling, just use diff highlight
    merged_hl_cache[key] = diff_hl
    return diff_hl
  end

  -- Create merged group: syntax fg/style + diff bg
  local merged_name = "CodeDiffInline_" .. syntax_hl:gsub("[%.@]", "_") .. "_" .. diff_hl
  local merged_def = {
    bg = diff_def.bg,
    fg = syntax_def.fg,
    bold = syntax_def.bold,
    italic = syntax_def.italic,
    underline = syntax_def.underline,
    strikethrough = syntax_def.strikethrough,
  }
  vim.api.nvim_set_hl(0, merged_name, merged_def)
  merged_hl_cache[key] = merged_name
  return merged_name
end

-- Compute treesitter syntax highlights for a set of lines
-- @param lines string[]: source lines
-- @param filetype string: language for treesitter parser
-- @return table: { [1-based-line] = { {start_col, end_col, hl_group}, ... } }
function M.compute_syntax_highlights(lines, filetype)
  if not filetype or filetype == "" or #lines == 0 then
    return {}
  end

  local source = table.concat(lines, "\n")

  -- Try to get a parser for this filetype
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, filetype)
  if not ok or not parser then
    return {}
  end

  local ok2, trees = pcall(parser.parse, parser)
  if not ok2 or not trees or #trees == 0 then
    return {}
  end

  local query_ok, query = pcall(vim.treesitter.query.get, filetype, "highlights")
  if not query_ok or not query then
    return {}
  end

  local result = {}

  for id, node in query:iter_captures(trees[1]:root(), source) do
    local r1, c1, r2, c2 = node:range()
    local hl_group = "@" .. query.captures[id]

    -- Handle single-line captures
    if r1 == r2 then
      local line_num = r1 + 1 -- 1-based
      if not result[line_num] then
        result[line_num] = {}
      end
      table.insert(result[line_num], { start_col = c1 + 1, end_col = c2, hl_group = hl_group })
    else
      -- Multi-line capture: split across lines
      for row = r1, r2 do
        local line_num = row + 1
        local line_text = lines[line_num] or ""
        if not result[line_num] then
          result[line_num] = {}
        end

        local sc = (row == r1) and (c1 + 1) or 1
        local ec = (row == r2) and c2 or #line_text
        if ec >= sc then
          table.insert(result[line_num], { start_col = sc, end_col = ec, hl_group = hl_group })
        end
      end
    end
  end

  -- Sort each line's highlights by start_col
  for _, line_hls in pairs(result) do
    table.sort(line_hls, function(a, b)
      return a.start_col < b.start_col
    end)
  end

  return result
end

-- ============================================================================
-- Build virtual line chunks with character-level highlights
-- ============================================================================

-- Build a single virt_line entry with char-level diff highlighting and syntax colors
-- line_text: the original (deleted) line text
-- char_ranges: sorted list of {start_col, end_col} (1-based, byte positions)
-- syntax_hls: sorted list of {start_col, end_col, hl_group} for this line (optional)
-- Returns: array of {text, hl_group} chunks suitable for virt_lines
local function build_highlighted_virt_line(line_text, char_ranges, syntax_hls, base_hl)
  base_hl = base_hl or "CodeDiffLineDelete"
  -- Build position-to-syntax-hl map for quick lookup
  local syntax_at = {}
  if syntax_hls then
    for _, sh in ipairs(syntax_hls) do
      for col = sh.start_col, sh.end_col do
        syntax_at[col] = sh.hl_group
      end
    end
  end

  -- Determine diff highlight for each byte position
  -- nil = CodeDiffLineDelete, otherwise the text-level diff highlight
  local diff_hl_at = {}
  if char_ranges then
    for _, range in ipairs(char_ranges) do
      for col = range.start_col, range.end_col do
        diff_hl_at[col] = range.hl_group
      end
    end
  end

  -- Build chunks by walking through the line, grouping consecutive positions
  -- with the same effective highlight
  if #line_text == 0 then
    return {
      { "", base_hl },
      { string.rep(" ", 300), base_hl },
    }
  end

  local chunks = {}
  local chunk_start = 1
  local prev_hl = nil

  local function get_hl_at(col)
    local diff_hl = diff_hl_at[col] or base_hl
    local syn_hl = syntax_at[col]
    if syn_hl then
      return get_merged_hl(syn_hl, diff_hl)
    end
    return diff_hl
  end

  prev_hl = get_hl_at(1)

  for col = 2, #line_text + 1 do
    local cur_hl = col <= #line_text and get_hl_at(col) or nil
    if cur_hl ~= prev_hl then
      table.insert(chunks, { line_text:sub(chunk_start, col - 1), prev_hl })
      chunk_start = col
      prev_hl = cur_hl
    end
  end

  -- Last chunk
  if chunk_start <= #line_text then
    table.insert(chunks, { line_text:sub(chunk_start), prev_hl })
  end

  -- Pad for full-width background color (simulates hl_eol for virt_lines)
  table.insert(chunks, { string.rep(" ", 300), base_hl })

  return chunks
end

-- ============================================================================
-- Extract char-level ranges for a specific original line from inner_changes
-- ============================================================================

-- Given inner_changes and a 1-based original line number, extract byte-position
-- ranges on that line that have character-level deletions.
-- Returns: sorted list of {start_col, end_col} in byte positions
local function get_char_ranges_for_orig_line(inner_changes, orig_line_1based, original_lines, modified_lines)
  local ranges = {}

  for _, inner in ipairs(inner_changes or {}) do
    for _, segment in ipairs(char_ranges.to_line_segments(inner.original, inner.modified, original_lines, modified_lines)) do
      if segment.line == orig_line_1based then
        table.insert(ranges, {
          start_col = segment.start_col + 1,
          end_col = segment.end_col,
          hl_group = segment.line_text and "CodeDiffLineDeleteText" or "CodeDiffCharDelete",
        })
      end
    end
  end

  table.sort(ranges, function(a, b)
    return a.start_col < b.start_col
  end)

  return #ranges > 0 and ranges or nil
end

-- ============================================================================
-- Apply char-level highlights on modified buffer lines
-- ============================================================================

local function apply_modified_char_highlights(bufnr, inner_changes, original_lines, modified_lines)
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for _, inner in ipairs(inner_changes or {}) do
    for _, segment in ipairs(char_ranges.to_line_segments(inner.modified, inner.original, modified_lines, original_lines)) do
      if segment.line <= line_count then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_inline, segment.line - 1, segment.start_col, {
          end_col = segment.end_col,
          hl_group = segment.line_text and "CodeDiffLineInsertText" or "CodeDiffCharInsert",
          priority = 200,
        })
      end
    end
  end
end

-- ============================================================================
-- Main Rendering Function
-- ============================================================================

-- Render inline diff on a single buffer (the modified buffer)
-- Deleted lines appear as virtual lines above the corresponding modified position
-- Added/changed lines get highlight extmarks on the real buffer text
--
-- @param bufnr number: The modified buffer to render on
-- @param diff_result table: The diff result from core/diff.compute_diff
-- @param original_lines string[]: Lines from the original (reference) content
-- @param modified_lines string[]: Lines from the modified buffer
-- @param opts? table: { filetype?: string } for syntax highlighting on virt_lines
function M.render_inline_diff(bufnr, diff_result, original_lines, modified_lines, opts)
  -- Clear previous inline decorations
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns_inline, 0, -1)
  -- Clear merged highlight cache on re-render (colorscheme may have changed)
  merged_hl_cache = {}

  if not diff_result or not diff_result.changes then
    return
  end

  -- Compute syntax highlights for original lines (for virt_line coloring)
  local filetype = opts and opts.filetype or (vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype or nil)
  local syntax_hls = M.compute_syntax_highlights(original_lines, filetype)

  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  local highlight_priority = config.options.diff.highlight_priority

  for _, mapping in ipairs(diff_result.changes) do
    local orig_start = mapping.original.start_line
    local orig_end = mapping.original.end_line
    local mod_start = mapping.modified.start_line
    local mod_end = mapping.modified.end_line

    local orig_count = orig_end - orig_start
    local mod_count = mod_end - mod_start
    local has_original = orig_count > 0
    local has_modified = mod_count > 0

    -- Step 1: Show deleted/original lines as virtual lines
    if has_original then
      local virt_lines = {}

      for orig_line = orig_start, orig_end - 1 do
        local line_text = original_lines[orig_line] or ""
        local char_ranges = get_char_ranges_for_orig_line(mapping.inner_changes, orig_line, original_lines, modified_lines)
        local line_syntax = syntax_hls[orig_line]
        local chunks = build_highlighted_virt_line(line_text, char_ranges, line_syntax)
        table.insert(virt_lines, chunks)
      end

      -- Anchor: place virtual lines above mod_start (or at end if pure deletion past buffer)
      local anchor_line
      if has_modified then
        anchor_line = mod_start - 1 -- 0-indexed, virt_lines_above places above this line
      else
        -- Pure deletion: anchor at the line where content was deleted
        -- mod_start points to the line AFTER the deletion point
        anchor_line = math.min(mod_start - 1, buf_line_count - 1)
        anchor_line = math.max(anchor_line, 0)
      end

      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_inline, anchor_line, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        virt_lines_overflow = virt_lines_overflow,
        priority = highlight_priority,
      })
    end

    -- Step 2: Highlight added/modified lines on the real buffer
    if has_modified then
      local hl_group = has_original and "CodeDiffLineChange" or "CodeDiffLineInsert"

      for line = mod_start, mod_end - 1 do
        if line > buf_line_count then
          break
        end

        local line_idx = line - 1
        pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns_inline, line_idx, 0, {
          end_line = line_idx + 1,
          end_col = 0,
          hl_group = hl_group,
          hl_eol = true,
          priority = highlight_priority,
        })
      end
    end

    -- Step 3: Character-level highlights on modified buffer lines
    if has_modified and mapping.inner_changes then
      apply_modified_char_highlights(bufnr, mapping.inner_changes, original_lines, modified_lines)
    end
  end
end

-- ============================================================================
-- Clear inline diff decorations
-- ============================================================================

function M.clear(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns_inline, 0, -1)
  end
end

return M
