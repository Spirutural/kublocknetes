--[[ kublocknetes :: phase 0 ME sizing probe

     Answers: how big is the ME item set, what does one entry cost in RAM,
     and can we stream it instead of materializing it?

     RUN THIS ON A SACRIFICIAL MACHINE. By default it refuses to make any
     call that returns the full network contents -- it measures cost on a
     narrow filter and extrapolates instead.

     usage:  probe_me              safe: capability report + cost estimate
             probe_me --force      actually call getItemsInNetwork() with no
                                   filter. This may hard-OOM the machine.
                                   That is the point of running it here.
]]

local component = require("component")
local computer  = require("computer")

local args = { ... }
local FORCE = false
for _, a in ipairs(args) do
  if a == "--force" then FORCE = true end
end

local OUT = "/home/probe_me.txt"
local out = assert(io.open(OUT, "w"))

local function w(fmt, ...)
  local n = select("#", ...)
  out:write(n > 0 and string.format(fmt, ...) or fmt, "\n")
  out:flush()
end

-- OC sandboxes collectgarbage and on some builds calling it raises, so
-- detect what works. Without a forced collection, every measurement below
-- includes uncollected garbage and reads high -- treat it as an upper bound.
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

local function mem()
  gc()
  return computer.freeMemory()
end

-- ------------------------------------------------------------- locate ----

local me, kind
for _, name in ipairs({ "me_interface", "me_controller", "me_exportbus", "me_importbus" }) do
  if component.isAvailable(name) then
    me, kind = component.getPrimary(name), name
    break
  end
end

if not me then
  w("no ME component found on this machine")
  w("attach an Adapter to an ME Interface / ME Controller and rerun")
  out:close()
  print("no ME component -- see " .. OUT)
  return
end

w("== me probe ==")
w("component     %s", kind)
w("address       %s", me.address)
w("mem total     %d bytes", computer.totalMemory())
w("mem free      %d bytes", mem())
w("mode          %s", FORCE and "FORCE (unfiltered call permitted)" or "safe")
w("gc control    %s%s", gcMode,
  gcMode == "unavailable" and "  (sizes below are upper bounds)" or "")

-- ------------------------------------------------------- capabilities ----
-- Which of these exist decides the entire ingest strategy: an iterator means
-- constant-memory streaming, a filter-only API means we shard the scan.

w("")
w("== capabilities ==")

local INTERESTING = {
  "allItems", "getItemsInNetwork", "getCraftables", "getCpus",
  "getFluidsInNetwork", "getEssentiaInNetwork", "getItemsInNetworkFiltered",
  "requestCrafting", "store", "getAvailableItems", "getNetworkStatus",
}

local methods = {}
do
  local ok, m = pcall(component.methods, me.address)
  if ok and type(m) == "table" then methods = m end
end

local present = {}
for _, name in ipairs(INTERESTING) do
  local has = methods[name] ~= nil
  present[name] = has
  w("   %-26s %s%s", name, has and "yes" or "no",
    has and string.format("   direct=%s", tostring(methods[name])) or "")
end

w("")
w("full method list:")
do
  local names = {}
  for name in pairs(methods) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    w("   %s", name)
  end
end

-- ------------------------------------------------- streaming (best case) ----

if present.allItems then
  w("")
  w("== streaming via allItems() ==")

  local before = mem()
  local ok, iter = pcall(me.allItems)

  if not ok then
    w("allItems() failed: %s", tostring(iter))
  else
    local count, low = 0, before
    local sampled = false

    -- Pull one at a time. Memory should stay flat; if it climbs linearly the
    -- iterator is secretly buffering and streaming ingest won't save us.
    while true do
      local ok2, entry = pcall(iter.next, iter)
      if not ok2 or entry == nil then break end

      count = count + 1

      if not sampled then
        sampled = true
        w("first entry fields:")
        if type(entry) == "table" then
          local keys = {}
          for k in pairs(entry) do keys[#keys + 1] = tostring(k) end
          table.sort(keys)
          for _, k in ipairs(keys) do
            local v = entry[k]
            w("   %-20s %s  (%s)", k, tostring(v), type(v))
          end
        else
          w("   <non-table entry: %s>", type(entry))
        end
      end

      if count % 250 == 0 then
        local now = computer.freeMemory()
        if now < low then low = now end
        w("   ... %d entries, free=%d", count, now)
        os.sleep(0)
      end
    end

    gc()
    w("")
    w("total entries      %d", count)
    w("free before        %d", before)
    w("free after         %d", mem())
    w("watermark low      %d", low)
    w("=> streaming ingest is %s",
      (mem() > before * 0.8) and "VIABLE (memory returned)"
                              or "SUSPECT (iterator buffers -- shard instead)")
  end
end

-- ------------------------------------------------- cost per entry ----------
-- Measure on a filter narrow enough to be safe, then extrapolate what the
-- unfiltered call would have cost.

if present.getItemsInNetwork then
  w("")
  w("== per-entry cost (filtered) ==")

  local PROBES = {
    { name = "minecraft:iron_ingot" },
    { name = "minecraft:cobblestone" },
    { name = "minecraft:redstone" },
  }

  for _, filter in ipairs(PROBES) do
    local before = mem()
    local ok, res = pcall(me.getItemsInNetwork, filter)
    if ok and type(res) == "table" then
      local after = computer.freeMemory()
      local n = #res
      w("filter %-28s entries=%-4d cost=%d bytes  (%s/entry)",
        filter.name, n, before - after,
        n > 0 and tostring(math.floor((before - after) / n)) or "n/a")

      if n > 0 and res[1] then
        local keys = {}
        for k in pairs(res[1]) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        w("   fields: %s", table.concat(keys, ", "))
      end
    else
      w("filter %-28s FAILED: %s", filter.name, tostring(res))
    end
    res = nil
    gc()
  end

  w("")
  w("NOTE: multiply bytes/entry by your real stack count to see whether an")
  w("      unfiltered call could ever fit. If it cannot, that is the finding.")
end

-- ------------------------------------------------- the dangerous call ------

if present.getItemsInNetwork and FORCE then
  w("")
  w("== UNFILTERED getItemsInNetwork() ==")
  w("free before        %d", mem())
  out:close()  -- close first: if this OOMs, the file must already be on disk

  local before = computer.freeMemory()
  local ok, res = pcall(me.getItemsInNetwork)

  out = assert(io.open(OUT, "a"))
  if ok and type(res) == "table" then
    local n = #res
    local after = computer.freeMemory()
    w("SURVIVED")
    w("entries            %d", n)
    w("cost               %d bytes", before - after)
    w("free after         %d", after)
  else
    w("FAILED: %s", tostring(res))
  end
elseif present.getItemsInNetwork then
  w("")
  w("unfiltered call skipped (pass --force on a sacrificial machine)")
end

-- --------------------------------------------------------- craftables -----
-- GT:NH craftable counts are usually far larger than the stocked item count.

if present.getCraftables then
  w("")
  w("== craftables (filtered probe only) ==")
  local before = mem()
  local ok, res = pcall(me.getCraftables, { name = "minecraft:iron_ingot" })
  if ok and type(res) == "table" then
    w("filtered craftables entries=%d cost=%d bytes", #res, before - computer.freeMemory())
  else
    w("filtered getCraftables FAILED: %s", tostring(res))
  end
  w("unfiltered getCraftables() NOT attempted -- assume it is larger than the")
  w("item set and plan to shard or filter it too.")
end

gc()
w("")
w("== done ==")
w("mem free           %d bytes", computer.freeMemory())
out:close()

print("wrote " .. OUT)
print("upload with:  pastebin put " .. OUT)
