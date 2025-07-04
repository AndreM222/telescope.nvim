local action_state = require "telescope.actions.state"
local action_set = require "telescope.actions.set"
local actions = require "telescope.actions"
local finders = require "telescope.finders"
local make_entry = require "telescope.make_entry"
local pickers = require "telescope.pickers"
local previewers = require "telescope.previewers"
local sorters = require "telescope.sorters"
local utils = require "telescope.utils"
local conf = require("telescope.config").values
local log = require "telescope.log"
local Msgstr = require('telescope.langMSG').Msgstr

local Path = require "plenary.path"

local flatten = utils.flatten
local filter = vim.tbl_filter

local files = {}

---@param s string
---@return string
local escape_chars = function(s)
  return (
    s:gsub("[%(|%)|\\|%[|%]|%-|%{%}|%?|%+|%*|%^|%$|%.]", {
      ["\\"] = "\\\\",
      ["-"] = "\\-",
      ["("] = "\\(",
      [")"] = "\\)",
      ["["] = "\\[",
      ["]"] = "\\]",
      ["{"] = "\\{",
      ["}"] = "\\}",
      ["?"] = "\\?",
      ["+"] = "\\+",
      ["*"] = "\\*",
      ["^"] = "\\^",
      ["$"] = "\\$",
      ["."] = "\\.",
    })
  )
end

local has_rg_program = function(picker_name, program)
  if vim.fn.executable(program) == 1 then
    return true
  end

  utils.notify(picker_name, {
    msg = Msgstr(
      "'ripgrep', or similar alternative, is a required dependency for the %s picker. Visit https://github.com/BurntSushi/ripgrep#installation for installation instructions.", {
      picker_name
    }),
    level = "ERROR",
  })
  return false
end

local get_open_filelist = function(grep_open_files, cwd)
  if not grep_open_files then
    return nil
  end

  local bufnrs = filter(function(b)
    if 1 ~= vim.fn.buflisted(b) then
      return false
    end
    return true
  end, vim.api.nvim_list_bufs())
  if not next(bufnrs) then
    return
  end

  local filelist = {}
  for _, bufnr in ipairs(bufnrs) do
    local file = vim.api.nvim_buf_get_name(bufnr)
    table.insert(filelist, Path:new(file):make_relative(cwd))
  end
  return filelist
end

local opts_contain_invert = function(args)
  local invert = false
  local files_with_matches = false

  for _, v in ipairs(args) do
    if v == "--invert-match" then
      invert = true
    elseif v == "--files-with-matches" or v == "--files-without-match" then
      files_with_matches = true
    end

    if #v >= 2 and v:sub(1, 1) == "-" and v:sub(2, 2) ~= "-" then
      local non_option = false
      for i = 2, #v do
        local vi = v:sub(i, i)
        if vi == "=" then -- ignore option -g=xxx
          break
        elseif vi == "g" or vi == "f" or vi == "m" or vi == "e" or vi == "r" or vi == "t" or vi == "T" then
          non_option = true
        elseif non_option == false and vi == "v" then
          invert = true
        elseif non_option == false and vi == "l" then
          files_with_matches = true
        end
      end
    end
  end
  return invert, files_with_matches
end

