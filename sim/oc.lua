--[[ sim :: OpenComputers simulator

     Runs many virtual OC machines inside one host Lua process so that
     cluster code can be developed and tested without Minecraft.

     Each virtual node is a coroutine with its own sandboxed globals, its own
     `component` / `computer` / `event` modules, and its own bounded signal
     queue. They talk over a shared modem bus that faithfully reproduces the
     three failure modes that actually matter in OC:

       * packets larger than maxPacketSize are rejected at send time
       * a full receive queue drops packets silently, with no error
       * packets can be lost or reordered in flight

     Time is virtual. The world advances to the next scheduled event when
     every node is blocked, so a 10-minute cluster test runs in milliseconds.

     WHAT THIS DOES NOT SIMULATE: real Lua memory accounting. Per-node
     memory is a number the test controls, not a measurement. It is enough to
     exercise scheduler logic; it will not catch a genuine OOM. Only the game
     can tell you that.
]]

local serialization = require("serialization")

local M = {}

-- ---------------------------------------------------------------- rng ----
-- Deterministic by design: a flaky-network test that cannot be replayed is
-- worse than no test.

local function newRng(seed)
  local state = (seed or 0x5EED) % 2147483648
  return function()
    state = (1103515245 * state + 12345) % 2147483648
    return state / 2147483648
  end
end

-- --------------------------------------------------------- addressing ----

