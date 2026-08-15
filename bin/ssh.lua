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

local args, opts = shell.parse(...)

if #args < 1 then
  print("usage: ssh <address> [command...]")
  print("       ssh <address> --secret <secret>")
  return 1
end

local host = args[1]

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
print(string.format("connected to %s (auth: %s)", session.remote, session.mode))
print("type 'exit' to disconnect")

while true do
  io.write(host:sub(1, 8) .. "# ")
  local line = io.read()
  if line == nil or line == "exit" then break end
  if line:match("%S") then run(line) end
end

print("disconnected")
return 0
