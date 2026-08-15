--[[ kublocknetes :: wire

     Message framing for the OC network.

     Two hard limits shape everything above this layer:

       1. A modem packet has a maximum size (typically 8192 bytes) and a
          maximum number of values per send. Any message larger than that
          must be split and reassembled.

       2. A machine's signal queue is bounded (typically 256). Overflow is
          silent -- the packet is simply gone, with no error anywhere. So
          reassembly must assume chunks arrive out of order, duplicated, or
          not at all, and must never leak memory waiting for a chunk that is
          never coming.

     This module does framing only. Retry and acknowledgement live in
     transport.lua, because at this layer we have no idea whether a missing
     chunk is worth waiting for.
]]

local wire = {}

wire.MAGIC   = "K8M1"
wire.PARTS   = 5  -- MAGIC, msgId, seq, total, chunk

-- Bytes of packet budget consumed by everything that is not payload. The
-- header values are small, but OC charges per value, so leave real slack.
wire.OVERHEAD = 128

--- Largest payload chunk that fits in one packet of the given size.
function wire.chunkSize(maxPacketSize)
  local size = (maxPacketSize or 8192) - wire.OVERHEAD
  if size < 64 then
    error("wire: maxPacketSize too small to frame messages", 2)
  end
  return size
end

--- Split a serialized payload into a list of packet argument lists.
--  Each entry is ready to unpack straight into modem.send/broadcast.
function wire.frame(msgId, payload, maxPacketSize)
  local chunkSize = wire.chunkSize(maxPacketSize)
  local length = #payload
  local total = length > 0 and math.ceil(length / chunkSize) or 1

  local packets = {}
  for i = 1, total do
    local chunk = payload:sub((i - 1) * chunkSize + 1, i * chunkSize)
    packets[i] = { wire.MAGIC, msgId, i, total, chunk }
  end
  return packets
end

-- ------------------------------------------------------------------------

local Reassembler = {}
Reassembler.__index = Reassembler

--- Reassembles chunked messages.
--  opts.ttl         seconds an incomplete message may sit before eviction
--  opts.maxPending  hard cap on in-flight messages (memory ceiling)
function wire.newReassembler(opts)
  opts = opts or {}
  return setmetatable({
    pending    = {},
    count      = 0,
    ttl        = opts.ttl or 15,
    maxPending = opts.maxPending or 24,
    evicted    = 0,
    duplicates = 0,
  }, Reassembler)
end

function Reassembler:_evict(now)
  local cutoff = now - self.ttl
  for id, entry in pairs(self.pending) do
    if entry.touched < cutoff then
      self.pending[id] = nil
      self.count = self.count - 1
      self.evicted = self.evicted + 1
    end
  end
end

--- Feed one received packet.
--  Returns the complete payload string once every chunk has arrived,
--  otherwise nil. Returns nil for anything that is not ours.
function Reassembler:feed(now, magic, msgId, seq, total, chunk)
  if magic ~= wire.MAGIC then return nil end
  if type(msgId) ~= "string" or type(chunk) ~= "string" then return nil end

  seq, total = math.tointeger(seq), math.tointeger(total)
  if not seq or not total or seq < 1 or total < 1 or seq > total then
    return nil
  end

  -- Single-chunk messages are the overwhelming majority. Never touch the
  -- pending table for them.
  if total == 1 then
    return chunk
  end

  local entry = self.pending[msgId]
  if not entry then
    self:_evict(now)

    -- Still over the cap after eviction: drop the oldest rather than grow.
    if self.count >= self.maxPending then
      local oldestId, oldestAt
      for id, e in pairs(self.pending) do
        if not oldestAt or e.touched < oldestAt then
          oldestId, oldestAt = id, e.touched
        end
      end
      if oldestId then
        self.pending[oldestId] = nil
        self.count = self.count - 1
        self.evicted = self.evicted + 1
      end
    end

    entry = { chunks = {}, have = 0, total = total, touched = now }
    self.pending[msgId] = entry
    self.count = self.count + 1
  end

  entry.touched = now

  if entry.chunks[seq] then
    self.duplicates = self.duplicates + 1
    return nil
  end

  entry.chunks[seq] = chunk
  entry.have = entry.have + 1

  if entry.have < entry.total then return nil end

  local payload = table.concat(entry.chunks)
  self.pending[msgId] = nil
  self.count = self.count - 1
  return payload
end

function Reassembler:stats()
  return {
    pending    = self.count,
    evicted    = self.evicted,
    duplicates = self.duplicates,
  }
end

return wire
