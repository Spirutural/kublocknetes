--[[ kublocknetes :: sshd service (OpenOS rc.d)

     Autostarts the remote shell daemon at boot, so a node comes back on its
     own after a chunk reload or a power cut -- which, given how often that
     happens, is the difference between a cluster and a chore.

       rc kbxsshd start
       rc kbxsshd enable        add to /etc/rc.cfg's enabled list

     The secret is read from /etc/kbx.secret rather than /etc/rc.cfg, so it
     is one file to lock down and it never appears in a process listing.
]]

local component = require("component")
local transport = require("transport")
local sshd      = require("sshd")
local naming    = require("naming")
local shellexec = require("shellexec")
local thread    = require("thread")

local worker
local server

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("l")
  f:close()
  if not line or line == "" then return nil end
  return line
end

local function hostname()
  return readFile("/etc/hostname")
end

local function makeDigest()
  if not component.isAvailable("data") then return nil end
  local data = component.getPrimary("data")
  if not data.sha256 then return nil end
  return function(s)
    local raw = data.sha256(s)
    return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
end

function start()
  if worker then
    print("kbxsshd: already running")
    return
  end

  local t = transport.new({ port = 22, timeout = 3, retries = 4 }):open()

  server = sshd.new({
    transport = t,
    executor  = shellexec,
    secret    = readFile("/etc/kbx.secret"),
    digest    = makeDigest(),
    hostname  = hostname,
  }):install()

  naming.serve(t, hostname)

  worker = thread.create(function() t:serve() end)
  worker:detach()

  print(string.format("kbxsshd: up as %s (auth: %s)",
    hostname() or "unnamed", server:mode()))
end

function stop()
  if not worker then
    print("kbxsshd: not running")
    return
  end
  worker:kill()
  worker = nil
  server = nil
  print("kbxsshd: stopped")
end

function status()
  if worker then
    print(string.format("kbxsshd: running as %s, %d execs, %d denied",
      hostname() or "unnamed",
      server and server.stats.execs or 0,
      server and server.stats.denied or 0))
  else
    print("kbxsshd: stopped")
  end
end
