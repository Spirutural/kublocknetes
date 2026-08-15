--[[ kublocknetes :: dropbox agent (OpenOS)

     Polls <dir>/in/ for command files, runs them, writes results to
     <dir>/out/. Files arrive from the host by writing straight into the
     world save -- no internet card, no ports, no config change.

       dropbox                        background, /home/dropbox
       dropbox --fg                   foreground
       dropbox --dir /home/kbx        elsewhere
       dropbox --interval 2           poll every 2s

     Memory stays flat no matter how long it runs: one job at a time, no
     history, bounded output. See lib/dropbox.lua for why that matters.
]]

local filesystem = require("filesystem")
local computer   = require("computer")
local shell      = require("shell")

local dropbox   = require("dropbox")
local shellexec = require("shellexec")

local _, opts = shell.parse(...)

local DIR      = opts.dir or "/home/dropbox"
local INTERVAL = tonumber(opts.interval) or 1

local fs = {
  exists  = function(p) return filesystem.exists(p) end,
  makeDir = function(p) return filesystem.makeDirectory(p) end,
  remove  = function(p) return filesystem.remove(p) end,
  rename  = function(a, b) return filesystem.rename(a, b) end,

  write = function(path, data)
    local f, err = io.open(path, "w")
    if not f then return nil, err end
    f:write(data)
    f:close()
    return true
  end,

  read = function(path, max)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = f:read(max or "a")
    f:close()
    return data
  end,

  list = function(dir)
    local names = {}
    local ok, iter = pcall(filesystem.list, dir)
    if not ok or not iter then return names end
    for name in iter do
      -- OpenOS suffixes directories with "/"; we only want files.
      if not name:match("/$") then names[#names + 1] = name end
    end
    return names
  end,
}

local agent = dropbox.new({
  fs        = fs,
  exec      = shellexec,
  dir       = DIR,
  maxOutput = tonumber(opts.maxoutput) or 16384,
}):setup()

print(string.format("dropbox on %s", DIR))
print(string.format("host %s, polling every %ss", computer.address(), INTERVAL))
print(string.format("free memory %d bytes", computer.freeMemory()))

local function loop()
  agent:run(os.sleep, INTERVAL)
end

if opts.fg then
  loop()
else
  local thread = require("thread")
  local worker = thread.create(loop)
  worker:detach()
  print("backgrounded. this shell stays usable.")
end
