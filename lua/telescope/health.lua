local health = vim.health or require "health"
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local error = health.error or health.report_error
local info = health.info or health.report_info

local Msgstr = require('telescope.langMSG').Msgstr
local extension_module = require "telescope._extensions"
local extension_info = require("telescope").extensions
local is_win = vim.api.nvim_call_function("has", { "win32" }) == 1

local optional_dependencies = {
  {
    finder_name = "live-grep",
    package = {
      {
        name = "rg",
        url = "[BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep)",
        optional = false,
      },
    },
  },
  {
    finder_name = "find-files",
    package = {
      {
        name = "fd",
        binaries = { "fdfind", "fd" },
        url = "[sharkdp/fd](https://github.com/sharkdp/fd)",
        optional = true,
      },
    },
  },
}

local required_plugins = {
  { lib = "plenary", optional = false },
  {
    lib = "nvim-treesitter",
    optional = true,
    info = "(Required for `:Telescope treesitter`.)",
  },
}

local check_binary_installed = function(package)
  local binaries = package.binaries or { package.name }
  for _, binary in ipairs(binaries) do
    local found = vim.fn.executable(binary) == 1
    if not found and is_win then
      binary = binary .. ".exe"
      found = vim.fn.executable(binary) == 1
    end
    if found then
      local handle = io.popen(binary .. " --version")
      local binary_version = handle:read "*a"
      handle:close()
      return true, binary_version
    end
  end
end

local function lualib_installed(lib_name)
  local res, _ = pcall(require, lib_name)
  return res
end

local M = {}

M.check = function()
  -- Required lua libs
  start(Msgstr("Checking for required plugins"))
  for _, plugin in ipairs(required_plugins) do
    if lualib_installed(plugin.lib) then
      ok(Msgstr("%s installed.", {plugin.lib}))
    else
      local lib_not_installed = Msgstr("%s not found.", { plugin.lib })
      if plugin.optional then
        warn(("%s %s"):format(lib_not_installed, plugin.info))
      else
        error(lib_not_installed)
      end
    end
  end

  -- external dependencies
  -- TODO: only perform checks if user has enabled dependency in their config
  start(Msgstr("Checking external dependencies"))

  for _, opt_dep in pairs(optional_dependencies) do
    for _, package in ipairs(opt_dep.package) do
      local installed, version = check_binary_installed(package)
      if not installed then
        local err_msg = Msgstr("%s: not found.", {package.name})
        if package.optional then
          warn(("%s %s"):format(err_msg, Msgstr("Install %s for extended capabilities", {package.url})))
        else
          error(
            ("%s %s"):format(
              err_msg,
              Msgstr("`%s` finder will not function without %s installed.", {opt_dep.finder_name, package.url})
            )
          )
        end
      else
        local eol = version:find "\n"
        local ver = eol and version:sub(0, eol - 1) or Msgstr("(unknown version)")
        ok(Msgstr("%s: found %s", { package.name, ver }))
      end
    end
  end

  -- Extensions
  start(Msgstr("===== Installed extensions ====="))

  local installed = {}
  for extension_name, _ in pairs(extension_info) do
    installed[#installed + 1] = extension_name
  end
  table.sort(installed)

  for _, installed_ext in ipairs(installed) do
    local extension_healthcheck = extension_module._health[installed_ext]

    start(Msgstr("Telescope Extension: `%s`", { installed_ext }))
    if extension_healthcheck then
      extension_healthcheck()
    else
      info(Msgstr("No healthcheck provided"))
    end
  end
end

return M
