--[[ kublocknetes :: phase 0 hardware probe

     Dumps this machine's capabilities and the full method surface of every
     attached component type to /home/probe.txt

     Safe to run anywhere. Calls nothing that returns bulk data.

     usage:  probe
             pastebin put /home/probe.txt
]]

local component = require("component")
local computer  = require("computer")

local OUT = "/home/probe.txt"
local out = assert(io.open(OUT, "w"))

local function w(fmt, ...)
  local n = select("#", ...)
  out:write(n > 0 and string.format(fmt, ...) or fmt, "\n")
end

local function try(fn, ...)
  local ok, v = pcall(fn, ...)
  if ok then return v end
  return nil, v
end

local function gc()
  for _ = 1, 4 do collectgarbage() end
end

-- ---------------------------------------------------------------- node ----

gc()

w("== node ==")
w("address       %s", computer.address())
w("tmp           %s", tostring(try(computer.tmpAddress)))
w("lua           %s", _VERSION)
w("architecture  %s", tostring(try(computer.getArchitecture) or "?"))
w("mem total     %d bytes (%.2f MB)", computer.totalMemory(), computer.totalMemory() / 1048576)
w("mem free      %d bytes (%.2f MB)", computer.freeMemory(), computer.freeMemory() / 1048576)
w("energy        %.0f / %.0f", computer.energy(), computer.maxEnergy())
w("uptime        %.1fs", computer.uptime())

-- OpenOS thread support decides whether pods can be coroutines or must be
-- hand-rolled on top of pullSignal. This is a load-bearing answer.
local has_thread = pcall(require, "thread")
w("thread api    %s", tostring(has_thread))

local archs = try(computer.getArchitectures)
if type(archs) == "table" then
  w("archs avail   %s", table.concat(archs, ", "))
end

-- ---------------------------------------------------------- inventory ----

w("")
w("== components ==")

local counts, order = {}, {}
local total = 0
for addr, ctype in component.list() do
  w("%s  %s", addr, ctype)
  if not counts[ctype] then
    counts[ctype] = 0
    order[#order + 1] = ctype
  end
  counts[ctype] = counts[ctype] + 1
  total = total + 1
end

table.sort(order)
w("")
w("-- %d components, %d distinct types", total, #order)
for _, ctype in ipairs(order) do
  w("   %4d  %s", counts[ctype], ctype)
end
out:flush()

-- ------------------------------------------------------------ modem ----
-- Transport limits drive the entire RPC framing layer, so pull them
-- explicitly rather than trusting documented defaults.

w("")
w("== transport ==")

for addr in component.list("modem") do
  local m = component.proxy(addr)
  w("modem %s", addr)
  w("   maxPacketSize   %s", tostring(try(m.maxPacketSize)))
  local wireless = try(m.isWireless)
  w("   isWireless      %s", tostring(wireless))
  if wireless then
    w("   strength        %s", tostring(try(m.getStrength)))
  end
  w("   isLinked        %s", tostring(try(m.isLinked) or false))
end

for addr in component.list("tunnel") do
  local t = component.proxy(addr)
  w("tunnel %s  (linked card)", addr)
  w("   maxPacketSize   %s", tostring(try(t.maxPacketSize)))
  w("   channel         %s", tostring(try(t.getChannel)))
end
out:flush()

-- ------------------------------------------------------- api surface ----
-- One representative per component type. Includes the direct/indirect flag:
-- indirect calls cost a tick each, which matters enormously for any loop
-- that touches a component per iteration.

w("")
w("== api surface (one instance per type) ==")

local seen = {}
for addr, ctype in component.list() do
  if not seen[ctype] then
    seen[ctype] = true

    w("")
    w("--- %s   [%s]", ctype, addr)

    local methods, err = try(component.methods, addr)
    if type(methods) ~= "table" then
      w("    <methods unavailable: %s>", tostring(err))
    else
      local names = {}
      for name in pairs(methods) do names[#names + 1] = name end
      table.sort(names)

      for _, name in ipairs(names) do
        local doc = try(component.doc, addr, name)
        w("    %-30s direct=%-5s %s",
          name, tostring(methods[name]), doc or "")
      end
    end

    -- Fields (non-method properties) show up on some drivers.
    local fields = try(component.fields, addr)
    if type(fields) == "table" and next(fields) then
      local fnames = {}
      for name in pairs(fields) do fnames[#fnames + 1] = name end
      table.sort(fnames)
      w("    fields: %s", table.concat(fnames, ", "))
    end

    out:flush()
  end
end

-- ---------------------------------------------------------------- fin ----

gc()
w("")
w("== done ==")
w("mem free after probe  %d bytes", computer.freeMemory())
out:close()

print("wrote " .. OUT)
print("upload with:  pastebin put " .. OUT)
