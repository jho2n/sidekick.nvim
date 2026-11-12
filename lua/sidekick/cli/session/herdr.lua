local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Herdr: sidekick.cli.Session
---@field herdr_terminal_id string
local M = {}
M.__index = M
M.priority = 50
M.external = false

---@param args string[]
---@param opts? vim.SystemOpts|{notify?:boolean}
function M.exec(args, opts)
  return Util.exec(vim.list_extend({ "hc" }, args), opts)
end

---@param args string[]
---@param notify? boolean
function M.json(args, notify)
  local _, stdout = M.exec(args, { notify = notify == true })
  local ok, data = pcall(vim.json.decode, stdout or "")
  return ok and type(data) == "table" and data or nil
end

function M:start()
  if Config.cli.mux.create ~= "terminal" then
    Util.warn('Herdr supports `cli.mux.create = "terminal"` only; falling back to an embedded terminal')
  end
  local cmd = {
    "run",
    "--json",
    "--bg",
    "--no-parent",
    "--no-notify",
    "--cwd",
    self.cwd,
    "--label",
    "sidekick.tool=" .. self.tool.name,
    "--",
    "env",
  }
  local keys = vim.tbl_keys(self.tool.env or {})
  table.sort(keys)
  for _, key in ipairs(keys) do
    if self.tool.env[key] == false then
      vim.list_extend(cmd, { "-u", key })
    end
  end
  for _, key in ipairs(keys) do
    if self.tool.env[key] ~= false then
      cmd[#cmd + 1] = key .. "=" .. tostring(self.tool.env[key])
    end
  end
  local argv = vim.deepcopy(self.tool.cmd)
  if
    self.tool.name == "codex"
    and vim.fs.basename(argv[1]) == "codex"
    and not vim.tbl_contains(argv, "--no-daemon")
  then
    -- The shared Codex daemon runs outside the core terminal.
    table.insert(argv, 2, "--no-daemon")
  end
  vim.list_extend(cmd, argv)
  local data = M.json(cmd, true)
  assert(data and type(data.address) == "string" and data.state == "live", "Failed to start Herdr terminal")
  self.herdr_terminal_id = data.address
  self.mux_session = data.address
  self.id = "herdr " .. data.address
  self.started = true
  return self:attach()
end

function M:attach()
  -- Reuse hc's terminal client to preserve paste-only input and keyboard modes.
  return { cmd = { "hc", "attach", self.herdr_terminal_id } }
end

function M:is_running()
  local data = M.json({ "get", self.herdr_terminal_id, "--json" })
  return data ~= nil and data.state == "live"
end

function M.sessions()
  -- Listing sessions must not start a core as a side effect.
  if not M.json({ "server", "status", "--json" }) then
    return {}
  end
  local data = M.json({ "ls", "--json" })
  local ret = {} ---@type sidekick.cli.session.State[]
  local Terminal = require("sidekick.cli.terminal")
  for _, entry in ipairs(data and type(data.terminals) == "table" and data.terminals or {}) do
    local address = type(entry) == "table" and entry.address
    if type(address) == "string" and not address:find("/", 1, true) then
      local term = M.json({ "get", address, "--json" })
      if term and term.state == "live" then
        local fg = type(term.foreground) == "table" and term.foreground or {}
        local argv = type(fg.argv) == "table" and fg.argv or type(term.argv) == "table" and term.argv or {}
        local proc = { pid = fg.pid or term.pid, ppid = 0, cmd = table.concat(argv, " ") }
        for name, tool in pairs(Config.tools()) do
          if (type(term.labels) == "table" and term.labels["sidekick.tool"] == name) or tool:is_proc(proc) then
            local pids = {} ---@type integer[]
            if term.pid then
              pids[#pids + 1] = term.pid
            end
            if fg.pid and fg.pid ~= term.pid then
              pids[#pids + 1] = fg.pid
            end
            for _, t in pairs(Terminal.terminals) do
              if t.mux_backend == "herdr" and t.mux_session == address then
                vim.list_extend(pids, t.pids or {})
              end
            end
            ret[#ret + 1] = {
              id = "herdr " .. address,
              tool = name,
              cwd = fg.cwd or term.cwd or "",
              herdr_terminal_id = address,
              mux_session = address,
              pids = pids,
            }
            break
          end
        end
      end
    end
  end
  return ret
end

function M:dump()
  local _, text = M.exec({ "read", self.herdr_terminal_id, "--lines", tostring(Config.cli.mux.dump) })
  return text
end

return M
