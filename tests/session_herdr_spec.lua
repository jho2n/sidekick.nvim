---@module 'luassert'

local Config = require("sidekick.config")
local Herdr = require("sidekick.cli.session.herdr")
local Util = require("sidekick.util")

describe("herdr session backend", function()
  local exec, create

  before_each(function()
    exec, create = Util.exec, Config.cli.mux.create
  end)

  after_each(function()
    Util.exec, Config.cli.mux.create = exec, create
  end)

  it("starts a persistent core terminal with exact argv and environment", function()
    local calls = {}
    Util.exec = function(cmd)
      calls[#calls + 1] = cmd
      return {}, '{"address":"t42","state":"live"}'
    end
    local tool = { name = "codex", cmd = { "codex", "resume", "a; $(literal)" }, env = { A = "a b", B = false } }
    local session = setmetatable({ cwd = "/tmp/my project", tool = tool }, Herdr)
    assert.are.same({ cmd = { "hc", "attach", "t42" } }, session:start())
    assert.are.same({
      "hc",
      "run",
      "--json",
      "--bg",
      "--no-parent",
      "--no-notify",
      "--cwd",
      "/tmp/my project",
      "--label",
      "sidekick.tool=codex",
      "--",
      "env",
      "-u",
      "B",
      "A=a b",
      "codex",
      "--no-daemon",
      "resume",
      "a; $(literal)",
    }, calls[1])
    assert.are.same({ "codex", "resume", "a; $(literal)" }, tool.cmd)
    assert.is_true(session.started)
  end)

  it("does not mark a failed launch as started", function()
    Util.exec = function()
      return nil
    end
    local session = setmetatable({ cwd = "/tmp", tool = { name = "claude", cmd = { "claude" } } }, Herdr)
    assert.has_error(function()
      session:start()
    end)
    assert.is_nil(session.started)
  end)

  it("discovers local running AI processes and ignores shells, remote and finished terminals", function()
    Util.exec = function(cmd)
      local data
      if cmd[2] == "ls" then
        data = { terminals = { { address = "t1" }, { address = "t2" }, { address = "t3" }, { address = "remote/t4" } } }
      elseif cmd[3] == "t1" then
        data = {
          address = "t1",
          state = "live",
          pid = 101,
          cwd = "/old",
          argv = { "env", "codex" },
          foreground = { pid = 102, argv = { "codex" }, cwd = "/tmp/project" },
        }
      elseif cmd[3] == "t2" then
        data = { address = "t2", state = "live", pid = 201, argv = { "zsh" } }
      elseif cmd[3] == "t3" then
        data = { address = "t3", state = "finished", argv = { "claude" } }
      else
        data = {}
      end
      return {}, vim.json.encode(data)
    end
    local sessions = Herdr.sessions()
    assert.are.equal(1, #sessions)
    assert.are.equal("codex", sessions[1].tool)
    assert.are.equal("/tmp/project", sessions[1].cwd)
    assert.are.equal("t1", sessions[1].herdr_terminal_id)
    assert.are.same({ 101, 102 }, sessions[1].pids)
  end)

  it("uses attach for input so paste and submit remain separate", function()
    local session = setmetatable({ herdr_terminal_id = "t42" }, Herdr)
    assert.are.same({ cmd = { "hc", "attach", "t42" } }, session:attach())
    assert.is_false(Herdr.external)
  end)

  it("handles unavailable cores, malformed JSON and exited terminals", function()
    local session = setmetatable({ herdr_terminal_id = "t42" }, Herdr)
    Util.exec = function()
      return nil
    end
    assert.are.same({}, Herdr.sessions())
    assert.is_false(session:is_running())
    Util.exec = function()
      return {}, "invalid"
    end
    assert.are.same({}, Herdr.sessions())
    Util.exec = function()
      return {}, '{"state":"finished"}'
    end
    assert.is_false(session:is_running())
  end)

  it("captures scrollback using the configured history limit", function()
    Util.exec = function(cmd)
      assert.are.same({ "hc", "read", "t42", "--lines", tostring(Config.cli.mux.dump) }, cmd)
      return { "history", "screen" }, "history\nscreen"
    end
    local session = setmetatable({ herdr_terminal_id = "t42" }, Herdr)
    assert.are.equal("history\nscreen", session:dump())
  end)

  it("rediscovers a custom tool started by Sidekick without an is_proc matcher", function()
    local tools = Config.cli.tools
    Config.cli.tools = { custom = { cmd = { "custom-ai" } } }
    local ok, err = pcall(function()
      Util.exec = function(cmd)
        local data = cmd[2] == "ls" and { terminals = { { address = "t1" } } }
          or { state = "live", pid = 101, argv = { "custom-ai" }, labels = { ["sidekick.tool"] = "custom" } }
        return {}, vim.json.encode(data)
      end
      local sessions = Herdr.sessions()
      assert.are.equal(1, #sessions)
      assert.are.equal("custom", sessions[1].tool)
    end)
    Config.cli.tools = tools
    assert(ok, err)
  end)
end)
