--[[ kublocknetes :: transport

     Request/response RPC over the OC modem network.

     Design notes, since the failure model here is unusual:

     * Retry is whole-message, not per-chunk. Chunk-level acknowledgement
       would cost a round trip per 8KB and buy little: if one chunk of a
       message was dropped for queue-overflow reasons, its siblings very
       likely were too.

     * Every request carries a stable id, and servers cache their last N
       responses keyed by it. A retry of a request that already executed
       returns the cached response instead of running the handler twice.
       This is what makes non-idempotent handlers safe to retry.

     * `call` pumps the event loop while it waits, so a node that is waiting
       on a reply still serves incoming requests. Without this, any two nodes
       that call each other at the same moment deadlock until timeout.

     * Nothing here retries forever. Above this layer, controllers reconcile
       on a timer, so a permanently failed call is not an emergency -- it is
       just this pass doing nothing. Let it fail and try again next sweep.
]]

local component     = require("component")
local computer      = require("computer")
local serialization = require("serialization")
local wire          = require("wire")

local transport = {}

--- Sentinel a handler may return to decline to answer at all.
--  Essential for broadcasts: without it, asking "who is called kubelet-1?"
--  draws an error reply from every machine that isn't, which is both a
--  packet storm and a pile of useless results to filter.
transport.NO_REPLY = setmetatable({}, {
  __tostring = function() return "NO_REPLY" end,
})

local T = {}
T.__index = T

--- Create a transport bound to a port.
--  opts.port      port to listen/send on (default 6443, the apiserver port)
--  opts.timeout   seconds to wait for a reply before retrying
--  opts.retries   attempts per call, including the first
function transport.new(opts)
  opts = opts or {}

  local modem = opts.modem or component.getPrimary("modem")

  local self = setmetatable({
    modem     = modem,
    address   = opts.address or computer.address(),
    port      = opts.port or 6443,
    maxPacket = opts.maxPacketSize or modem.maxPacketSize(),
    timeout   = opts.timeout or 2,
    retries   = opts.retries or 3,

    handlers  = {},
    pending   = {},
    reasm     = wire.newReassembler({ ttl = opts.ttl or 15 }),

    seq        = 0,
    cache      = {},
    cacheOrder = {},
    cacheMax   = opts.cacheSize or 16,

    stats = { sent = 0, received = 0, retries = 0, timeouts = 0, served = 0 },
  }, T)

  return self
end

function T:open()
  self.modem.open(self.port)
  return self
end

function T:close()
  self.modem.close(self.port)
end

--- Register a server-side method.
function T:handle(method, fn)
  self.handlers[method] = fn
  return self
end

-- ------------------------------------------------------------ internals ----

function T:_nextId()
  self.seq = self.seq + 1
  return string.format("%s#%d", self.address:sub(1, 8), self.seq)
end

function T:_transmit(target, envelope, wireId)
  local payload = serialization.serialize(envelope)
  local packets = wire.frame(wireId, payload, self.maxPacket)

  for _, packet in ipairs(packets) do
    if target then
      self.modem.send(target, self.port, table.unpack(packet))
    else
      self.modem.broadcast(self.port, table.unpack(packet))
    end
    self.stats.sent = self.stats.sent + 1
  end
end

