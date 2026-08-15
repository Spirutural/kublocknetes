--[[ kublocknetes :: ssh client (OpenOS)

       ssh <address>                        interactive
       ssh <address> ls /usr/lib            one command
       ssh <address> --secret hunter2       authenticated

     The address is an OC component address; a unique prefix is enough.
]]

local component = require("component")
local shell     = require("shell")

local transport = require("transport")
local ssh       = require("ssh")
local naming    = require("naming")

local args, opts = shell.parse(...)

-- `ssh --list` takes no target, so it is handled before the usage check.
if opts.list then
  local naming_   = require("naming")
  local transport_ = require("transport")
  local t_ = transport_.new({ port = tonumber(opts.port) or 22 }):open()

  local machines = naming_.list(t_, { timeout = tonumber(opts.timeout) or 2 })

  -- A broadcast never loops back to its sender, so this machine can never
  -- discover itself. Add it explicitly: a cluster listing that omits the
  -- machine you are standing on is a listing you cannot trust.
  local selfName
  do
    local f = io.open("/etc/hostname", "r")
    if f then selfName = f:read("l"); f:close() end
    if selfName == "" then selfName = nil end
  end

  if #machines == 0 and not selfName then
    print("no named machines answered")
    print("set one with:  hostname <name>   (then: rc kbxsshd restart)")
    return 0
  end

  print(string.format("%-20s %-40s %s", "HOSTNAME", "ADDRESS", ""))
  if selfName then
    local addr = component.isAvailable("modem")
      and component.getPrimary("modem").address or "-"
    print(string.format("%-20s %-40s %s", selfName, addr, "(this machine)"))
  end
  for _, m in ipairs(machines) do
    print(string.format("%-20s %-40s %s", m.name, m.address, ""))
  end
  return 0
end

if #args < 1 then
  print("usage: ssh <hostname|address> [command...]")
  print("       ssh <hostname|address> --secret <secret>")
  print("       ssh --list                 show every named machine")
  return 1
end

local target = args[1]

local function makeDigest()
  if not component.isAvailable("data") then return nil end
  local data = component.getPrimary("data")
  if not data.sha256 then return nil end
  return function(s)
    local raw = data.sha256(s)
    return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
end

local t = transport.new({
  port    = tonumber(opts.port) or 22,
  timeout = tonumber(opts.timeout) or 3,
  retries = 4,
}):open()

-- A hostname costs one broadcast to resolve; an address costs nothing.
local host, resolveErr = naming.lookup(t, target)
if not host then
  io.stderr:write("ssh: " .. tostring(resolveErr) .. "\n")
  return 1
end

local session, err = ssh.connect(t, host, {
  secret = opts.secret,
  digest = makeDigest(),
})

if not session then
  io.stderr:write("ssh: " .. tostring(err) .. "\n")
  return 1
end

local function run(cmd)
  local out, code, truncated = session:exec(cmd)
  if out == nil then
    io.stderr:write("ssh: " .. tostring(code) .. "\n")
    return 1
  end
  if #out > 0 then
    io.write(out)
    if out:sub(-1) ~= "\n" then io.write("\n") end
  end
  if truncated then
    io.stderr:write("ssh: output truncated\n")
  end
  return code
end

-- One-shot form.
if #args > 1 then
  return run(table.concat(args, " ", 2))
end

-- Interactive form.
print(string.format("connected to %s%s (auth: %s)",
  session.hostname or session.remote:sub(1, 8),
  session.hostname and (" [" .. session.remote:sub(1, 8) .. "]") or "",
  session.mode))
print("type 'exit' to disconnect")

while true do
  io.write((session.hostname or host:sub(1, 8)) .. "# ")
  local line = io.read()
  if line == nil or line == "exit" then break end
  if line:match("%S") then run(line) end
end

print("disconnected")
return 0
