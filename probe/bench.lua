--[[ kublocknetes :: phase 0 call-cost benchmark

     The probe showed that modem.send, broadcast and open are all INDIRECT
     calls (direct=false), while maxPacketSize and isOpen are direct.

     In OpenComputers an indirect call makes the machine yield and resume on
     a later server tick, whereas direct calls run inline against a per-tick
     budget. If that is right, the cost of sending a message is dominated by
     the NUMBER OF PACKETS, not their size -- which would make chunking far
     more expensive than the 8KB limit suggests, and would set a hard ceiling
     on cluster chatter.

     This measures it instead of assuming it.

     usage:  bench
             bench --count 200

     Sends go to a port nothing is listening on, so nothing is delivered and
     no queues are disturbed. It is still real network traffic -- run it on a
     quiet machine.
]]

local component = require("component")
local computer  = require("computer")
local shell     = require("shell")

local _, opts = shell.parse(...)
local N = tonumber(opts.count) or 100

local DEAD_PORT = 41234  -- deliberately nobody's port

if not component.isAvailable("modem") then
  io.stderr:write("no modem on this machine\n")
  return 1
end

local modem = component.getPrimary("modem")

--- Time `n` invocations of fn, returning seconds per call.
local function measure(label, n, fn)
  local start = computer.uptime()
  for i = 1, n do fn(i) end
  local elapsed = computer.uptime() - start

  local per = elapsed / n
  io.write(string.format("  %-34s %8.2f ms/call   (%.2fs total)\n",
    label, per * 1000, elapsed))
  return per
end

io.write(string.format("call cost benchmark, n=%d\n\n", N))

io.write("direct calls\n")
local directCost = measure("modem.maxPacketSize()", N, function()
  modem.maxPacketSize()
end)

measure("computer.freeMemory()", N, function()
  computer.freeMemory()
end)

io.write("\nindirect calls\n")
local sendCost = measure("modem.broadcast(dead port, 8B)", N, function()
  modem.broadcast(DEAD_PORT, "xxxxxxxx")
end)

-- If cost is per-call rather than per-byte, a big payload costs the same as
-- a small one. That is the whole question.
local big = string.rep("x", 7000)
local bigCost = measure("modem.broadcast(dead port, 7KB)", N, function()
  modem.broadcast(DEAD_PORT, big)
end)

io.write("\n")
io.write(string.format("  indirect / direct ratio        %.1fx\n",
  directCost > 0 and (sendCost / directCost) or 0))
io.write(string.format("  7KB / 8B send ratio            %.2fx\n",
  sendCost > 0 and (bigCost / sendCost) or 0))

io.write("\ninterpretation\n")
if sendCost > 0 then
  io.write(string.format("  a 1-packet message costs about %.0f ms\n", sendCost * 1000))
  io.write(string.format("  a 50KB message (%d packets) costs about %.2f s\n",
    math.ceil(50000 / 8064), math.ceil(50000 / 8064) * sendCost))
  io.write(string.format("  sustained ceiling is about %.0f packets/sec\n", 1 / sendCost))
end

if bigCost > 0 and sendCost > 0 and (bigCost / sendCost) < 1.5 then
  io.write("\n  payload size barely matters: cost is PER PACKET.\n")
  io.write("  pack aggressively and send fewer, fuller packets.\n")
else
  io.write("\n  payload size does matter; cost is not purely per-packet.\n")
end

return 0
