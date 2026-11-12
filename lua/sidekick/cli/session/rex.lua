local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Rex: sidekick.cli.Session
---@field rex_session_id string
---@field rex_block_id string
local M = {}
M.__index = M
M.priority = 10
M.external = true

---@param args string[]
---@param opts? vim.SystemOpts|{notify?:boolean}
function M.exec(args, opts)
  return Util.exec(vim.list_extend({ "rex", "--autostart=false" }, args), opts)
end

---@param args string[]
---@param notify? boolean
function M.json(args, notify)
  local _, stdout = M.exec(args, { notify = notify == true })
  local ok, data = pcall(vim.json.decode, stdout or "")
  return ok and type(data) == "table" and data or nil
end

function M:start()
  local session = assert(vim.env.REX_SESSION, "Rex backend requires REX_SESSION; start Neovim inside Rex")
  local cmd = {
    "run",
    "-s",
    session,
    "-c",
    self.cwd,
    "--shell=none",
    "--label",
    "sidekick:" .. self.tool.name,
    "--json",
    "--focus=false",
  }
  if Config.cli.mux.create == "split" then
    local block = assert(vim.env.REX_BLOCK, "Rex splits require REX_BLOCK")
    vim.list_extend(cmd, { "--split=" .. (Config.cli.mux.split.vertical and "right" or "below"), "-b", block })
    local size = Config.cli.mux.split.size
    if size <= 1 then
      vim.list_extend(cmd, { "--ratio", tostring(math.max(1, math.min(99, math.floor(size * 100)))) })
    end
  end
  if Config.cli.mux.create == "terminal" then
    Util.warn('Rex uses a native tab for `cli.mux.create = "terminal"`; use `window` or `split`')
  end
  cmd[#cmd + 1] = "--"
  local keys = vim.tbl_keys(self.tool.env or {})
  table.sort(keys)
  if #keys > 0 then
    cmd[#cmd + 1] = "env"
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
  end
  vim.list_extend(cmd, self.tool.cmd)
  local data = M.json(cmd, true)
  local block = data and type(data.block_ids) == "table" and data.block_ids[1]
  assert(type(block) == "string", "Failed to start Rex terminal")
  self.rex_session_id, self.rex_block_id = session, block
  self.id = "rex " .. session .. " " .. block
  self.mux_session = session
  self.started = true
end

function M:attach()
  M.exec({ "focus", "-s", self.rex_session_id, self.rex_block_id })
end

function M:is_running()
  local data = M.json({ "block", "call", "-s", self.rex_session_id, "-b", self.rex_block_id, "process" })
  return data ~= nil and type(data.child) == "table" and data.child.pid ~= nil
end

function M.sessions()
  local session = vim.env.REX_SESSION
  if not session then
    return {}
  end
  local data = M.json({ "block", "ls", "-s", session, "--json" })
  local ret = {} ---@type sidekick.cli.session.State[]
  local procs = require("sidekick.cli.procs").new()
  for _, block in ipairs(data and type(data.blocks) == "table" and data.blocks or {}) do
    if type(block) == "table" and type(block.block_id) == "string" then
      local proc = M.json({ "block", "call", "-s", session, "-b", block.block_id, "process" })
      local fg = proc and proc.foreground
      if proc and type(proc.child) == "table" and type(fg) == "table" then
        for name, tool in pairs(Config.tools()) do
          local cmd = table.concat({ fg.name or "", fg.path or "", fg.argv0 or "" }, " ")
          if
            block.label == "sidekick:" .. name
            or tool:is_proc(procs:get(fg.pid) or { pid = fg.pid, ppid = 0, cmd = cmd })
          then
            ret[#ret + 1] = {
              id = "rex " .. session .. " " .. block.block_id,
              tool = name,
              cwd = fg.cwd or "",
              rex_session_id = session,
              rex_block_id = block.block_id,
              mux_session = session,
              pids = fg.pid and { fg.pid } or nil,
            }
            break
          end
        end
      end
    end
  end
  return ret
end

function M:send(text)
  local data = M.json({ "block", "call", "-s", self.rex_session_id, "-b", self.rex_block_id, "modes" })
  assert(data, "Failed to read Rex terminal modes")
  for _, mode in ipairs(type(data.modes) == "table" and data.modes or {}) do
    if mode.number == 2004 and mode.set then
      text = "\27[200~" .. text .. "\27[201~"
      break
    end
  end
  M.exec({ "send", "-s", self.rex_session_id, "-b", self.rex_block_id }, { stdin = text })
end

function M:submit()
  M.exec({ "send-key", "-s", self.rex_session_id, "-b", self.rex_block_id, "enter" })
end

function M:dump()
  local _, text = M.exec({ "capture", "-s", self.rex_session_id, "-b", self.rex_block_id, "--format=vt", "--trim" })
  if text then
    local lines = vim.split(text, "\n")
    return table.concat(vim.list_slice(lines, math.max(1, #lines - Config.cli.mux.dump + 1)), "\n")
  end
end

return M
