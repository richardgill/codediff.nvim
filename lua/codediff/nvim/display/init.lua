local events = require("codediff.nvim.display.events")
local layer = require("codediff.nvim.display.layer")
local layout = require("codediff.nvim.display.layout")
local viewport = require("codediff.nvim.display.viewport")

local M = {
  capture = viewport.capture,
  restore = viewport.restore,
  get_offset = viewport.get_offset,
  set_offset = events.set_offset,
  observe = events.observe,
  unobserve = events.unobserve,
  synchronize = events.synchronize,
  create_layer = layer.create_layer,
  set_layer = layer.set_layer,
  clear_layer = layer.clear_layer,
  destroy_layer = layer.destroy_layer,
  measure_ranges = layout.measure_ranges,
  measurement_context = layout.measurement_context,
  closed_folds = layout.closed_folds,
}

function M.is_viewport_supported()
  return vim.fn.has("nvim-0.12") == 1 and type(vim.api.nvim_win_text_height) == "function"
end

function M.is_supported()
  return M.is_viewport_supported() and layer._is_supported()
end

return M
