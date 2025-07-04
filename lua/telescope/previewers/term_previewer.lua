local conf = require("telescope.config").values
local utils = require "telescope.utils"
local Path = require "plenary.path"
local from_entry = require "telescope.from_entry"
local Previewer = require "telescope.previewers.previewer"
local putil = require "telescope.previewers.utils"
local Msgstr = require('telescope.langMSG').Msgstr

local defaulter = utils.make_default_callable

local previewers = {}

-- TODO: Should play with these some more, ty @clason
local bat_options = { "--style=plain", "--color=always", "--paging=always" }
local has_less = (vim.fn.executable "less" == 1) and conf.use_less

local get_file_stat = function(filename)
  return vim.loop.fs_stat(utils.path_expand(filename)) or {}
end

local list_dir = (function()
  if vim.fn.has "win32" == 1 then
    return function(dirname)
      return { "cmd.exe", "/c", "dir", utils.path_expand(dirname) }
    end
  else
    return function(dirname)
      return { "ls", "-la", utils.path_expand(dirname) }
    end
  end
end)()

local bat_maker = function(filename, lnum, start, finish)
  if get_file_stat(filename).type == "directory" then
    return list_dir(filename)
  end

  local command = { "bat" }

  if lnum then
    vim.list_extend(command, { "--highlight-line", lnum })
  end

  if has_less then
    if start then
      vim.list_extend(command, { "--pager", Msgstr("less -RS +%s", { start }) })
    else
      vim.list_extend(command, { "--pager", "less -RS" })
    end
  else
    if start and finish then
      vim.list_extend(command, { "-r", Msgstr("%s:%s", {start, finish}) })
    end
  end

  return utils.flatten {
    command,
    bat_options,
    "--",
    utils.path_expand(filename),
  }
end

local cat_maker = function(filename, _, start, _)
  if get_file_stat(filename).type == "directory" then
    return list_dir(filename)
  end

  if 1 == vim.fn.executable "file" then
    local mime_type = utils.get_os_command_output({ "file", "--mime-type", "-b", filename })[1]
    if putil.binary_mime_type(mime_type) then
      return { "echo", "Binary file found. These files cannot be displayed!" }
    end
  end

  if has_less then
    if start then
      return { "less", "-RS", string.format("+%s", start), utils.path_expand(filename) }
    else
      return { "less", "-RS", utils.path_expand(filename) }
    end
  else
    return {
      "cat",
      "--",
      utils.path_expand(filename),
    }
  end
end

local get_maker = function(opts)
  local maker = opts.maker
  if not maker and 1 == vim.fn.executable "bat" then
    maker = bat_maker
  elseif not maker and 1 == vim.fn.executable "cat" then
    maker = cat_maker
  end

  if not maker then
    error "Needs maker"
  end

  return maker
end