function T:_remember(id, reply)
  if self.cache[id] then return end

  self.cache[id] = reply
  self.cacheOrder[#self.cacheOrder + 1] = id

  if #self.cacheOrder > self.cacheMax then
    local evicted = table.remove(self.cacheOrder, 1)
    self.cache[evicted] = nil
  end
end

function T:_dispatch(from, env)
  if env.k == "req" then
    -- Duplicate of something already answered: replay, do not re-run.
    local cached = self.cache[env.id]
    if cached then
      self:_transmit(from, cached, self:_nextId())
      return
    end

    local reply
    local handler = self.handlers[env.m]

    if not handler then
      reply = { k = "err", id = env.id, e = "no such method: " .. tostring(env.m) }
    else
      local ok, result = pcall(handler, env.a, { from = from, transport = self })
      if ok then
        -- Declining to answer must not be cached either: a later, matching
        -- query with a recycled id would otherwise get the silence replayed.
        if result == transport.NO_REPLY then return end
        reply = { k = "res", id = env.id, r = result }
      else
        reply = { k = "err", id = env.id, e = tostring(result) }
      end
      self.stats.served = self.stats.served + 1
    end

    self:_remember(env.id, reply)
    self:_transmit(from, reply, self:_nextId())

  elseif env.k == "res" or env.k == "err" then
    local waiter = self.pending[env.id]
    if not waiter then return end

    -- A discovery waits for many answers; a call waits for one.
    if waiter.multi then
      if env.k == "res" then
        waiter.replies[#waiter.replies + 1] = { from = from, result = env.r }
      end
    else
      waiter.done   = true
      waiter.result = env.r
      waiter.err    = env.e
    end
  end
end

--- Process at most one inbound signal. Returns true if it was ours.
function T:pump(timeout)
  local sig = table.pack(computer.pullSignal(timeout))

  if sig[1] ~= "modem_message" then return false end
  if sig[4] ~= self.port then return false end

  self.stats.received = self.stats.received + 1

  local payload = self.reasm:feed(
    computer.uptime(), sig[6], sig[7], sig[8], sig[9], sig[10])
  if not payload then return true end

  local env = serialization.unserialize(payload)
  if type(env) == "table" then
    self:_dispatch(sig[3], env)
  end

  return true
end

--- Serve requests. Runs for `duration` seconds, or forever if nil.
function T:serve(duration)
  local deadline = duration and (computer.uptime() + duration) or nil

  while true do
    if deadline then
      local remaining = deadline - computer.uptime()
      if remaining <= 0 then return end
      self:pump(remaining)
    else
      self:pump(1)
    end
  end
end

--- Broadcast a request and collect every answer within the timeout.
--  Returns a list of { from = address, result = value }.
--
--  Unlike `call` this never retries: a discovery that finds nothing is a
--  normal outcome, not a failure, and the caller sweeps again later.
--  Handlers that have nothing to say should return transport.NO_REPLY.
--
--  opts.timeout  seconds to listen for replies
--  opts.first    stop at the first answer instead of waiting out the window
function T:discover(method, args, opts)
  opts = opts or {}
  local timeout = opts.timeout or 2

  local id = self:_nextId()
  local waiter = { multi = true, replies = {} }
  self.pending[id] = waiter

  self:_transmit(nil, { k = "req", id = id, m = method, a = args }, id .. "/b")

  local deadline = computer.uptime() + timeout
  while computer.uptime() < deadline do
    self:pump(deadline - computer.uptime())
    if opts.first and #waiter.replies > 0 then break end
  end

  self.pending[id] = nil
  return waiter.replies
end

--- Call a method on a remote node. Blocks (yielding) until reply or timeout.
--  Returns result, or nil plus an error string.
function T:call(target, method, args, opts)
  opts = opts or {}
  local timeout = opts.timeout or self.timeout
  local retries = opts.retries or self.retries

  local id  = self:_nextId()
  local env = { k = "req", id = id, m = method, a = args }

  local waiter = { done = false }
  self.pending[id] = waiter

  for attempt = 1, retries do
    if attempt > 1 then self.stats.retries = self.stats.retries + 1 end

    -- Distinct wire id per attempt so a resend never merges with the stale
    -- partial chunks of a previous one.
    self:_transmit(target, env, id .. "/" .. attempt)

    local deadline = computer.uptime() + timeout
    while computer.uptime() < deadline do
      self:pump(deadline - computer.uptime())
      if waiter.done then
        self.pending[id] = nil
        if waiter.err then return nil, waiter.err end
        return waiter.result
      end
    end
  end

  self.pending[id] = nil
  self.stats.timeouts = self.stats.timeouts + 1
  return nil, "timeout"
end

return transport
