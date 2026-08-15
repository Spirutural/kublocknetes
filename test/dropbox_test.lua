local T       = require("test.init")
local dropbox = require("dropbox")

T.describe("dropbox :: job handling")

--- An in-memory stand-in for the OC filesystem.
local function fakeFs()
  local files, dirs = {}, {}
  return {
    _files = files,
    _dirs  = dirs,
    exists  = function(p) return files[p] ~= nil or dirs[p] == true end,
    makeDir = function(p) dirs[p] = true end,
    write   = function(p, data) files[p] = data end,
    read    = function(p) return files[p] end,
    remove  = function(p) files[p] = nil end,
    rename  = function(a, b) files[b] = files[a]; files[a] = nil end,
    list    = function(dir)
      local out = {}
      for path in pairs(files) do
        local name = path:match("^" .. dir:gsub("%-", "%%-") .. "/(.+)$")
        if name and not name:find("/") then out[#out + 1] = name end
      end
      table.sort(out)
      return out
    end,
  }
end

local function newAgent(exec, opts)
  local fs = fakeFs()
  local agent = dropbox.new({
    fs   = fs,
    exec = exec or function(cmd) return "ran: " .. cmd, 0 end,
    dir  = "/d",
    maxOutput = opts and opts.maxOutput,
  }):setup()
  return agent, fs
end

T.test("runs a job and writes the result", function()
  local agent, fs = newAgent()
  fs.write("/d/in/001", "ls /usr")

  local job = agent:poll()

  T.eq(job, "001", "handled the job")
  T.eq(fs._files["/d/out/001"], "exit:0\nran: ls /usr", "result written")
  T.nilish(fs._files["/d/in/001"], "input consumed")
end)

T.test("idle poll does nothing and reports nothing", function()
  local agent = newAgent()
  T.nilish(agent:poll(), "no job")
end)

T.test("processes exactly one job per poll", function()
  local agent, fs = newAgent()
  fs.write("/d/in/001", "first")
  fs.write("/d/in/002", "second")
  fs.write("/d/in/003", "third")

  T.eq(agent:poll(), "001", "lowest name first")
  T.ok(fs._files["/d/in/002"], "second still pending")
  T.ok(fs._files["/d/in/003"], "third still pending")

  T.eq(agent:poll(), "002")
  T.eq(agent:poll(), "003")
  T.nilish(agent:poll(), "drained")
end)

T.test("ignores partial writes still being uploaded", function()
  local agent, fs = newAgent()
  fs.write("/d/in/001.part", "half a command")

  T.nilish(agent:poll(), "must not read a .part file")
  T.ok(fs._files["/d/in/001.part"], "and must not consume it")
end)

T.test("results appear atomically, never half-written", function()
  local agent, fs = newAgent()
  fs.write("/d/in/001", "whatever")
  agent:poll()

  T.nilish(fs._files["/d/out/001.part"], "no leftover partial")
  T.ok(fs._files["/d/out/001"], "final result present")
end)

T.test("exit codes are carried in the result header", function()
  local agent, fs = newAgent(function() return "nope", 3 end)
  fs.write("/d/in/001", "failing-command")
  agent:poll()
  T.eq(fs._files["/d/out/001"], "exit:3\nnope")
end)

T.test("a crashing command produces a result, not a dead agent", function()
  local agent, fs = newAgent(function() error("executor exploded") end)
  fs.write("/d/in/001", "boom")

  local job = agent:poll()

  T.eq(job, "001", "still reported as handled")
  T.ok(fs._files["/d/out/001"]:find("exploded"), "error surfaced to the host")
  T.ok(fs._files["/d/out/001"]:find("exit:1"), "non-zero exit")
end)

T.test("empty jobs are answered rather than silently dropped", function()
  local agent, fs = newAgent()
  fs.write("/d/in/001", "   \n  ")
  agent:poll()
  T.ok(fs._files["/d/out/001"]:find("empty"), "explains itself")
end)

T.test("output is truncated to the ceiling", function()
  local agent, fs = newAgent(
    function() return string.rep("X", 100000), 0 end,
    { maxOutput = 1024 })
  fs.write("/d/in/001", "huge")
  agent:poll()

  local result = fs._files["/d/out/001"]
  T.ok(#result < 1200, "capped, got " .. #result .. " bytes")
  T.ok(result:find("truncated"), "says so")
end)

T.describe("dropbox :: memory discipline")

T.test("a job is consumed before it runs, so it cannot be replayed forever", function()
  -- If the executor dies hard mid-job, the input must already be gone.
  -- At-most-once beats a poison job that crashes the agent on every boot.
  local seen = {}
  local agent, fs = newAgent(function(cmd)
    seen[#seen + 1] = cmd
    T.nilish(fs._files["/d/in/001"], "input already removed before exec ran")
    return "ok", 0
  end)

  fs.write("/d/in/001", "dangerous")
  agent:poll()
  T.eq(#seen, 1, "ran once")
end)

T.test("agent state stays flat across many jobs", function()
  -- The failure that killed occlaude: a growing in-memory array. Nothing
  -- here may accumulate per job.
  local agent, fs = newAgent()

  local function agentFieldCount()
    local n = 0
    for _ in pairs(agent) do n = n + 1 end
    return n
  end

  fs.write("/d/in/000", "warmup")
  agent:poll()
  local baseline = agentFieldCount()

  for i = 1, 200 do
    fs.write("/d/in/" .. string.format("%03d", i), "command " .. i)
    agent:poll()
  end

  T.eq(agentFieldCount(), baseline,
    "no new fields after 200 jobs -- nothing is accumulating")
  T.eq(agent.stats.done, 201, "all jobs ran")

  -- Results do pile up on disk, which is fine: that is the host's problem,
  -- and disk is 4MB rather than 1.5MB of RAM.
  T.eq(#fs.list("/d/out"), 201, "results are on disk, not in memory")
end)