local function newAddress(rng)
  local hex = "0123456789abcdef"
  local parts = {}
  for _, len in ipairs({ 8, 4, 4, 4, 12 }) do
    local buf = {}
    for i = 1, len do
      local n = math.floor(rng() * 16) + 1
      buf[i] = hex:sub(n, n)
    end
    parts[#parts + 1] = table.concat(buf)
  end
  return table.concat(parts, "-")
end

-- -------------------------------------------------------- packet sizing ----
-- Approximates how OC charges for a packet's values. Conservative on
-- purpose: better that the simulator rejects a packet the game would have
-- allowed than the reverse.

local function valueSize(v)
  local t = type(v)
  if t == "string" then return #v + 2 end
  if t == "number" then return 8 end
  if t == "boolean" then return 4 end
  if t == "nil" then return 1 end
  error("modem: cannot send value of type " .. t, 0)
end

-- ================================================================ World ====

local World = {}
World.__index = World

function M.newWorld(cfg)
  cfg = cfg or {}
  local rng = newRng(cfg.seed)
  return setmetatable({
    time          = 0,
    nodes         = {},
    order         = {},
    inflight      = {},
    maxPacketSize = cfg.maxPacketSize or 8192,
    maxQueueSize  = cfg.maxQueueSize or 256,
    lossRate      = cfg.lossRate or 0,
    latency       = cfg.latency or 0.05,
    jitter        = cfg.jitter or 0.02,
    stepLimit     = cfg.stepLimit or 2000000,
    rng           = rng,
    shared        = {},
    -- Globals withheld from node sandboxes, matched to a real GT:NH machine
    -- (see docs/hardware.md). collectgarbage is simply absent there, so any
    -- library code reaching for it must fail here too.
    --
    -- Not denied, because OpenOS really does provide them: dofile, loadfile,
    -- debug.traceback, debug.getinfo, utf8, string.pack, table.move.
    -- Already absent in host Lua 5.3, so needing no help: loadstring, unpack,
    -- coroutine.close.
    deny          = cfg.deny or { "collectgarbage" },
    verbose       = cfg.verbose or false,
    stats         = { sent = 0, delivered = 0, lost = 0, dropped = 0 },
  }, World)
end

function World:log(fmt, ...)
  if self.verbose then
    io.write(string.format("[%8.3f] " .. fmt .. "\n", self.time, ...))
  end
end

-- ================================================================= Node ====

local Node = {}
Node.__index = Node

--- Add a machine to the world.
--  spec.name         label used in logs
--  spec.totalMemory  bytes (default 1.5MB, a T3 case with 2x T3 RAM)
--  spec.freeMemory   bytes currently free (default 85% of total)
--  spec.wireless     modem is wireless
--  spec.components   extra fake components: { type = methodTable }
function World:addNode(spec)
  spec = spec or {}

  local node = setmetatable({
    world       = self,
    address     = spec.address or newAddress(self.rng),
    name        = spec.name or ("node" .. (#self.order + 1)),
    totalMemory = spec.totalMemory or 1572864,
    up          = true,
    booted      = 0,
    queue       = {},
    openPorts   = {},
    components  = {},
    modules     = {},
    wake        = 0,
    dropped     = 0,
    wireless    = spec.wireless or false,
  }, Node)

  node.freeMemory = spec.freeMemory or math.floor(node.totalMemory * 0.85)

  node:_addComponent("modem", node:_modemMethods())
  node:_addComponent("computer", {})

  for ctype, methods in pairs(spec.components or {}) do
    node:_addComponent(ctype, methods)
  end

  self.nodes[node.address] = node
  self.order[#self.order + 1] = node
  return node
end

function Node:_addComponent(ctype, methods)
  local addr = newAddress(self.world.rng)
  self.components[addr] = { type = ctype, methods = methods, address = addr }
  return addr
end

function Node:__tostring()
  return "node:" .. self.name
end

-- ------------------------------------------------------------- modem ----

function Node:_modemMethods()
  local node = self

  local function transmit(target, port, ...)
    local world = node.world

    if type(port) ~= "number" or port < 1 or port > 65535 then
      error("invalid port number", 0)
    end

    local size = 0
    local values = table.pack(...)
    for i = 1, values.n do
      size = size + valueSize(values[i])
    end
    if size > world.maxPacketSize then
      error("packet too big (max " .. world.maxPacketSize .. ")", 0)
    end

    world.stats.sent = world.stats.sent + 1

    local targets = {}
    if target then
      local t = world.nodes[target]
      if t then targets[1] = t end
    else
      for _, t in ipairs(world.order) do
        if t ~= node then targets[#targets + 1] = t end
      end
    end

    for _, t in ipairs(targets) do
      if world.rng() < world.lossRate then
        world.stats.lost = world.stats.lost + 1
        world:log("%s -> %s :%d LOST", node.name, t.name, port)
      else
        local delay = world.latency + world.rng() * world.jitter
        world.inflight[#world.inflight + 1] = {
          at     = world.time + delay,
          to     = t,
          from   = node,
          port   = port,
          values = values,
        }
      end
    end

    return true
  end

  return {
    address = function() return nil end,

    open = function(port)
      if node.openPorts[port] then return false end
      node.openPorts[port] = true
      return true
    end,

    close = function(port)
      if port == nil then
        node.openPorts = {}
        return true
      end
      if not node.openPorts[port] then return false end
      node.openPorts[port] = nil
      return true
    end,

    isOpen = function(port) return node.openPorts[port] == true end,

    maxPacketSize = function() return node.world.maxPacketSize end,

    isWireless = function() return node.wireless end,

    getStrength = function() return node.wireless and 400 or 0 end,
    setStrength = function(s) return s end,

    send = function(address, port, ...)
      return transmit(address, port, ...)
    end,

    broadcast = function(port, ...)
      return transmit(nil, port, ...)
    end,
  }
end

-- ------------------------------------------------------------ signals ----

function Node:push(name, ...)
  if not self.up then return false end

  -- The bounded queue is the whole point. Overflow is silent in OC, so it
  -- must be silent here too.
  if #self.queue >= self.world.maxQueueSize then
    self.dropped = self.dropped + 1
    self.world.stats.dropped = self.world.stats.dropped + 1
    self.world:log("%s QUEUE FULL, dropping %s", self.name, tostring(name))
    return false
  end

  self.queue[#self.queue + 1] = table.pack(name, ...)
  return true
end

-- --------------------------------------------------------- lifecycle ----

--- Hard power cut. Everything in flight and in the queue is lost, exactly
--  like a redstone-gated power feed being switched off.
function Node:crash()
  self.world:log("%s CRASH", self.name)
  self.up = false
  self.co = nil
  self.queue = {}
  self.openPorts = {}
end

function Node:boot(entry, ...)
  self.up = true
  self.booted = self.world.time
  self.queue = {}

  local args = table.pack(...)
  local fn = type(entry) == "function" and entry or self:loadfile(entry)

  self.co = coroutine.create(function()
    return fn(table.unpack(args, 1, args.n))
  end)
  self.wake = 0
  self.world:log("%s BOOT", self.name)
end

-- -------------------------------------------------- module resolution ----
-- Node code runs in its own sandbox and gets its own instance of every
-- module, so two virtual machines never share state by accident.

local SEARCH_ROOTS = { "lib/", "sim/", "" }

function Node:_env()
  if self._envCache then return self._envCache end

  local node = self
  local env = {}
  for k, v in pairs(_G) do env[k] = v end

  for _, name in ipairs(node.world.deny) do env[name] = nil end

  env._G = env
  env.require = function(name) return node:_require(name) end

  -- Escape hatch for tests: a table visible to every node and to the host.
  -- Nothing in lib/ may touch this.
  env.SHARED = node.world.shared

  env.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[#parts + 1] = tostring((select(i, ...)))
    end
    io.write(string.format("[%8.3f] %-10s %s\n",
      node.world.time, node.name, table.concat(parts, "\t")))
  end

  env.os = setmetatable({
    time  = function() return math.floor(node.world.time) end,
    clock = function() return node.world.time end,
    sleep = function(t) node:_sleep(t) end,
    date  = os.date,
  }, { __index = os })

  self._envCache = env
  return env
end

function Node:_sleep(seconds)
  local deadline = self.world.time + (seconds or 0)
  repeat
    coroutine.yield({ wake = deadline })
  until self.world.time >= deadline
end

function Node:_require(name)
  if self.modules[name] then return self.modules[name] end

  local builtin = self["_module_" .. name]
  if builtin then
    local mod = builtin(self)
    self.modules[name] = mod
    return mod
  end

  local relative = name:gsub("%.", "/") .. ".lua"
  for _, root in ipairs(SEARCH_ROOTS) do
    local path = root .. relative
    local f = io.open(path, "r")
    if f then
      local src = f:read("a")
      f:close()
      local chunk, err = load(src, "@" .. path, "t", self:_env())
      if not chunk then error("load " .. path .. ": " .. err, 0) end
      local mod = chunk()
      self.modules[name] = mod
      return mod
    end
  end

  error("module '" .. name .. "' not found", 0)
end

--- Compile source in this node's sandbox. This is also how pod dispatch
--  will work for real: code arrives as a string and is loaded into a
--  restricted environment.
function Node:loadstring(src, name)
  return assert(load(src, "=" .. (name or "chunk"), "t", self:_env()))
end

function Node:loadfile(path)
  local f = assert(io.open(path, "r"), "cannot open " .. path)
  local src = f:read("a")
  f:close()
  return assert(load(src, "@" .. path, "t", self:_env()))
end

-- ----------------------------------------------------- node modules ----

function Node:_module_serialization()
  return serialization
end

function Node:_module_computer()
  local node = self

  return {
    address     = function() return node.address end,
    tmpAddress  = function() return nil end,
    totalMemory = function() return node.totalMemory end,
    freeMemory  = function() return node.freeMemory end,
    energy      = function() return 1000 end,
    maxEnergy   = function() return 1000 end,
    uptime      = function() return node.world.time - node.booted end,
    users       = function() return end,
    beep        = function() end,
    shutdown    = function() node:crash() end,

    pushSignal  = function(name, ...) return node:push(name, ...) end,

    pullSignal  = function(timeout)
      local deadline = timeout and (node.world.time + timeout) or nil
      while true do
        if #node.queue > 0 then
          local sig = table.remove(node.queue, 1)
          return table.unpack(sig, 1, sig.n)
        end
        if deadline and node.world.time >= deadline then return nil end
        -- math.huge, not nil: a nil wake means "runnable now", which would
        -- turn an untimed pullSignal into a busy spin.
        coroutine.yield({ wake = deadline or math.huge })
      end
    end,
  }
end

function Node:_module_component()
  local node = self

  -- Real OC proxy methods are callable TABLES, not functions: they carry a
  -- __call plus a __tostring returning the method's documentation, which is
  -- why `print(component.gpu.setResolution)` prints docs in OpenOS.
  --
  -- Modelling this faithfully matters. Handing out plain functions here lets
  -- `type(m.send) == "function"` guards pass in tests and then silently skip
  -- every component call in-game -- which is exactly how the first probe
  -- reported a nil maxPacketSize on a modem that had one.
  local function proxyFor(entry)
    local proxy = { address = entry.address, type = entry.type }
    for name, fn in pairs(entry.methods) do
      proxy[name] = setmetatable({}, {
        __call     = function(_, ...) return fn(...) end,
        __tostring = function() return "function -- " .. name end,
      })
    end
    return proxy
  end

  local component
  component = {
    list = function(filter)
      local items = {}
      for addr, entry in pairs(node.components) do
        if not filter or entry.type:find(filter, 1, true) then
          items[#items + 1] = { addr, entry.type }
        end
      end
      table.sort(items, function(a, b) return a[1] < b[1] end)
      local i = 0
      return function()
        i = i + 1
        if items[i] then return items[i][1], items[i][2] end
      end
    end,

    proxy = function(addr)
      local entry = node.components[addr]
      if not entry then return nil, "no such component" end
      return proxyFor(entry)
    end,

    type = function(addr)
      local entry = node.components[addr]
      return entry and entry.type or nil
    end,

    methods = function(addr)
      local entry = node.components[addr]
      if not entry then return nil, "no such component" end
      local out = {}
      for name in pairs(entry.methods) do out[name] = true end
      return out
    end,

    doc = function() return "" end,

    isAvailable = function(ctype)
      for _, entry in pairs(node.components) do
        if entry.type == ctype then return true end
      end
      return false
    end,

    getPrimary = function(ctype)
      local best
      for addr, entry in pairs(node.components) do
        if entry.type == ctype and (not best or addr < best.address) then
          best = entry
        end
      end
      if not best then error("no primary '" .. ctype .. "' available", 0) end
      return proxyFor(best)
    end,
  }

  return setmetatable(component, {
    __index = function(_, ctype)
      if component.isAvailable(ctype) then
        return component.getPrimary(ctype)
      end
      return nil
    end,
  })
end

function Node:_module_event()
  local node = self
  local computer = node:_require("computer")

  return {
    pull = function(...)
      local args = table.pack(...)
      local timeout, first = nil, 1
      if type(args[1]) == "number" then
        timeout, first = args[1], 2
      end

      local deadline = timeout and (node.world.time + timeout) or nil
      while true do
        local remaining = deadline and (deadline - node.world.time) or nil
        if remaining and remaining <= 0 then return nil end

        local sig = table.pack(computer.pullSignal(remaining))
        if sig[1] == nil then return nil end

        if args.n < first then
          return table.unpack(sig, 1, sig.n)
        end
        for i = first, args.n do
          if args[i] == nil or sig[1] == args[i] then
            return table.unpack(sig, 1, sig.n)
          end
        end
      end
    end,

    push = function(...) return computer.pushSignal(...) end,
  }
end

-- ============================================================ scheduler ====

function World:_deliverDue()
  if #self.inflight == 0 then return end

  local remaining = {}
  for _, pkt in ipairs(self.inflight) do
    if pkt.at <= self.time then
      local to = pkt.to
      if to.up and to.openPorts[pkt.port] then
        local distance = 0
        if to:push("modem_message", to.address, pkt.from.address,
                   pkt.port, distance,
                   table.unpack(pkt.values, 1, pkt.values.n)) then
          self.stats.delivered = self.stats.delivered + 1
        end
      end
    else
      remaining[#remaining + 1] = pkt
    end
  end
  self.inflight = remaining
end

function World:_resumeRunnable()
  local ran = false

  for _, node in ipairs(self.order) do
    local runnable = node.up
      and node.co
      and coroutine.status(node.co) == "suspended"
      and (#node.queue > 0 or not node.wake or node.wake <= self.time)

    if runnable then
      ran = true
      local ok, result = coroutine.resume(node.co)

      if not ok then
        io.write(string.format("[%8.3f] %-10s PANIC %s\n",
          self.time, node.name, tostring(result)))
        node.up = false
        node.co = nil
      elseif coroutine.status(node.co) == "dead" then
        self:log("%s halted", node.name)
        node.co = nil
      else
        node.wake = (type(result) == "table") and result.wake or nil
      end
    end
  end

  return ran
end

function World:_nextEventTime()
  local next_

  for _, pkt in ipairs(self.inflight) do
    if not next_ or pkt.at < next_ then next_ = pkt.at end
  end

  for _, node in ipairs(self.order) do
    if node.up and node.co and coroutine.status(node.co) == "suspended" then
      if node.wake and (not next_ or node.wake < next_) then
        next_ = node.wake
      end
    end
  end

  return next_
end

--- Advance the world by `duration` seconds of virtual time.
function World:run(duration)
  local endTime = self.time + duration
  local steps = 0

  while self.time <= endTime do
    steps = steps + 1
    if steps > self.stepLimit then
      error("sim: step limit exceeded -- a node is probably spinning "
            .. "without yielding", 0)
    end

    self:_deliverDue()

    if not self:_resumeRunnable() then
      local next_ = self:_nextEventTime()
      if not next_ or next_ > endTime then
        self.time = endTime
        break
      end
      -- Never move backwards, and always make progress.
      self.time = math.max(next_, self.time + 1e-9)
    end
  end
end

M.World = World
M.Node  = Node

return M
