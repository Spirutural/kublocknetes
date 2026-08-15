--[[ kublocknetes :: dropbox service (OpenOS rc.d)

     Autostarts the filesystem command channel at boot.

       rc kbxdropbox start
       rc kbxdropbox enable

     Worth enabling on every machine that matters: it is the one channel
     that keeps working when the network does not, since it needs no modem,
     no card and no other machine to be alive.
]]

local filesystem = require("filesystem")
local computer   = require("computer")
local dropbox    = require("dropbox")
local shellexec  = require("shellexec")
local thread     = require("thread")

local DIR      = "/home/dropbox"
local INTERVAL = 1

local worker
local agent

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
      if not name:match("/$") then names[#names + 1] = name end
    end
    return names
  end,
}

function start()
  if worker then
    print("kbxdropbox: already running")
    return
  end

  agent = dropbox.new({
    fs   = fs,
    exec = shellexec,
    dir  = DIR,
  }):setup()

  worker = thread.create(function() agent:run(os.sleep, INTERVAL) end)
  worker:detach()

  print(string.format("kbxdropbox: watching %s/in (free %d bytes)",
    DIR, computer.freeMemory()))
end

function stop()
  if not worker then
    print("kbxdropbox: not running")
    return
  end
  worker:kill()
  worker = nil
  agent = nil
  print("kbxdropbox: stopped")
end

function status()
  if worker and agent then
    print(string.format("kbxdropbox: running, %d done / %d failed / %d skipped",
      agent.stats.done, agent.stats.failed, agent.stats.skipped))
  else
    print("kbxdropbox: stopped")
  end
end