previewers.new_termopen_previewer = function(opts)
  opts = opts or {}

  assert(opts.get_command, "get_command is a required function")
  assert(not opts.preview_fn, "preview_fn not allowed")

  local opt_setup = opts.setup
  local opt_teardown = opts.teardown

  local old_bufs = {}
  local bufentry_table = {}
  local term_ids = {}

  local function get_term_id(self)
    if self.state then
      return self.state.termopen_id
    end
  end

  local function get_bufnr(self)
    if self.state then
      return self.state.termopen_bufnr
    end
  end

  local function set_term_id(self, value)
    if self.state and term_ids[self.state.termopen_bufnr] == nil then
      term_ids[self.state.termopen_bufnr] = value
      self.state.termopen_id = value
    end
  end

  local function set_bufnr(self, value)
    if get_bufnr(self) then
      table.insert(old_bufs, get_bufnr(self))
    end
    if self.state then
      self.state.termopen_bufnr = value
    end
  end

  local function get_bufnr_by_bufentry(self, value)
    if self.state then
      return bufentry_table[value]
    end
  end

  local function set_bufentry(self, value)
    if self.state and value then
      bufentry_table[value] = get_bufnr(self)
    end
  end

  function opts.setup(self)
    local state = {}
    if opt_setup then
      state = vim.tbl_deep_extend("force", state, opt_setup(self))
    end
    return state
  end

  function opts.teardown(self)
    if opt_teardown then
      opt_teardown(self)
    end

    set_bufnr(self, nil)
    set_bufentry(self, nil)

    for _, bufnr in ipairs(old_bufs) do
      local term_id = term_ids[bufnr]
      if term_id and utils.job_is_running(term_id) then
        vim.fn.jobstop(term_id)
      end
      utils.buf_delete(bufnr)
    end
    bufentry_table = {}
  end

  function opts.preview_fn(self, entry, status)
    local preview_winid = status.layout.preview and status.layout.preview.winid
    if get_bufnr(self) == nil then
      set_bufnr(self, vim.api.nvim_win_get_buf(preview_winid))
    end

    local prev_bufnr = get_bufnr_by_bufentry(self, entry)
    if prev_bufnr then
      set_bufnr(self, prev_bufnr)
      utils.win_set_buf_noautocmd(preview_winid, self.state.termopen_bufnr)
      self.state.termopen_id = term_ids[self.state.termopen_bufnr]
    else
      local bufnr = vim.api.nvim_create_buf(false, true)
      set_bufnr(self, bufnr)
      utils.win_set_buf_noautocmd(preview_winid, bufnr)

      local term_opts = {
        cwd = opts.cwd or vim.loop.cwd(),
        env = opts.env or conf.set_env,
      }

      local cmd = opts.get_command(entry, status)
      if cmd then
        vim.api.nvim_buf_call(bufnr, function()
          set_term_id(self, vim.fn.termopen(cmd, term_opts))
        end)
      end
      set_bufentry(self, entry)
    end
  end

  if not opts.send_input then
    function opts.send_input(self, input)
      local termcode = vim.api.nvim_replace_termcodes(input, true, false, true)

      local term_id = get_term_id(self)
      if term_id then
        if not utils.job_is_running(term_id) then
          return
        end

        vim.fn.chansend(term_id, termcode)
      end
    end
  end

  if not opts.scroll_fn then
    function opts.scroll_fn(self, direction)
      if not self.state then
        return
      end

      local input = direction > 0 and "d" or "u"
      local count = math.abs(direction)

      self:send_input(count .. input)
    end
  end

  return Previewer:new(opts)
end

previewers.cat = defaulter(function(opts)
  opts = opts or {}

  local maker = get_maker(opts)
  local cwd = opts.cwd or vim.loop.cwd()

  return previewers.new_termopen_previewer {
    title = Msgstr("File Preview"),
    dyn_title = function(_, entry)
      return Path:new(from_entry.path(entry, false, false)):normalize(cwd)
    end,

    get_command = function(entry)
      local p = from_entry.path(entry, true, false)
      if p == nil or p == "" then
        return
      end

      return maker(p)
    end,
  }
end, {})

previewers.vimgrep = defaulter(function(opts)
  opts = opts or {}

  local maker = get_maker(opts)
  local cwd = opts.cwd or vim.loop.cwd()

  return previewers.new_termopen_previewer {
    title = Msgstr("Grep Preview"),
    dyn_title = function(_, entry)
      return Path:new(from_entry.path(entry, false, false)):normalize(cwd)
    end,

    get_command = function(entry, status)
      local win_id = status.layout.preview and status.layout.preview.winid
      local height = vim.api.nvim_win_get_height(win_id)

      local p = from_entry.path(entry, true, false)
      if p == nil or p == "" then
        return
      end
      if entry.bufnr and (p == "[No Name]" or vim.api.nvim_buf_get_option(entry.bufnr, "buftype") ~= "") then
        return
      end

      local lnum = entry.lnum or 0

      local context = math.floor(height / 2)
      local start = math.max(0, lnum - context)
      local finish = lnum + context

      return maker(p, lnum, start, finish)
    end,
  }
end, {})

previewers.qflist = defaulter(function(opts)
  opts = opts or {}

  local maker = get_maker(opts)
  local cwd = opts.cwd or vim.loop.cwd()

  return previewers.new_termopen_previewer {
    title = Msgstr("Grep Preview"),
    dyn_title = function(_, entry)
      return Path:new(from_entry.path(entry, false, false)):normalize(cwd)
    end,

    get_command = function(entry, status)
      local win_id = status.layout.preview and status.layout.preview.winid
      local height = vim.api.nvim_win_get_height(win_id)

      local p = from_entry.path(entry, true, false)
      if p == nil or p == "" then
        return
      end
      local lnum = entry.lnum

      local start, finish
      if entry.start and entry.finish then
        start = entry.start
        finish = entry.finish
      else
        local context = math.floor(height / 2)
        start = math.max(0, lnum - context)
        finish = lnum + context
      end

      return maker(p, lnum, start, finish)
    end,
  }
end, {})

return previewers
