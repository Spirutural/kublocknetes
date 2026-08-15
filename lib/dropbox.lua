--[[ kublocknetes :: dropbox agent

     A command channel that needs no network at all.

     OpenComputers filesystems are real directories on the host disk, and a
     running server picks up files written from outside. So a job can be
     dropped into <dir>/in/ from the host, executed in-game, and its output
     read back from <dir>/out/. No internet card, no ports, no config change.

     MEMORY DISCIPLINE IS THE POINT.

     The predecessor to this, `occlaude`, died because it kept a growing
     messages array in a 1.5 MB machine. That is not a RAM shortage, it is
     state on the wrong side of the wire -- the host has gigabytes.

     So this agent:
       * processes exactly ONE job per poll, never a batch
       * deletes each job as it reads it
       * holds no history, no queue, no session
       * truncates output to a fixed ceiling
       * caps how large a job it will even read

     Its memory use is therefore flat and bounded regardless of how long it
     runs or how many jobs pass through it. Anything that needs to remember
     belongs on the host.

     Dependencies are injected so the whole loop is testable in the simulator
     with no OpenOS present. Real wiring lives in bin/dropbox.lua.
]]

local dropbox = {}

local D = {}
D.__index = D

--- opts.fs   table of { list, read, write, remove, exists, makeDir }
--  opts.exec function(cmd) -> output:string, exitCode:number
--  opts.dir  base directory, default "/home/dropbox"
function dropbox.new(opts)
  assert(opts and opts.fs, "dropbox: fs required")
  assert(opts.exec, "dropbox: exec required")

  local self = setmetatable({
    fs        = opts.fs,
    exec      = opts.exec,
    dir       = opts.dir or "/home/dropbox",
    maxOutput = opts.maxOutput or 16384,
    maxJob    = opts.maxJob or 4096,
    stats     = { done = 0, failed = 0, skipped = 0 },
  }, D)

  self.inDir  = self.dir .. "/in"
  self.outDir = self.dir .. "/out"

  return self
end

function D:setup()
  for _, d in ipairs({ self.dir, self.inDir, self.outDir }) do
    if not self.fs.exists(d) then self.fs.makeDir(d) end
  end
  return self
end

--- Lowest-named pending job, so ordering is stable and predictable.
--  Deliberately returns ONE name, never the list -- callers must not be able
--  to accumulate.
function D:_nextJob()
  local names = self.fs.list(self.inDir)
  if not names then return nil end

  local best
  for _, name in ipairs(names) do
    -- Ignore partials: the host writes to a temp name and renames into
    -- place, so anything still suffixed is mid-write.
    if not name:match("%.part$") and (not best or name < best) then
      best = name
    end
  end
  return best
end

--- Process at most one job. Returns the job id handled, or nil if idle.
function D:poll()
  local job = self:_nextJob()
  if not job then return nil end

  local inPath = self.inDir .. "/" .. job

  -- Read then immediately remove. If we die mid-command the job is gone
  -- rather than replayed forever -- at-most-once, which for a human-driven
  -- debug channel is the safer failure.
  local cmd = self.fs.read(inPath, self.maxJob)
  self.fs.remove(inPath)

  if type(cmd) ~= "string" or cmd:match("^%s*$") then
    self.stats.skipped = self.stats.skipped + 1
    self:_reply(job, "dropbox: empty or unreadable job\n", 1)
    return job
  end

  cmd = cmd:gsub("^%s+", ""):gsub("%s+$", "")

  local ok, out, code = pcall(self.exec, cmd)
  if not ok then
    self.stats.failed = self.stats.failed + 1
    self:_reply(job, "dropbox: " .. tostring(out) .. "\n", 1)
    return job
  end

  out = tostring(out or "")
  if #out > self.maxOutput then
    out = out:sub(1, self.maxOutput) .. "\n[truncated]\n"
  end

  self.stats.done = self.stats.done + 1
  self:_reply(job, out, code or 0)
  return job
end

--- Write the result atomically: a partial file must never be readable, or
--  the host will happily read half an answer and believe it.
function D:_reply(job, body, code)
  local final = self.outDir .. "/" .. job
  local temp  = final .. ".part"

  self.fs.write(temp, string.format("exit:%d\n%s", code, body))
  self.fs.rename(temp, final)
end

--- Poll forever. `sleep` is injected so tests need no real clock.
function D:run(sleep, interval)
  interval = interval or 1
  while true do
    -- Keep polling while there is work, so a burst drains promptly, but
    -- still one job at a time.
    if not self:poll() then
      sleep(interval)
    end
  end
end

return dropbox
