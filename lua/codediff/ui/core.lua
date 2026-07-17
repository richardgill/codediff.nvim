-- Core diff rendering algorithm
local M = {}

local config = require("codediff.config")
local highlights = require("codediff.ui.highlights")
local filler_renderer = require("codediff.ui.filler")
local char_ranges = require("codediff.ui.char_ranges")

-- Namespace references
local ns_highlight = highlights.ns_highlight
local ns_filler = highlights.ns_filler
local ns_conflict = highlights.ns_conflict

-- ============================================================================
-- Helper Functions
-- ============================================================================

-- Check if a range is empty (start and end are the same position)
local function is_empty_range(range)
  return range.start_line == range.end_line and range.start_col == range.end_col
end

local function has_lines(line_range)
  return line_range.end_line > line_range.start_line
end

local function get_modified_line_highlight(mapping)
  return has_lines(mapping.original) and "CodeDiffLineChange" or "CodeDiffLineInsert"
end

-- ============================================================================
-- Step 1: Line-Level Highlights
-- ============================================================================

local function apply_line_highlights(bufnr, line_range, hl_group)
  if line_range.end_line <= line_range.start_line then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for line = line_range.start_line, line_range.end_line - 1 do
    if line > line_count then
      break
    end

    local line_idx = line - 1

    vim.api.nvim_buf_set_extmark(bufnr, ns_highlight, line_idx, 0, {
      end_line = line_idx + 1,
      end_col = 0,
      hl_group = hl_group,
      hl_eol = true,
      priority = config.options.diff.highlight_priority,
    })
  end
end

-- ============================================================================
-- Step 2: Character-Level Highlights
-- ============================================================================

local function apply_unpaired_line_text_highlights(bufnr, lines, mapping, side, hl_group)
  local paired = {}
  for _, pair in ipairs(mapping.line_pairs) do
    paired[pair[side .. "_line"]] = true
  end

  for line = mapping[side].start_line, mapping[side].end_line - 1 do
    if not paired[line] and lines[line] and #lines[line] > 0 then
      vim.api.nvim_buf_set_extmark(bufnr, ns_highlight, line - 1, 0, {
        end_col = #lines[line],
        hl_group = hl_group,
        priority = 200,
      })
    end
  end
end

local function apply_char_highlight(args)
  local line_count = vim.api.nvim_buf_line_count(args.bufnr)
  local segments = char_ranges.to_line_segments(args.range, args.counterpart, args.lines, args.counterpart_lines)

  for _, segment in ipairs(segments) do
    if segment.line <= line_count then
      pcall(vim.api.nvim_buf_set_extmark, args.bufnr, ns_highlight, segment.line - 1, segment.start_col, {
        end_col = segment.end_col,
        hl_group = segment.line_text and args.line_text_hl_group or args.hl_group,
        priority = 200,
      })
    end
  end
end

-- ============================================================================
-- Step 3: Filler Line Calculation
-- ============================================================================

local function calculate_fillers(mapping)
  local fillers = {}
  local original_line = mapping.original.start_line
  local modified_line = mapping.modified.start_line

  for _, pair in ipairs(mapping.line_pairs) do
    local original_count = pair.original_line - original_line
    local modified_count = pair.modified_line - modified_line
    if original_count > modified_count then
      fillers[#fillers + 1] = {
        buffer = "modified",
        after_line = pair.modified_line - 1,
        count = original_count - modified_count,
      }
    elseif modified_count > original_count then
      fillers[#fillers + 1] = {
        buffer = "original",
        after_line = pair.original_line - 1,
        count = modified_count - original_count,
      }
    end
    original_line = pair.original_line + 1
    modified_line = pair.modified_line + 1
  end

  local original_count = mapping.original.end_line - original_line
  local modified_count = mapping.modified.end_line - modified_line
  if original_count > modified_count then
    fillers[#fillers + 1] = {
      buffer = "modified",
      after_line = mapping.modified.end_line - 1,
      count = original_count - modified_count,
    }
  elseif modified_count > original_count then
    fillers[#fillers + 1] = {
      buffer = "original",
      after_line = mapping.original.end_line - 1,
      count = modified_count - original_count,
    }
  end

  return fillers
end

-- ============================================================================
-- Main Rendering Function
-- ============================================================================

