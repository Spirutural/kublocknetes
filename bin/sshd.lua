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
-- Captures stdout by way of the shell's own redirection, which is the part
-- we can rely on. stderr is captured by swapping io.stderr for the duration;
-- programs that cached a reference to the original stream at load time will
-- still leak to the local screen. Good enough to read logs with.

local function execute(cmd)
  local outPath = "/tmp/.sshd-out"
  local errPath = "/tmp/.sshd-err"

  local errFile = io.open(errPath, "w")
  local savedStderr = io.stderr
  if errFile then io.stderr = errFile end

  local ok, reason = pcall(shell.execute, cmd .. " > " .. outPath)

  io.stderr = savedStderr
  if errFile then errFile:close() end

  local parts = {}

  local f = io.open(outPath, "r")
  if f then
    parts[#parts + 1] = f:read("a") or ""
    f:close()
  end

  local e = io.open(errPath, "r")
  if e then
    local errText = e:read("a")
    e:close()
    if errText and #errText > 0 then parts[#parts + 1] = errText end
  end

  local code = 0
  if not ok then
    parts[#parts + 1] = "sshd: " .. tostring(reason)
    code = 1
  elseif reason == false then
    code = 1
  end

  return table.concat(parts), code
end

-- --------------------------------------------------------------- boot ----

local digest = makeDigest()

local t = transport.new({ port = PORT, timeout = 3, retries = 4 }):open()

local server = sshd.new({
  transport = t,
  executor  = execute,
  secret    = opts.secret,
  digest    = digest,
  maxOutput = tonumber(opts.maxoutput) or 32768,
}):install()

print(string.format("sshd on port %d, host %s", PORT, computer.address()))
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
