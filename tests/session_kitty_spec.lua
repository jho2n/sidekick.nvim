---@module 'luassert'

local Kitty = require("sidekick.cli.session.kitty")
local Util = require("sidekick.util")

describe("kitty session backend", function()
  local original_exec
  local original_executable

  before_each(function()
    original_exec = Util.exec
    original_executable = vim.fn.executable
  end)

  after_each(function()
    Util.exec = original_exec
    vim.fn.executable = original_executable
  end)

  it("prefers kitten remote control command", function()
    vim.fn.executable = function(cmd)
      return cmd == "kitten" and 1 or 0
    end

    assert.are.same({ "kitten", "@", "ls" }, Kitty.cmd({ "ls" }))
  end)

  it("falls back to kitty +kitten remote control command", function()
    vim.fn.executable = function(cmd)
      return cmd == "kitty" and 1 or 0
    end

    assert.are.same({ "kitty", "+kitten", "@", "ls" }, Kitty.cmd({ "ls" }))
  end)

  it("parses kitty ls windows", function()
    vim.fn.executable = function()
      return 1
    end
    Util.exec = function()
      local json = vim.json.encode({
        {
          tabs = {
            {
              id = 7,
              windows = {
                { id = 42, pid = 1001, cwd = "/tmp/project", cmdline = { "claude" } },
              },
            },
          },
        },
      })
      return vim.split(json, "\n"), json
    end

    assert.are.same({
      {
        id = "42",
        tab_id = "7",
        pid = 1001,
        cwd = "/tmp/project",
        cmdline = { "claude" },
      },
    }, Kitty.windows())
  end)

  it("sends text and submit key to a matched kitty window", function()
    vim.fn.executable = function()
      return 1
    end
    local calls = {}
    Util.exec = function(cmd, opts)
      calls[#calls + 1] = { cmd = cmd, stdin = opts and opts.stdin }
      return {}, ""
    end

    local session = setmetatable({ kitty_window_id = "42" }, Kitty)
    session:send("hello\n")
    session:submit()

    assert.are.same({
      {
        cmd = {
          "kitten",
          "@",
          "send-text",
          "--match",
          "id:42",
          "--stdin",
          "--bracketed-paste=enable",
        },
        stdin = "hello\n",
      },
      {
        cmd = { "kitten", "@", "send-key", "--match", "id:42", "enter" },
        stdin = nil,
      },
    }, calls)
  end)
end)