-- Render diff highlights and fillers
-- Assumes buffer content is already set by caller
function M.render_diff(left_bufnr, right_bufnr, original_lines, modified_lines, lines_diff)
  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_filler, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_filler, 0, -1)

  local total_left_fillers = 0
  local total_right_fillers = 0

  for _, mapping in ipairs(lines_diff.changes) do
    local orig_has_lines = has_lines(mapping.original)
    local mod_has_lines = has_lines(mapping.modified)

    if orig_has_lines then
      apply_line_highlights(left_bufnr, mapping.original, "CodeDiffLineDelete")
      apply_unpaired_line_text_highlights(left_bufnr, original_lines, mapping, "original", "CodeDiffLineDeleteText")
    end

    if mod_has_lines then
      apply_line_highlights(right_bufnr, mapping.modified, get_modified_line_highlight(mapping))
      apply_unpaired_line_text_highlights(right_bufnr, modified_lines, mapping, "modified", "CodeDiffLineInsertText")
    end

    if mapping.inner_changes then
      for _, inner in ipairs(mapping.inner_changes) do
        if not is_empty_range(inner.original) then
          apply_char_highlight({
            bufnr = left_bufnr,
            range = inner.original,
            counterpart = inner.modified,
            hl_group = "CodeDiffCharDelete",
            line_text_hl_group = "CodeDiffLineDeleteText",
            lines = original_lines,
            counterpart_lines = modified_lines,
          })
        end

        if not is_empty_range(inner.modified) then
          apply_char_highlight({
            bufnr = right_bufnr,
            range = inner.modified,
            counterpart = inner.original,
            hl_group = "CodeDiffCharInsert",
            line_text_hl_group = "CodeDiffLineInsertText",
            lines = modified_lines,
            counterpart_lines = original_lines,
          })
        end
      end
    end

    local fillers = calculate_fillers(mapping)

    for _, filler in ipairs(fillers) do
      if filler.buffer == "original" then
        filler_renderer.place(left_bufnr, filler.after_line - 1, filler.count)
        total_left_fillers = total_left_fillers + filler.count
      else
        filler_renderer.place(right_bufnr, filler.after_line - 1, filler.count)
        total_right_fillers = total_right_fillers + filler.count
      end
    end
  end

  -- Render moved code indicators (separate module)
  if lines_diff.moves and #lines_diff.moves > 0 then
    local ok, move = pcall(require, "codediff.ui.move")
    if ok and move then
      move.render_moves(left_bufnr, right_bufnr, lines_diff)
    else
      vim.notify_once("[codediff] failed to load codediff.ui.move: " .. tostring(move), vim.log.levels.WARN)
    end
  end

  return {
    left_fillers = total_left_fillers,
    right_fillers = total_right_fillers,
  }
end

-- ============================================================================
-- Whole File Rendering
-- ============================================================================

--- Render a one-sided file with highlighting across all logical lines.
---@param bufnr number
---@param side "original"|"modified"
function M.render_whole_file(bufnr, side)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_filler, 0, -1)

  if not config.options.diff.highlight_added_deleted_files then
    return
  end

  local highlight_groups = {
    original = "CodeDiffLineDelete",
    modified = "CodeDiffLineInsert",
  }
  local hl_group = highlight_groups[side]
  if not hl_group then
    error("Invalid whole-file diff side: " .. tostring(side))
  end

  vim.api.nvim_buf_set_extmark(bufnr, ns_highlight, 0, 0, {
    end_row = vim.api.nvim_buf_line_count(bufnr),
    end_col = 0,
    hl_group = hl_group,
    hl_eol = true,
    priority = config.options.diff.highlight_priority,
    right_gravity = false,
    end_right_gravity = true,
  })
end

-- ============================================================================
-- Single Buffer Rendering (for merge view)
-- ============================================================================

-- Render diff highlights for a single buffer
-- Used in merge view where each buffer shows diff against base independently
-- bufnr: buffer number to render
-- diff: the diff result (same format as lines_diff from compute_diff)
-- side: "original" or "modified" - which side of the diff this buffer represents
--       "original" = deletions (red highlights)
--       "modified" = insertions (green highlights)
function M.render_single_buffer(bufnr, diff, side, counterpart_lines)
  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_filler, 0, -1)

  -- Get buffer lines for character highlight calculations
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Determine highlight groups based on side
  local char_hl = side == "original" and "CodeDiffCharDelete" or "CodeDiffCharInsert"
  local line_text_hl = side == "original" and "CodeDiffLineDeleteText" or "CodeDiffLineInsertText"
  local counterpart_side = side == "original" and "modified" or "original"

  for _, mapping in ipairs(diff.changes) do
    -- Get the range for our side
    local range = mapping[side]
    if not range then
      goto continue
    end

    -- Apply line highlights
    if has_lines(range) then
      local line_hl = side == "original" and "CodeDiffLineDelete" or get_modified_line_highlight(mapping)
      apply_line_highlights(bufnr, range, line_hl)
      apply_unpaired_line_text_highlights(bufnr, lines, mapping, side, line_text_hl)
    end

    -- Apply character highlights from inner changes
    if mapping.inner_changes then
      for _, inner in ipairs(mapping.inner_changes) do
        local inner_range = inner[side]
        if inner_range and not is_empty_range(inner_range) then
          apply_char_highlight({
            bufnr = bufnr,
            range = inner_range,
            counterpart = inner[counterpart_side],
            hl_group = char_hl,
            line_text_hl_group = line_text_hl,
            lines = lines,
            counterpart_lines = counterpart_lines,
          })
        end
      end
    end

    ::continue::
  end
