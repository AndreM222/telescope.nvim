local conf = require("telescope.config").values
local finders = require "telescope.finders"
local make_entry = require "telescope.make_entry"
local pickers = require "telescope.pickers"
local utils = require "telescope.utils"

local Msgstr = require('telescope.langMSG').Msgstr

local diagnostics = {}

local sorting_comparator = function(opts)
  local current_buf = vim.api.nvim_get_current_buf()
  local comparators = {
    -- sort results by bufnr (prioritize cur buf), severity, lnum
    buffer = function(a, b)
      if a.bufnr == b.bufnr then
        if a.type == b.type then
          return a.lnum < b.lnum
        else
          return a.type < b.type
        end
      else
        if a.bufnr == current_buf then
          return true
        end
        if b.bufnr == current_buf then
          return false
        end
        return a.bufnr < b.bufnr
      end
    end,
    severity = function(a, b)
      if a.type < b.type then
        return true
      elseif a.type > b.type then
        return false
      end

      if a.bufnr == b.bufnr then
        return a.lnum < b.lnum
      elseif a.bufnr == current_buf then
        return true
      elseif b.bufnr == current_buf then
        return false
      else
        return a.bufnr < b.bufnr
      end
    end,
  }

  local sort_by = vim.F.if_nil(opts.sort_by, "buffer")
  return comparators[sort_by]
end

local convert_diagnostic_type = function(severities, severity)
  -- convert from string to int
  if type(severity) == "string" then
    -- make sure that e.g. error is uppercased to ERROR
    return severities[severity:upper()]
  end
  -- otherwise keep original value, incl. nil
  return severity
end

local diagnostics_to_tbl = function(opts)
  opts = vim.F.if_nil(opts, {})
  local items = {}
  local severities = vim.diagnostic.severity

  opts.severity = convert_diagnostic_type(severities, opts.severity)
  opts.severity_limit = convert_diagnostic_type(severities, opts.severity_limit)
  opts.severity_bound = convert_diagnostic_type(severities, opts.severity_bound)

  local diagnosis_opts = { severity = {}, namespace = opts.namespace }
  if opts.severity ~= nil then
    if opts.severity_limit ~= nil or opts.severity_bound ~= nil then
      utils.notify("builtin.diagnostics", {
        msg = Msgstr("Invalid severity parameters. Both a specific severity and a limit/bound is not allowed"),
        level = "ERROR",
      })
      return {}
    end
    diagnosis_opts.severity = opts.severity
  else
    if opts.severity_limit ~= nil then
      diagnosis_opts.severity["min"] = opts.severity_limit
    end
    if opts.severity_bound ~= nil then
      diagnosis_opts.severity["max"] = opts.severity_bound
    end
    if vim.version().minor > 9 and vim.tbl_isempty(diagnosis_opts.severity) then
      diagnosis_opts.severity = nil
    end
  end

  opts.root_dir = opts.root_dir == true and vim.loop.cwd() or opts.root_dir

  local bufnr_name_map = {}
  local filter_diag = function(diagnostic)
    if bufnr_name_map[diagnostic.bufnr] == nil then
      bufnr_name_map[diagnostic.bufnr] = vim.api.nvim_buf_get_name(diagnostic.bufnr)
    end

    local root_dir_test = not opts.root_dir
      or string.sub(bufnr_name_map[diagnostic.bufnr], 1, #opts.root_dir) == opts.root_dir
    local listed_test = not opts.no_unlisted or vim.api.nvim_buf_get_option(diagnostic.bufnr, "buflisted")

    return root_dir_test and listed_test
  end

  local preprocess_diag = function(diagnostic)
    return {
      bufnr = diagnostic.bufnr,
      filename = bufnr_name_map[diagnostic.bufnr],
      lnum = diagnostic.lnum + 1,
      col = diagnostic.col + 1,
      text = vim.trim(diagnostic.message:gsub("[\n]", "")),
      type = severities[diagnostic.severity] or severities[1],
    }
  end

  for _, d in ipairs(vim.diagnostic.get(opts.bufnr, diagnosis_opts)) do
    if filter_diag(d) then
      table.insert(items, preprocess_diag(d))
    end
  end

  table.sort(items, sorting_comparator(opts))

  return items
end

diagnostics.get = function(opts)
  if opts.bufnr ~= 0 then
    opts.bufnr = nil
  end
  if type(opts.bufnr) == "string" then
    opts.bufnr = tonumber(opts.bufnr)
  end
  if opts.bufnr ~= nil then
    opts.path_display = vim.F.if_nil(opts.path_display, "hidden")
  end

  local locations = diagnostics_to_tbl(opts)

  if vim.tbl_isempty(locations) then
    utils.notify("builtin.diagnostics", {
      msg = Msgstr("No diagnostics found"),
      level = "INFO",
    })
    return
  end

  if type(opts.line_width) == "string" and opts.line_width ~= "full" then
    utils.notify("builtin.diagnostics", {
      msg = Msgstr("'%s' is not a valid value for line_width", {opts.line_width}),
      level = "ERROR",
    })
    return
  end

  pickers
    .new(opts, {
      prompt_title = opts.bufnr == nil and Msgstr("Workspace Diagnostics") or Msgstr("Document Diagnostics"),
      finder = finders.new_table {
        results = locations,
        entry_maker = opts.entry_maker or make_entry.gen_from_diagnostics(opts),
      },
      previewer = conf.qflist_previewer(opts),
      sorter = conf.prefilter_sorter {
        tag = "type",
        sorter = conf.generic_sorter(opts),
      },
    })
    :find()
end

local function apply_checks(mod)
  for k, v in pairs(mod) do
    mod[k] = function(opts)
      opts = opts or {}
      v(opts)
    end
  end

  return mod
end

return apply_checks(diagnostics)
