local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Cmux: sidekick.cli.Session
---@field cmux_surface_id string
local M = {}
M.__index = M
M.priority = 10
M.external = true

---@param args string[]
---@param opts? vim.SystemOpts|{notify?:boolean}
function M.exec(args, opts)
  local cmd = { "cmux" }
  vim.list_extend(cmd, args)
  return Util.exec(cmd, opts)
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
    "cmux does not support `opts.cli.mux.create = \"terminal\"`.",
    "Falling back to `window`.",
    "Please update your config.",
  })
  return "window"
end

---@param s string
function M.state_key(s)
  return "cmux-" .. s:gsub("[^%w%._-]", "_")
end

---@class sidekick.cmux.Surface
---@field id string
---@field uuid? string
---@field type? string
---@field title? string
---@field focused? boolean

---@return sidekick.cmux.Surface[]
function M.surfaces()
  local _, stdout = M.exec({ "list-surfaces", "--json", "--id-format", "both" }, { notify = false })
  if not stdout or stdout == "" then
    _, stdout = M.exec({ "list-panels", "--json", "--id-format", "both" }, { notify = false })
  end
  if not stdout or stdout == "" then
    return {}
  end

  local ok, data = pcall(vim.json.decode, stdout)
  if not ok or type(data) ~= "table" then
    return {}
  end

  local ret = {} ---@type sidekick.cmux.Surface[]
  for _, surface in ipairs(data.surfaces or {}) do
    local id = surface.ref or surface.id
    if id then
      ret[#ret + 1] = {
        id = tostring(id),
        uuid = surface.ref and surface.id or nil,
        type = surface.type,
        title = surface.title,
        focused = surface.focused == true,
      }
    end
  end
  return ret
end

---@param id string
---@return sidekick.cmux.Surface?
function M.surface(id)
  for _, surface in ipairs(M.surfaces()) do
    if surface.id == id or surface.uuid == id then
      return surface
    end
  end
end

---@return sidekick.cmux.Surface?
function M.focused_surface()
  for _, surface in ipairs(M.surfaces()) do
    if surface.focused then
      return surface
    end
  end
end

---@param output string?
---@return string?
function M.parse_surface(output)
  return output and output:match("surface=([^%s]+)") or nil
end

---@param argv string[]
function M.shell_join(argv)
  return table.concat(vim.tbl_map(vim.fn.shellescape, argv), " ")
end

function M:bootstrap_cmd()
  local parts = { "cd", vim.fn.shellescape(self.cwd), "&&", "exec" }
  local env = {}
  local unsets, sets = {}, {}
  for key, value in pairs(self.tool.env or {}) do
    if value == false then
      unsets[#unsets + 1] = key
    else
      sets[#sets + 1] = key
    end
  end
  table.sort(unsets)
  table.sort(sets)
  for _, key in ipairs(unsets) do
    vim.list_extend(env, { "-u", vim.fn.shellescape(key) })
  end
  for _, key in ipairs(sets) do
    env[#env + 1] = vim.fn.shellescape(("%s=%s"):format(key, tostring(self.tool.env[key])))
  end
  if #env > 0 then
    parts[#parts + 1] = "env"
    vim.list_extend(parts, env)
  end
  parts[#parts + 1] = M.shell_join(self.tool.cmd)
  return table.concat(parts, " ") .. "\n"
end

function M:start()
  local mode = M.create_mode()
  local args
  if mode == "window" then
    args = { "new-surface", "--type", "terminal" }
  else
    args = { "new-split", Config.cli.mux.split.vertical and "right" or "down" }
  end

  local _, stdout = M.exec(args, { notify = true })
  local surface_id = M.parse_surface(stdout)
  if not surface_id then
    vim.wait(1000, function()
      local surface = M.focused_surface()
      surface_id = surface and surface.id or nil
      return surface_id ~= nil
    end, 50)
  end
  if not surface_id then
    return
  end

  self.id = "cmux " .. surface_id
  self.cmux_surface_id = surface_id
  self.mux_session = surface_id
  self.started = true
  self.pids = nil

  Util.set_state(M.state_key(surface_id), {
    tool = self.tool.name,
    cwd = self.cwd,
    surface = surface_id,
  })

  vim.wait(500, function()
    return M.surface(surface_id) ~= nil
  end, 50)
  self:send(self:bootstrap_cmd())

  Util.info(("Started **%s** in a new cmux %s"):format(
    self.tool.name,
    mode == "window" and "surface" or "split"
  ))
end

function M:attach()
  if self.cmux_surface_id then
    M.exec({ "focus-surface", "--surface", self.cmux_surface_id }, { notify = false })
  end
end

function M:is_running()
  return self.cmux_surface_id and M.surface(self.cmux_surface_id) ~= nil or false
end

function M.sessions()
  local ret = {} ---@type sidekick.cli.session.State[]
  for _, surface in ipairs(M.surfaces()) do
    if surface.type == nil or surface.type == "terminal" then
      local state = Util.get_state(M.state_key(surface.id))
      if state and state.tool and state.cwd then
        ret[#ret + 1] = {
          id = "cmux " .. surface.id,
          cwd = state.cwd,
          tool = state.tool,
          cmux_surface_id = surface.id,
          mux_session = surface.id,
        }
      end
    end
  end
  return ret
end

function M:send(text)
  if not self.cmux_surface_id then
    return
  end
  M.exec({ "send-surface", "--surface", self.cmux_surface_id, text }, { notify = false })
end

function M:submit()
  if not self.cmux_surface_id then
    return
  end
  M.exec({ "send-key-surface", "--surface", self.cmux_surface_id, "enter" }, { notify = false })
end

return M
