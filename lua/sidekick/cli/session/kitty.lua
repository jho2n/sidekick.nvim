local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Kitty: sidekick.cli.Session
---@field kitty_window_id string
---@field kitty_tab_id? string
---@field kitty_pid? number
local M = {}
M.__index = M
M.priority = 10
M.external = true

---@param args string[]
function M.cmd(args)
  local ret
  if vim.fn.executable("kitten") == 1 then
    ret = { "kitten", "@" }
  else
    ret = { "kitty", "+kitten", "@" }
  end
  vim.list_extend(ret, args)
  return ret
end

---@param args string[]
---@param opts? vim.SystemOpts|{notify?:boolean}
function M.exec(args, opts)
  return Util.exec(M.cmd(args), opts)
end

function M:init()
  self.external = true
  self.priority = 10
end

---@return "window"|"split"
function M.create_mode()
  if Config.cli.mux.create ~= "terminal" then
    return Config.cli.mux.create
  end
  Util.warn({
    "Kitty does not support `opts.cli.mux.create = \"terminal\"`.",
    "Falling back to `window`.",
    "Please update your config.",
  })
  return "window"
end

---@return string[]
function M:add_cmd(ret)
  for key, value in pairs(self.tool.env or {}) do
    if value == false then
      vim.list_extend(ret, { "--env", key }) -- unset
    else
      vim.list_extend(ret, { "--env", ("%s=%s"):format(key, tostring(value)) })
    end
  end
  vim.list_extend(ret, self.tool.cmd)
  return ret
end

function M:start()
  local mode = M.create_mode()
  local cmd = { "launch", "--cwd", self.cwd, "--title", self.tool.name }

  if mode == "window" then
    vim.list_extend(cmd, { "--type", "tab", "--tab-title", self.tool.name })
  else
    vim.list_extend(cmd, {
      "--type",
      "window",
      "--location",
      Config.cli.mux.split.vertical and "vsplit" or "hsplit",
    })
  end

  self:add_cmd(cmd)
  local lines = M.exec(cmd, { notify = true })
  local window_id = lines and lines[1]
  if not window_id or window_id == "" then
    return
  end

  self.id = "kitty " .. window_id
  self.kitty_window_id = window_id
  self.mux_session = window_id
  self.started = true

  vim.wait(1000, function()
    local window = M.window(window_id)
    if window then
      self.kitty_pid = window.pid
      self.kitty_tab_id = window.tab_id
      self.mux_session = window.tab_id or window_id
      self.cwd = window.cwd or self.cwd
      self.pids = window.pid and require("sidekick.cli.procs").pids(window.pid) or nil
      return true
    end
  end, 50)

  Util.info(("Started **%s** in a new kitty %s"):format(
    self.tool.name,
    mode == "window" and "tab" or "split"
  ))
end

function M:attach()
  if self.kitty_window_id then
    M.exec({ "focus-window", "--match", "id:" .. self.kitty_window_id }, { notify = false })
  end
end

function M:is_running()
  return self.kitty_window_id and M.window(self.kitty_window_id) ~= nil or false
end

---@class sidekick.kitty.Window
---@field id string
---@field tab_id? string
---@field pid? number
---@field cwd? string
---@field cmdline? string[]

---@return sidekick.kitty.Window[]
function M.windows()
  local _, stdout = M.exec({ "ls" }, { notify = false })
  if not stdout or stdout == "" then
    return {}
  end
  local ok, tree = pcall(vim.json.decode, stdout)
  if not ok or type(tree) ~= "table" then
    return {}
  end

  local ret = {} ---@type sidekick.kitty.Window[]
  for _, os_window in ipairs(tree) do
    for _, tab in ipairs(os_window.tabs or {}) do
      for _, window in ipairs(tab.windows or {}) do
        ret[#ret + 1] = {
          id = tostring(window.id),
          tab_id = tab.id and tostring(tab.id) or nil,
          pid = tonumber(window.pid),
          cwd = window.cwd,
          cmdline = window.cmdline,
        }
      end
    end
  end
  return ret
end

---@param id string|number
---@return sidekick.kitty.Window?
function M.window(id)
  id = tostring(id)
  for _, window in ipairs(M.windows()) do
    if window.id == id then
      return window
    end
  end
end

function M.sessions()
  local windows = M.windows()
  local ret = {} ---@type sidekick.cli.session.State[]
  local tools = Config.tools()
  local Procs = require("sidekick.cli.procs")
  local procs = Procs.new()

  for _, window in ipairs(windows) do
    if window.pid then
      procs:walk(window.pid, function(proc)
        for _, tool in pairs(tools) do
          local cmd = window.cmdline and table.concat(window.cmdline, " ") or proc.cmd
          if tool:is_proc(proc) or tool:is_proc({
            pid = window.pid,
            ppid = proc.ppid,
            cmd = cmd,
            cwd = window.cwd,
          }) then
            ret[#ret + 1] = {
              id = "kitty " .. window.id,
              cwd = proc.cwd or window.cwd or "",
              tool = tool,
              kitty_window_id = window.id,
              kitty_tab_id = window.tab_id,
              kitty_pid = window.pid,
              mux_session = window.tab_id or window.id,
              pids = Procs.pids(window.pid),
            }
            return true
          end
        end
      end)
    end
  end

  return ret
end

function M:send(text)
  if not self.kitty_window_id then
    return
  end
  M.exec({
    "send-text",
    "--match",
    "id:" .. self.kitty_window_id,
    "--stdin",
    "--bracketed-paste=enable",
  }, { stdin = text, notify = false })
end

function M:submit()
  if not self.kitty_window_id then
    return
  end
  M.exec({ "send-key", "--match", "id:" .. self.kitty_window_id, "enter" }, { notify = false })
end

function M:dump()
  if not self.kitty_window_id then
    return
  end
  local _, ret = M.exec({
    "get-text",
    "--match",
    "id:" .. self.kitty_window_id,
    "--extent",
    "all",
    "--ansi",
  }, { notify = false })
  return ret
end

return M
