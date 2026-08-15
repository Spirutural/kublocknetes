--[[ kublocknetes :: sshd daemon (OpenOS)

     OpenOS glue around lib/sshd.lua: shell execution, Data Card digest, and
     backgrounding. All the protocol logic lives in the library, which is why
     none of OpenOS appears there.

       sshd --secret hunter2          background, authenticated
       sshd --secret hunter2 --fg     foreground (ctrl-c to stop)
       sshd                           NO AUTH -- anyone on the network

     A Data Card upgrades authentication to nonce/response automatically, so
     the secret never crosses the wire. Without one it is sent in the clear.
]]

local component = require("component")
local shell     = require("shell")
local computer  = require("computer")

local transport = require("transport")
local sshd      = require("sshd")
local naming    = require("naming")

-- --------------------------------------------------------- hostname ----
-- /etc/hostname is OpenOS's own convention, written by the stock `hostname`
-- program, so we inherit it rather than inventing a parallel one. Re-read
-- per call so `hostname foo` takes effect on a running daemon.

local function hostname()
  local f = io.open("/etc/hostname", "r")
  if not f then return nil end
  local name = f:read("l")
  f:close()
  if not name or name == "" then return nil end
  return name
end

local _, opts = shell.parse(...)

local PORT = tonumber(opts.port) or 22

-- ------------------------------------------------------------- digest ----
-- A Data Card gives us sha256, which turns plaintext auth into
-- challenge/response. Returns nil when no card is present, and lib/sshd
-- falls back to the weaker mode on its own.

local function makeDigest()
  if not component.isAvailable("data") then return nil end

  local data = component.getPrimary("data")
  if not data.sha256 then return nil end

  return function(s)
    local raw = data.sha256(s)
    return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
end

-- ----------------------------------------------------------- executor ----
-- Shared with the dropbox agent; lives in openos/ because it depends on
-- OpenOS's shell and would need rewriting for a custom node runtime.

local execute = require("shellexec")

-- --------------------------------------------------------------- boot ----

local digest = makeDigest()

local t = transport.new({ port = PORT, timeout = 3, retries = 4 }):open()

local server = sshd.new({
  transport = t,
  executor  = execute,
  secret    = opts.secret,
  digest    = digest,
  hostname  = hostname,
  maxOutput = tonumber(opts.maxoutput) or 32768,
}):install()

-- Answer "who is <name>" on the same port, so `ssh <name>` works without a
-- registry or a second daemon.
naming.serve(t, hostname)

print(string.format("sshd on port %d", PORT))
print(string.format("host %s  %s", computer.address(),
  hostname() and ("(" .. hostname() .. ")") or "(no hostname -- set one with: hostname <name>)"))
print(string.format("auth: %s%s", server:mode(),
  digest and "  (Data Card present)" or ""))

if server:mode() == "none" then
  print("WARNING: no secret set. Any machine on this network can run commands.")
elseif server:mode() == "secret" then
  print("WARNING: no Data Card. The secret is sent in the clear.")
end

if opts.fg then
  t:serve()
else
  local thread = require("thread")
  local worker = thread.create(function() t:serve() end)
  worker:detach()
  print("backgrounded. this shell stays usable.")
end