-- Special keys:
--  opts.search_dirs -- list of directory to search in
--  opts.grep_open_files -- boolean to restrict search to open files
files.live_grep = function(opts)
  local vimgrep_arguments = opts.vimgrep_arguments or conf.vimgrep_arguments
  if not has_rg_program("live_grep", vimgrep_arguments[1]) then
    return
  end
  local search_dirs = opts.search_dirs
  local grep_open_files = opts.grep_open_files
  opts.cwd = opts.cwd and utils.path_expand(opts.cwd) or vim.loop.cwd()

  local filelist = get_open_filelist(grep_open_files, opts.cwd)
  if search_dirs then
    for i, path in ipairs(search_dirs) do
      search_dirs[i] = utils.path_expand(path)
    end
  end

  local additional_args = {}
  if opts.additional_args ~= nil then
    if type(opts.additional_args) == "function" then
      additional_args = opts.additional_args(opts)
    elseif type(opts.additional_args) == "table" then
      additional_args = opts.additional_args
    end
  end

  if opts.type_filter then
    additional_args[#additional_args + 1] = "--type=" .. opts.type_filter
  end

  if type(opts.glob_pattern) == "string" then
    additional_args[#additional_args + 1] = "--glob=" .. opts.glob_pattern
  elseif type(opts.glob_pattern) == "table" then
    for i = 1, #opts.glob_pattern do
      additional_args[#additional_args + 1] = "--glob=" .. opts.glob_pattern[i]
    end
  end

  if opts.file_encoding then
    additional_args[#additional_args + 1] = "--encoding=" .. opts.file_encoding
  end

  local args = flatten { vimgrep_arguments, additional_args }
  opts.__inverted, opts.__matches = opts_contain_invert(args)

  local live_grepper = finders.new_job(function(prompt)
    if not prompt or prompt == "" then
      return nil
    end

    local search_list = {}

    if grep_open_files then
      search_list = filelist
    elseif search_dirs then
      search_list = search_dirs
    end

    return flatten { args, "--", prompt, search_list }
  end, opts.entry_maker or make_entry.gen_from_vimgrep(opts), opts.max_results, opts.cwd)

  pickers
    .new(opts, {
      prompt_title = Msgstr("Live Grep"),
      finder = live_grepper,
      previewer = conf.grep_previewer(opts),
      -- TODO: It would be cool to use `--json` output for this
      -- and then we could get the highlight positions directly.
      sorter = sorters.highlighter_only(opts),
      attach_mappings = function(_, map)
        map("i", "<c-space>", actions.to_fuzzy_refine)
        return true
      end,
      push_cursor_on_edit = true,
    })
    :find()
end

files.grep_string = function(opts)
  local vimgrep_arguments = vim.F.if_nil(opts.vimgrep_arguments, conf.vimgrep_arguments)
  if not has_rg_program("grep_string", vimgrep_arguments[1]) then
    return
  end
  local word
  local visual = vim.fn.mode() == "v"

  if visual == true then
    local saved_reg = vim.fn.getreg "v"
    vim.cmd [[noautocmd sil norm! "vy]]
    local sele = vim.fn.getreg "v"
    vim.fn.setreg("v", saved_reg)
    word = vim.F.if_nil(opts.search, sele)
  else
    word = vim.F.if_nil(opts.search, vim.fn.expand "<cword>")
  end

  word = tostring(word)
  local search = opts.use_regex and word or escape_chars(word)
  local search_args = search == "" and { "-v", "--", "^[[:space:]]*$" } or { "--", search }

  local additional_args = {}
  if opts.additional_args ~= nil then
    if type(opts.additional_args) == "function" then
      additional_args = opts.additional_args(opts)
    elseif type(opts.additional_args) == "table" then
      additional_args = opts.additional_args
    end
  end

  if opts.file_encoding then
    additional_args[#additional_args + 1] = "--encoding=" .. opts.file_encoding
  end

  local args
  if visual == true then
    args = flatten {
      vimgrep_arguments,
      additional_args,
      search_args,
    }
  else
    args = flatten {
      vimgrep_arguments,
      additional_args,
      opts.word_match,
      search_args,
    }
  end

  opts.__inverted, opts.__matches = opts_contain_invert(args)

  if opts.grep_open_files then
    for _, file in ipairs(get_open_filelist(opts.grep_open_files, opts.cwd) or {}) do
      table.insert(args, file)
    end
  elseif opts.search_dirs then
    for _, path in ipairs(opts.search_dirs) do
      table.insert(args, utils.path_expand(path))
    end
  end

  opts.entry_maker = opts.entry_maker or make_entry.gen_from_vimgrep(opts)
  pickers
    .new(opts, {
      prompt_title = Msgstr("Find Word (%s)", {word:gsub("\n", "\\n")}),
      finder = finders.new_oneshot_job(args, opts),
      previewer = conf.grep_previewer(opts),
      sorter = conf.generic_sorter(opts),
      push_cursor_on_edit = true,
    })
    :find()
end

files.find_files = function(opts)
  local find_command = (function()
    if opts.find_command then
      if type(opts.find_command) == "function" then
        return opts.find_command(opts)
      end
      return opts.find_command
    elseif 1 == vim.fn.executable "rg" then
      return { "rg", "--files", "--color", "never" }
    elseif 1 == vim.fn.executable "fd" then
      return { "fd", "--type", "f", "--color", "never" }
    elseif 1 == vim.fn.executable "fdfind" then
      return { "fdfind", "--type", "f", "--color", "never" }
    elseif 1 == vim.fn.executable "find" and vim.fn.has "win32" == 0 then
      return { "find", ".", "-type", "f" }
    elseif 1 == vim.fn.executable "where" then
      return { "where", "/r", ".", "*" }
    end
  end)()

  if not find_command then
    utils.notify("builtin.find_files", {
      msg = Msgstr("You need to install either find, fd, or rg"),
      level = "ERROR",
    })
    return
  end

  local command = find_command[1]
  local hidden = opts.hidden
  local no_ignore = opts.no_ignore
  local no_ignore_parent = opts.no_ignore_parent
  local follow = opts.follow
  local search_dirs = opts.search_dirs
  local search_file = opts.search_file

  if search_dirs then
    for k, v in pairs(search_dirs) do
      search_dirs[k] = utils.path_expand(v)
    end
  end

  if command == "fd" or command == "fdfind" or command == "rg" then
    if hidden then
      find_command[#find_command + 1] = "--hidden"
    end
    if no_ignore then
      find_command[#find_command + 1] = "--no-ignore"
    end
    if no_ignore_parent then
      find_command[#find_command + 1] = "--no-ignore-parent"
    end
    if follow then
      find_command[#find_command + 1] = "-L"
    end
    if search_file then
      if command == "rg" then
        find_command[#find_command + 1] = "-g"
        find_command[#find_command + 1] = "*" .. search_file .. "*"
      else
        find_command[#find_command + 1] = search_file
      end
    end
    if search_dirs then
      if command ~= "rg" and not search_file then
        find_command[#find_command + 1] = "."
      end
      vim.list_extend(find_command, search_dirs)
    end
  elseif command == "find" then
    if not hidden then
      table.insert(find_command, { "-not", "-path", "*/.*" })
      find_command = flatten(find_command)
    end
    if no_ignore ~= nil then
      log.warn "The `no_ignore` key is not available for the `find` command in `find_files`."
    end
    if no_ignore_parent ~= nil then
      log.warn "The `no_ignore_parent` key is not available for the `find` command in `find_files`."
    end
    if follow then
      table.insert(find_command, 2, "-L")
    end
    if search_file then
      table.insert(find_command, "-name")
      table.insert(find_command, "*" .. search_file .. "*")
    end
    if search_dirs then
      table.remove(find_command, 2)
      for _, v in pairs(search_dirs) do
        table.insert(find_command, 2, v)
      end
    end
  elseif command == "where" then
    if hidden ~= nil then
      log.warn "The `hidden` key is not available for the Windows `where` command in `find_files`."
    end
    if no_ignore ~= nil then
      log.warn "The `no_ignore` key is not available for the Windows `where` command in `find_files`."
    end
    if no_ignore_parent ~= nil then
      log.warn "The `no_ignore_parent` key is not available for the Windows `where` command in `find_files`."
    end
    if follow ~= nil then
      log.warn "The `follow` key is not available for the Windows `where` command in `find_files`."
    end
    if search_dirs ~= nil then
      log.warn "The `search_dirs` key is not available for the Windows `where` command in `find_files`."
    end
    if search_file ~= nil then
      log.warn "The `search_file` key is not available for the Windows `where` command in `find_files`."
    end
  end

  if opts.cwd then
    opts.cwd = utils.path_expand(opts.cwd)
  end

  opts.entry_maker = opts.entry_maker or make_entry.gen_from_file(opts)

  pickers
    .new(opts, {
      prompt_title = Msgstr("Find Files"),
      __locations_input = true,
      finder = finders.new_oneshot_job(find_command, opts),
      previewer = conf.grep_previewer(opts),
      sorter = conf.file_sorter(opts),
    })
    :find()
end

local function prepare_match(entry, kind)
  local entries = {}

  if entry.node then
    table.insert(entries, entry)
  else
    for name, item in pairs(entry) do
      vim.list_extend(entries, prepare_match(item, name))
    end
  end

  return entries
end

--  TODO: finish docs for opts.show_line
files.treesitter = function(opts)
  opts.show_line = vim.F.if_nil(opts.show_line, true)

  local has_nvim_treesitter, _ = pcall(require, "nvim-treesitter")
  if not has_nvim_treesitter then
    utils.notify("builtin.treesitter", {
      msg = Msgstr("This picker requires nvim-treesitter"),
      level = "ERROR",
    })
    return
  end

  local parsers = require "nvim-treesitter.parsers"
  if not parsers.has_parser(parsers.get_buf_lang(opts.bufnr)) then
    utils.notify("builtin.treesitter", {
      msg = Msgstr("No parser for the current buffer"),
      level = "ERROR",
    })
    return
  end

  local ts_locals = require "nvim-treesitter.locals"
  local results = {}
  for _, definition in ipairs(ts_locals.get_definitions(opts.bufnr)) do
    local entries = prepare_match(ts_locals.get_local_nodes(definition))
    for _, entry in ipairs(entries) do
      entry.kind = vim.F.if_nil(entry.kind, "")
      table.insert(results, entry)
    end
  end

  results = utils.filter_symbols(results, opts)
  if vim.tbl_isempty(results) then
    -- error message already printed in `utils.filter_symbols`
    return
  end

  if vim.tbl_isempty(results) then
    return
  end

  pickers
    .new(opts, {
      prompt_title = Msgstr("Treesitter Symbols"),
      finder = finders.new_table {
        results = results,
        entry_maker = opts.entry_maker or make_entry.gen_from_treesitter(opts),
      },
      previewer = conf.grep_previewer(opts),
      sorter = conf.prefilter_sorter {
        tag = "kind",
        sorter = conf.generic_sorter(opts),
      },
      push_cursor_on_edit = true,
    })
    :find()
end

files.current_buffer_fuzzy_find = function(opts)
  -- All actions are on the current buffer
  local filename = vim.api.nvim_buf_get_name(opts.bufnr)
  local filetype = vim.api.nvim_buf_get_option(opts.bufnr, "filetype")

  local lines = vim.api.nvim_buf_get_lines(opts.bufnr, 0, -1, false)
  local lines_with_numbers = {}

  for lnum, line in ipairs(lines) do
    table.insert(lines_with_numbers, {
      lnum = lnum,
      bufnr = opts.bufnr,
      filename = filename,
      text = line,
    })
  end

  opts.results_ts_highlight = vim.F.if_nil(opts.results_ts_highlight, true)
  local lang = vim.treesitter.language.get_lang(filetype) or filetype
  if opts.results_ts_highlight and lang and utils.has_ts_parser(lang) then
    local parser = vim.treesitter.get_parser(opts.bufnr, lang)
    local query = vim.treesitter.query.get(lang, "highlights")
    local root = parser:parse()[1]:root()

    local line_highlights = setmetatable({}, {
      __index = function(t, k)
        local obj = {}
        rawset(t, k, obj)
        return obj
      end,
    })

    for id, node in query:iter_captures(root, opts.bufnr, 0, -1) do
      local hl = "@" .. query.captures[id]
      if hl and type(hl) ~= "number" then
        local row1, col1, row2, col2 = node:range()

        if row1 == row2 then
          local row = row1 + 1

          for index = col1, col2 do
            line_highlights[row][index] = hl
          end
        else
          local row = row1 + 1
          for index = col1, #lines[row] do
            line_highlights[row][index] = hl
          end

          while row < row2 + 1 do
            row = row + 1

            for index = 0, #(lines[row] or {}) do
              line_highlights[row][index] = hl
            end
          end
        end
      end
    end

    opts.line_highlights = line_highlights
  end

  pickers
    .new(opts, {
      prompt_title = Msgstr("Current Buffer Fuzzy"),
      finder = finders.new_table {
        results = lines_with_numbers,
        entry_maker = opts.entry_maker or make_entry.gen_from_buffer_lines(opts),
      },
      sorter = conf.generic_sorter(opts),
      previewer = conf.grep_previewer(opts),
      attach_mappings = function()
        actions.select_default:replace(function(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if not selection then
            utils.__warn_no_selection "builtin.current_buffer_fuzzy_find"
            return
          end
          local current_picker = action_state.get_current_picker(prompt_bufnr)
          local searched_for = require("telescope.actions.state").get_current_line()

          ---@type number[] | {start:number, end:number?, highlight:string?}[]
          local highlights = current_picker.sorter:highlighter(searched_for, selection.ordinal) or {}
          highlights = vim.tbl_map(function(hl)
            if type(hl) == "table" and hl.start then
              return hl.start
            elseif type(hl) == "number" then
              return hl
            end
            error "Invalid higlighter fn"
          end, highlights)

          local first_col = 0
          if #highlights > 0 then
            first_col = math.min(unpack(highlights)) - 1
          end

          actions.close(prompt_bufnr)
          vim.schedule(function()
            vim.cmd "normal! m'"
            vim.api.nvim_win_set_cursor(0, { selection.lnum, first_col })
          end)
        end)

        return true
      end,
    })
    :find()
end

files.tags = function(opts)
  local tagfiles = opts.ctags_file and { opts.ctags_file } or vim.fn.tagfiles()
  for i, ctags_file in ipairs(tagfiles) do
    tagfiles[i] = vim.fn.expand(ctags_file, true)
  end
  if vim.tbl_isempty(tagfiles) then
    utils.notify("builtin.tags", {
      msg = Msgstr("No tags file found. Create one with ctags -R"),
      level = "ERROR",
    })
    return
  end
  opts.entry_maker = vim.F.if_nil(opts.entry_maker, make_entry.gen_from_ctags(opts))

  pickers
    .new(opts, {
      prompt_title = Msgstr("Tags"),
      finder = finders.new_oneshot_job(flatten { "cat", tagfiles }, opts),
      previewer = previewers.ctags.new(opts),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function()
        action_set.select:enhance {
          post = function()
            local selection = action_state.get_selected_entry()
            if not selection then
              return
            end

            if selection.scode then
              -- un-escape / then escape required
              -- special chars for vim.fn.search()
              -- ] ~ *
              local scode = selection.scode:gsub([[\/]], "/"):gsub("[%]~*]", function(x)
                return "\\" .. x
              end)

              vim.cmd "keepjumps norm! gg"
              vim.fn.search(scode)
              vim.cmd "norm! zz"
            else
              vim.api.nvim_win_set_cursor(0, { selection.lnum, 0 })
            end
          end,
        }
        return true
      end,
    })
    :find()
end

files.current_buffer_tags = function(opts)
  return files.tags(vim.tbl_extend("force", {
    prompt_title = Msgstr("Current Buffer Tags"),
    only_current_file = true,
    path_display = "hidden",
  }, opts))
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

return apply_checks(files)
