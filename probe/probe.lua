--[[ kublocknetes :: phase 0 hardware probe

     Dumps this machine's capabilities and the full method surface of every
     attached component type to /home/probe.txt

     Every section is independently pcall-wrapped and the file is flushed
     between them. A probe that dies halfway is still worth reading -- and
     the whole reason this script exists is that we do not yet know what
     this sandbox allows, so it must assume anything can fail.

     Safe to run anywhere. Calls nothing that returns bulk data.

     usage:  probe
             pastebin put /home/probe.txt
]]

local component = require("component")
local computer  = require("computer")

local OUT = "/home/probe.txt"
local out = assert(io.open(OUT, "w"))

--- Write a line. Never throws, even if the format string and arguments
--- disagree -- a formatting slip must not cost us the whole report.
local function w(fmt, ...)
  local line
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, fmt, ...)
    line = ok and formatted or (tostring(fmt) .. "   <bad format args>")
  else
    line = tostring(fmt)
  end
  out:write(line, "\n")
end

local function try(fn, ...)
  if type(fn) ~= "function" then return nil, "not a function" end
  local ok, v = pcall(fn, ...)
  if ok then return v end
  return nil, v
end

local function section(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    w("")
    w("!! section '%s' failed: %s", name, tostring(err))
  end
  out:flush()
end

-- ------------------------------------------------------ gc capability ----
-- OC sandboxes collectgarbage, and on at least some builds calling it
-- raises. Detect what works rather than assuming, because every memory
-- measurement below depends on it.

local gcMode = "unavailable"

if type(collectgarbage) == "function" then
  if pcall(collectgarbage, "collect") then
    gcMode = "collect"
  elseif pcall(collectgarbage) then
    gcMode = "bare"
  end
end

local function gc()
  if gcMode == "collect" then
    for _ = 1, 4 do pcall(collectgarbage, "collect") end
  elseif gcMode == "bare" then
    for _ = 1, 4 do pcall(collectgarbage) end
  end
end

-- ---------------------------------------------------------------- node ----

section("node", function()
  gc()

  w("== node ==")
  w("address       %s", tostring(computer.address()))
  w("tmp           %s", tostring(try(computer.tmpAddress)))
  w("lua           %s", tostring(_VERSION))
  w("architecture  %s", tostring(try(computer.getArchitecture) or "?"))
  w("gc control    %s", gcMode)

  local total = try(computer.totalMemory)
  local free  = try(computer.freeMemory)
  w("mem total     %s bytes (%.2f MB)", tostring(total), (total or 0) / 1048576)
  w("mem free      %s bytes (%.2f MB)", tostring(free), (free or 0) / 1048576)

  w("energy        %s / %s", tostring(try(computer.energy)),
                             tostring(try(computer.maxEnergy)))
  w("uptime        %ss", tostring(try(computer.uptime)))

  -- Decides whether pods can be coroutines or must be hand-rolled on top of
  -- pullSignal. Load-bearing for the kubelet design.
  local ok, thread = pcall(require, "thread")
  w("thread api    %s", tostring(ok and type(thread) == "table"))

  local archs = try(computer.getArchitectures)
  if type(archs) == "table" then
    local names = {}
    for _, a in ipairs(archs) do names[#names + 1] = tostring(a) end
    w("archs avail   %s", table.concat(names, ", "))
  end
end)

-- ------------------------------------------------------- sandbox caps ----
-- We now know the sandbox is more restricted than stock Lua 5.3. Everything
-- in lib/ has to run inside it, so enumerate exactly what is on offer.

section("sandbox", function()
  w("")
  w("== sandbox ==")

  local GLOBALS = {
    "collectgarbage", "load", "loadstring", "dofile", "loadfile", "require",
    "rawget", "rawset", "rawequal", "rawlen", "setmetatable", "getmetatable",
    "select", "pcall", "xpcall", "error", "assert", "next", "pairs", "ipairs",
    "tonumber", "tostring", "type", "unpack", "print",
  }

  for _, name in ipairs(GLOBALS) do
    w("   %-18s %s", name, type(_G[name]))
  end

  local MEMBERS = {
    "table.unpack", "table.pack", "table.move", "table.concat", "table.sort",
    "string.format", "string.rep", "string.gmatch", "string.pack",
    "math.tointeger", "math.type", "math.maxinteger",
    "os.time", "os.clock", "os.date", "os.getenv",
    "io.open", "io.write",
    "coroutine.create", "coroutine.close", "coroutine.isyieldable",
    "utf8.char", "debug.traceback", "debug.getinfo",
  }

  w("")
  for _, path in ipairs(MEMBERS) do
    local root, key = path:match("^(%w+)%.(%w+)$")
    local parent = _G[root]
    local value = (type(parent) == "table") and parent[key] or nil
    w("   %-24s %s", path, type(value))
  end
end)

-- -------------------------------------------------------- device info ----
-- getDeviceInfo is the fastest route to real rack specs: CPU tier, RAM
-- stick sizes, disk capacities, all self-reported by the hardware.

section("devices", function()
  local info = try(computer.getDeviceInfo)
  if type(info) ~= "table" then
    w("")
    w("== devices ==")
    w("   getDeviceInfo unavailable on this build")
    return
  end

  w("")
  w("== devices ==")

  local addrs = {}
  for addr in pairs(info) do addrs[#addrs + 1] = addr end
  table.sort(addrs)

  for _, addr in ipairs(addrs) do
    local d = info[addr]
    w("%s", addr)
    local keys = {}
    for k in pairs(d) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      w("   %-14s %s", k, tostring(d[k]))
    end
  end
end)

-- ---------------------------------------------------------- inventory ----

section("components", function()
  w("")
  w("== components ==")

  local counts, order, total = {}, {}, 0

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
end)

-- ------------------------------------------------------------ modem ----
-- Transport limits drive the entire RPC framing layer, so read them
-- rather than trusting documented defaults.

section("transport", function()
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
end)

-- ------------------------------------------------------- api surface ----
-- One representative per component type, with the direct/indirect flag:
-- indirect calls cost a tick each, which dominates the cost of any loop
-- that touches a component per iteration.

section("api", function()
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

      local fields = try(component.fields, addr)
      if type(fields) == "table" and next(fields) then
        local fnames = {}
        for name in pairs(fields) do fnames[#fnames + 1] = tostring(name) end
        table.sort(fnames)
        w("    fields: %s", table.concat(fnames, ", "))
      end

      out:flush()
    end
  end
end)

-- ---------------------------------------------------------------- fin ----

gc()
w("")
w("== done ==")
w("mem free after probe  %s bytes", tostring(try(computer.freeMemory)))
out:close()

print("wrote " .. OUT)
print("upload with:  pastebin put " .. OUT)
