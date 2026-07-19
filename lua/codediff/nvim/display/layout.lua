local layer = require("codediff.nvim.display.layer")

local M = {}

local context_states = setmetatable({}, { __mode = "k" })

local require_valid_window = function(win)
  if not vim.api.nvim_win_is_valid(win) then
    error("display layout requires a valid window")
  end
end

local get_render_signature = function(win, buf)
  local window_info = vim.fn.getwininfo(win)[1]
  local values = {
    vim.api.nvim_win_get_width(win),
    window_info and window_info.textoff or 0,
    vim.wo[win].wrap,
    vim.wo[win].linebreak,
    vim.wo[win].breakindent,
    vim.wo[win].breakindentopt,
    vim.wo[win].showbreak,
    vim.wo[win].list,
    vim.wo[win].listchars,
    vim.wo[win].number,
    vim.wo[win].relativenumber,
    vim.wo[win].numberwidth,
    vim.wo[win].signcolumn,
    vim.wo[win].foldcolumn,
    vim.wo[win].statuscolumn,
    vim.wo[win].conceallevel,
    vim.wo[win].concealcursor,
    vim.bo[buf].tabstop,
    vim.bo[buf].vartabstop,
    vim.o.ambiwidth,
    vim.o.display,
  }
  return table.concat(vim.tbl_map(tostring, values), "\31")
end

local scan_height_decorated_rows = function(state)
  local rows = {}
  local extmarks = vim.api.nvim_buf_get_extmarks(state.buf, -1, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    local details = extmark[4]
    local affects_height = details.virt_lines or details.virt_text or details.conceal
    local excluded = state.excluded_layer and layer._owns_namespace(state.excluded_layer, details.ns_id)
    if not excluded and affects_height then
      rows[extmark[2]] = true
    end
  end
  return rows
end

local create_context = function(state)
  local context = {}
  context_states[context] = state
  context.has_same_signature = function(_, other)
    local other_state = context_states[other]
    return other_state ~= nil and state.signature == other_state.signature
  end
  context.height_decorated_rows = function()
    if not state.decorated_rows then
      state.decorated_rows = scan_height_decorated_rows(state)
    end
    return vim.deepcopy(state.decorated_rows)
  end
  context.has_active_conceal = function()
    return state.conceallevel > 0
  end
  return context
end

function M.measure_ranges(win, ranges)
  require_valid_window(win)
  local heights = {}
  for index, range in ipairs(ranges) do
    if range.end_row <= range.start_row then
      heights[index] = 0
    else
      heights[index] = vim.api.nvim_win_text_height(win, {
        start_row = range.start_row,
        start_vcol = 0,
        end_row = range.end_row - 1,
      }).all
    end
  end
  return heights
end

function M.measurement_context(win, opts)
  require_valid_window(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return create_context({
    buf = buf,
    conceallevel = vim.wo[win].conceallevel,
    excluded_layer = opts and opts.exclude_layer or nil,
    signature = get_render_signature(win, buf),
  })
end

function M.closed_folds(win, rows)
  require_valid_window(win)
  local line_count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
  return vim.api.nvim_win_call(win, function()
    local fold_ends = {}
    local seen = {}
    for _, row in ipairs(rows) do
      if row >= 0 and row < line_count and not seen[row] then
        seen[row] = true
        local fold_start = vim.fn.foldclosed(row + 1)
        if fold_start >= 0 then
          fold_ends[row] = vim.fn.foldclosedend(row + 1)
        end
      end
    end
    return fold_ends
  end)
end

return M