end

-- ============================================================================
-- Merge View Rendering (3-way merge with alignment)
-- ============================================================================

-- Render merge view with proper alignment between left and right buffers
-- Both buffers show diff against base, with filler lines to align corresponding changes
-- left_bufnr: buffer showing input1 (incoming/theirs :3)
-- right_bufnr: buffer showing input2 (current/ours :2)
-- base_to_left_diff: diff from base to input1
-- base_to_right_diff: diff from base to input2
-- base_lines: array of base content lines
-- left_lines_content: array of input1 content lines
-- right_lines_content: array of input2 content lines
function M.render_merge_view(left_bufnr, right_bufnr, base_to_left_diff, base_to_right_diff, base_lines, left_lines_content, right_lines_content)
  local merge_alignment = require("codediff.ui.merge_alignment")

  -- Clear existing highlights and fillers
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_filler, 0, -1)
  vim.api.nvim_buf_clear_namespace(left_bufnr, ns_conflict, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_highlight, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_filler, 0, -1)
  vim.api.nvim_buf_clear_namespace(right_bufnr, ns_conflict, 0, -1)

  -- Get buffer lines for character highlight calculations
  local left_lines = vim.api.nvim_buf_get_lines(left_bufnr, 0, -1, false)
  local right_lines = vim.api.nvim_buf_get_lines(right_bufnr, 0, -1, false)

  -- Compute alignments to identify conflict regions (where both sides have changes)
  local alignments, conflict_left_changes, conflict_right_changes =
    merge_alignment.compute_merge_fillers_and_conflicts(base_to_left_diff, base_to_right_diff, base_lines, left_lines_content, right_lines_content)

  -- Render highlights ONLY for conflict regions (where both left and right modified the same base region)
  -- This matches VSCode's behavior of only highlighting conflicting changes
  for _, change in ipairs(conflict_left_changes) do
    local range = change.modified
    if range and has_lines(range) then
      apply_line_highlights(left_bufnr, range, "CodeDiffLineInsert")
      apply_unpaired_line_text_highlights(left_bufnr, left_lines, change, "modified", "CodeDiffLineInsertText")
    end
    if change.inner_changes then
      for _, inner in ipairs(change.inner_changes) do
        local inner_range = inner.modified
        if inner_range and not is_empty_range(inner_range) then
          apply_char_highlight({
            bufnr = left_bufnr,
            range = inner_range,
            counterpart = inner.original,
            hl_group = "CodeDiffCharInsert",
            line_text_hl_group = "CodeDiffLineInsertText",
            lines = left_lines,
            counterpart_lines = base_lines,
          })
        end
      end
    end
  end

  for _, change in ipairs(conflict_right_changes) do
    local range = change.modified
    if range and has_lines(range) then
      apply_line_highlights(right_bufnr, range, "CodeDiffLineInsert")
      apply_unpaired_line_text_highlights(right_bufnr, right_lines, change, "modified", "CodeDiffLineInsertText")
    end
    if change.inner_changes then
      for _, inner in ipairs(change.inner_changes) do
        local inner_range = inner.modified
        if inner_range and not is_empty_range(inner_range) then
          apply_char_highlight({
            bufnr = right_bufnr,
            range = inner_range,
            counterpart = inner.original,
            hl_group = "CodeDiffCharInsert",
            line_text_hl_group = "CodeDiffLineInsertText",
            lines = right_lines,
            counterpart_lines = base_lines,
          })
        end
      end
    end
  end

  -- Extract fillers from alignments
  local left_fillers, right_fillers = alignments.left_fillers, alignments.right_fillers

  local total_left_fillers = 0
  local total_right_fillers = 0

  for _, filler in ipairs(left_fillers) do
    filler_renderer.place(left_bufnr, filler.after_line - 1, filler.count)
    total_left_fillers = total_left_fillers + filler.count
  end

  for _, filler in ipairs(right_fillers) do
    filler_renderer.place(right_bufnr, filler.after_line - 1, filler.count)
    total_right_fillers = total_right_fillers + filler.count
  end

  return {
    left_fillers = total_left_fillers,
    right_fillers = total_right_fillers,
    conflict_blocks = alignments.conflict_blocks,
  }
end

return M
