---@module 'luassert'

local Cmux = require("sidekick.cli.session.cmux")
local Util = require("sidekick.util")

describe("cmux session backend", function()
  local original_exec

  before_each(function()
    original_exec = Util.exec
  end)

  after_each(function()
    Util.exec = original_exec
  end)

  it("parses surface id from command output", function()
    assert.are.equal("surface:4", Cmux.parse_surface("OK surface=surface:4 pane=pane:1 workspace=workspace:1"))
    assert.is_nil(Cmux.parse_surface("OK"))
  end)

  it("parses cmux surfaces", function()
    Util.exec = function()
      local json = vim.json.encode({
        surfaces = {
          { ref = "surface:1", id = "uuid-1", type = "terminal", title = "~/project", focused = true },
          { ref = "surface:2", id = "uuid-2", type = "browser", focused = false },
        },
      })
      return vim.split(json, "\n"), json
    end

    assert.are.same({
      { id = "surface:1", uuid = "uuid-1", type = "terminal", title = "~/project", focused = true },
      { id = "surface:2", uuid = "uuid-2", type = "browser", title = nil, focused = false },
    }, Cmux.surfaces())
  end)

  it("builds a shell bootstrap command", function()
    local session = setmetatable({
      cwd = "/tmp/my project",
      tool = {
        cmd = { "claude", "--dangerously-skip-permissions" },
        env = { FOO = "bar baz", REMOVE_ME = false },
      },
    }, Cmux)

    assert.are.equal(
      "cd '/tmp/my project' && exec env -u 'REMOVE_ME' 'FOO=bar baz' 'claude' '--dangerously-skip-permissions'\n",
      session:bootstrap_cmd()
    )
  end)

  it("sends text and submit key to a specific surface", function()
    local calls = {}
    Util.exec = function(cmd, opts)
      calls[#calls + 1] = { cmd = cmd, stdin = opts and opts.stdin }
      return {}, ""
    end

    local session = setmetatable({ cmux_surface_id = "surface:7" }, Cmux)
    session:send("hello\n")
    session:submit()

    assert.are.same({
      {
        cmd = { "cmux", "send-surface", "--surface", "surface:7", "hello\n" },
        stdin = nil,
      },
      {
        cmd = { "cmux", "send-key-surface", "--surface", "surface:7", "enter" },
        stdin = nil,
      },
    }, calls)
  end)
end)
