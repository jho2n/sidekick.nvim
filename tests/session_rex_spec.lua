---@module 'luassert'

local Config = require("sidekick.config")
local Rex = require("sidekick.cli.session.rex")
local Util = require("sidekick.util")

describe("rex session backend", function()
  local exec, mux, env, calls

  before_each(function()
    exec, mux = Util.exec, vim.deepcopy(Config.cli.mux)
    env = { vim.env.REX_SESSION, vim.env.REX_BLOCK }
    vim.env.REX_SESSION, vim.env.REX_BLOCK = "session:1", "block:editor"
    calls = {}
    Util.exec = function(cmd, opts)
      calls[#calls + 1] = { cmd = cmd, stdin = opts and opts.stdin }
      local data = { block_ids = { "block:new", "block:editor" }, window_id = "window:1" }
      return {}, vim.json.encode(data)
    end
  end)

  after_each(function()
    Util.exec, Config.cli.mux = exec, mux
    vim.env.REX_SESSION, vim.env.REX_BLOCK = env[1], env[2]
  end)

  it("creates a split beside the editor with literal arguments and environment", function()
    Config.cli.mux.create = "split"
    Config.cli.mux.split = { vertical = false, size = 0.3 }
    local session = setmetatable({
      cwd = "/tmp/my project",
      tool = { name = "codex", cmd = { "codex", "a; $(literal)" }, env = { KEEP = "a b", REMOVE = false } },
    }, Rex)
    session:start()
    assert.are.same({
      "rex",
      "--autostart=false",
      "run",
      "-s",
      "session:1",
      "-c",
      "/tmp/my project",
      "--shell=none",
      "--label",
      "sidekick:codex",
      "--json",
      "--focus=false",
      "--split=below",
      "-b",
      "block:editor",
      "--ratio",
      "30",
      "--",
      "env",
      "-u",
      "REMOVE",
      "KEEP=a b",
      "codex",
      "a; $(literal)",
    }, calls[1].cmd)
    assert.are.equal("rex session:1 block:new", session.id)
    assert.is_true(session.started)
  end)

  it("does not record failed launches or target an unspecified session", function()
    local session = setmetatable({ cwd = "/tmp", tool = { name = "codex", cmd = { "codex" } } }, Rex)
    Util.exec = function()
      return nil
    end
    assert.has_error(function()
      session:start()
    end)
    assert.is_nil(session.started)
    vim.env.REX_SESSION = nil
    assert.has_error(function()
      session:start()
    end)
  end)

  it("discovers live AI processes in the current Rex session", function()
    Util.exec = function(cmd)
      local data
      if vim.tbl_contains(cmd, "ls") then
        data = { blocks = { { block_id = "block:agent" }, { block_id = "block:shell" } } }
      elseif vim.tbl_contains(cmd, "block:agent") then
        data = { child = { pid = 101 }, foreground = { pid = 102, name = "codex", cwd = "/tmp/project" } }
      else
        data = { child = { pid = 201 }, foreground = { pid = 201, name = "zsh", cwd = "/tmp" } }
      end
      return {}, vim.json.encode(data)
    end
    local sessions = Rex.sessions()
    assert.are.equal(1, #sessions)
    assert.are.equal("codex", sessions[1].tool)
    assert.are.equal("/tmp/project", sessions[1].cwd)
    assert.are.equal("session:1", sessions[1].rex_session_id)
  end)

  it("preserves multiline text without submitting and scopes every operation", function()
    local session = setmetatable({ rex_session_id = "session:1", rex_block_id = "block:agent" }, Rex)
    session:send("\237\149\156\234\184\128\n'quoted'\n")
    session:submit()
    session:attach()
    assert.are.same({
      { cmd = { "rex", "--autostart=false", "block", "call", "-s", "session:1", "-b", "block:agent", "modes" } },
      {
        cmd = { "rex", "--autostart=false", "send", "-s", "session:1", "-b", "block:agent" },
        stdin = "\237\149\156\234\184\128\n'quoted'\n",
      },
      { cmd = { "rex", "--autostart=false", "send-key", "-s", "session:1", "-b", "block:agent", "enter" } },
      { cmd = { "rex", "--autostart=false", "focus", "-s", "session:1", "block:agent" } },
    }, calls)
  end)

  it("rejects invalid JSON and reports exited processes as stopped", function()
    Util.exec = function()
      return {}, "invalid"
    end
    assert.are.same({}, Rex.sessions())
    local session = setmetatable({ rex_session_id = "session:1", rex_block_id = "block:agent" }, Rex)
    assert.is_false(session:is_running())
    Util.exec = function()
      return {}, '{"child":null,"last_exit":{"code":0}}'
    end
    assert.is_false(session:is_running())
  end)

  it("limits captured scrollback", function()
    Config.cli.mux.dump = 2
    Util.exec = function()
      return {}, "one\ntwo\nthree"
    end
    local session = setmetatable({ rex_session_id = "session:1", rex_block_id = "block:agent" }, Rex)
    assert.are.equal("two\nthree", session:dump())
  end)

  it("brackets pasted context when the program enables bracketed paste", function()
    Util.exec = function(cmd, opts)
      if opts and opts.stdin then
        assert.are.equal("\27[200~a\nb\27[201~", opts.stdin)
      end
      return {}, vim.json.encode({ modes = { { number = 2004, set = true } } })
    end
    local session = setmetatable({ rex_session_id = "session:1", rex_block_id = "block:agent" }, Rex)
    session:send("a\nb")
  end)

  it("identifies interpreter-based tools from the full process command", function()
    local Procs = require("sidekick.cli.procs")
    local new = Procs.new
    local ok, err = pcall(function()
      Procs.new = function()
        return {
          get = function()
            return { pid = 102, ppid = 101, cmd = "node /opt/bin/codex", cwd = "/tmp/project" }
          end,
        }
      end
      Util.exec = function(cmd)
        if vim.tbl_contains(cmd, "ls") then
          return {}, '{"blocks":[{"block_id":"block:node"}]}'
        end
        return {}, '{"child":{"pid":101},"foreground":{"pid":102,"name":"node","cwd":"/tmp/project"}}'
      end
      local sessions = Rex.sessions()
      assert.are.equal(1, #sessions)
      assert.are.equal("codex", sessions[1].tool)
    end)
    Procs.new = new
    assert(ok, err)
  end)

  it("rediscovers custom tools started by Sidekick without an is_proc matcher", function()
    local tools = Config.cli.tools
    Config.cli.tools = { custom = { cmd = { "custom-ai" } } }
    local ok, err = pcall(function()
      Util.exec = function(cmd)
        if vim.tbl_contains(cmd, "ls") then
          return {}, '{"blocks":[{"block_id":"block:custom","label":"sidekick:custom"}]}'
        end
        return {}, '{"child":{"pid":101},"foreground":{"pid":102,"name":"custom-ai"}}'
      end
      local sessions = Rex.sessions()
      assert.are.equal(1, #sessions)
      assert.are.equal("custom", sessions[1].tool)
    end)
    Config.cli.tools = tools
    assert(ok, err)
  end)

  it("focuses an attached external session through CLI focus and toggle", function()
    local State = require("sidekick.cli.state")
    local with = State.with
    local count = 0
    local ok, err = pcall(function()
      State.with = function(cb)
        cb({ session = {
          attach = function()
            count = count + 1
          end,
        } }, false)
      end
      require("sidekick.cli").focus()
      require("sidekick.cli").toggle()
      assert.are.equal(2, count)
    end)
    State.with = with
    assert(ok, err)
  end)
end)
