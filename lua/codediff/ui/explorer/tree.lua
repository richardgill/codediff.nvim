-- Tree data structure building for explorer
-- Handles creating the tree hierarchy from git status
local M = {}

local Tree = require("codediff.ui.lib.tree")
local config = require("codediff.config")
local filter = require("codediff.ui.explorer.filter")
local nodes = require("codediff.ui.explorer.nodes")
local line_stats = require("codediff.ui.explorer.line_stats")

-- Filter files based on explorer.file_filter config
-- Returns files that should be shown (not ignored)
local function filter_files(files)
  local explorer_config = config.options.explorer or {}
  local file_filter = explorer_config.file_filter or {}
  local ignore_patterns = file_filter.ignore or {}

  return filter.apply(files, ignore_patterns)
end

-- Creates a collapsible heading such as "Changes (3 · +42 -8)" above its file nodes.
local function create_group_node(label, name, files, children)
  local line_stats_options = config.options.explorer.line_stats
  local stat_segments = { { text = tostring(#files), hl = "CodeDiffExplorerTreeGroup" } }
  if line_stats_options.enabled and line_stats_options.group_totals then
    stat_segments = line_stats.build_group_segments(files, line_stats_options)
  end

  local formatted_stats = line_stats.text(stat_segments)
  local text = formatted_stats == "" and label or string.format("%s (%s)", label, formatted_stats)
  return Tree.Node({
    text = text,
    data = { type = "group", name = name, label = label, stat_segments = stat_segments },
  }, children)
end

-- Create tree data structure from git status result
function M.create_tree_data(status_result, git_root, base_revision, is_dir_mode, visible_groups)
  local explorer_config = config.options.explorer or {}
  local view_mode = explorer_config.view_mode or "list"
  visible_groups = visible_groups or explorer_config.visible_groups or {}

  -- Filter merge artifacts and apply file filter
  local unstaged = nodes.filter_merge_artifacts(filter_files(status_result.unstaged))
  local staged = nodes.filter_merge_artifacts(filter_files(status_result.staged))
  local conflicts = status_result.conflicts and nodes.filter_merge_artifacts(filter_files(status_result.conflicts)) or {}

  -- Decide flattening from all files once, then apply the same boundaries to every group.
  local flattenable_paths
  if view_mode == "tree" and explorer_config.flatten_dirs ~= false then
    local all_files = vim.list_extend({}, unstaged)
    vim.list_extend(all_files, staged)
    vim.list_extend(all_files, conflicts)
    flattenable_paths = nodes.get_flattenable_paths(all_files)
  end

  local create_nodes = (view_mode == "tree") and nodes.create_tree_file_nodes or nodes.create_file_nodes
  local unstaged_nodes = create_nodes(unstaged, git_root, "unstaged", flattenable_paths)
  local staged_nodes = create_nodes(staged, git_root, "staged", flattenable_paths)
  local conflict_nodes = create_nodes(conflicts, git_root, "conflicts", flattenable_paths)

  if is_dir_mode or base_revision then
    -- Dir or revision mode: single group showing all changes
    return {
      create_group_node("Changes", "unstaged", unstaged, unstaged_nodes),
    }
  else
    -- Status mode: separate conflicts/staged/unstaged groups
    local tree_nodes = {}

    -- Conflicts first (most important)
    if #conflict_nodes > 0 and visible_groups.conflicts ~= false then
      table.insert(tree_nodes, create_group_node("Merge Changes", "conflicts", conflicts, conflict_nodes))
    end

    -- Unstaged changes
    if visible_groups.unstaged ~= false then
      table.insert(tree_nodes, create_group_node("Changes", "unstaged", unstaged, unstaged_nodes))
    end

    -- Staged changes
    if visible_groups.staged ~= false then
      table.insert(tree_nodes, create_group_node("Staged Changes", "staged", staged, staged_nodes))
    end

    return tree_nodes
  end
end

return M
