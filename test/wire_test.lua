local T    = require("test.init")
local wire = require("wire")

T.describe("wire :: framing")

T.test("small message is a single packet", function()
  local packets = wire.frame("m1", "hello", 8192)
  T.eq(#packets, 1, "packet count")
  T.eq(packets[1][1], wire.MAGIC, "magic")
  T.eq(packets[1][3], 1, "seq")
  T.eq(packets[1][4], 1, "total")
  T.eq(packets[1][5], "hello", "chunk")
end)

T.test("empty payload still produces one packet", function()
  local packets = wire.frame("m1", "", 8192)
  T.eq(#packets, 1, "packet count")
  T.eq(packets[1][5], "", "chunk")
end)

T.test("large message splits and every chunk fits", function()
  local payload = string.rep("x", 40000)
  local packets = wire.frame("m1", payload, 8192)
  T.ok(#packets > 1, "should split")

  local limit = wire.chunkSize(8192)
  for _, p in ipairs(packets) do
    T.ok(#p[5] <= limit, "chunk within budget")
  end
  T.eq(#packets, math.ceil(#payload / limit), "chunk count")
end)

T.test("rejects a packet size too small to frame", function()
  local ok = pcall(wire.frame, "m1", "x", 32)
  T.eq(ok, false, "should error")
end)

T.describe("wire :: reassembly")

local function roundtrip(payload, maxPacket, mangle)
  local packets = wire.frame("m1", payload, maxPacket)
  if mangle then packets = mangle(packets) end

  local r = wire.newReassembler()
  local result
  for _, p in ipairs(packets) do
    result = r:feed(0, table.unpack(p)) or result
  end
  return result, r
end

T.test("single-chunk round trip", function()
  T.eq(roundtrip("hello", 8192), "hello")
end)

T.test("multi-chunk round trip", function()
  local payload = string.rep("abcdefgh", 5000)
  T.eq(roundtrip(payload, 8192), payload)
end)

T.test("out-of-order chunks reassemble correctly", function()
  local payload = string.rep("y", 30000)
  local result = roundtrip(payload, 8192, function(packets)
    local reversed = {}
    for i = #packets, 1, -1 do reversed[#reversed + 1] = packets[i] end
    return reversed
  end)
  T.eq(result, payload)
end)

T.test("duplicate chunks are counted, not double-appended", function()
  local payload = string.rep("z", 30000)
  local result, r = roundtrip(payload, 8192, function(packets)
    local doubled = {}
    for _, p in ipairs(packets) do
      doubled[#doubled + 1] = p
      doubled[#doubled + 1] = p
    end
    return doubled
  end)
  T.eq(result, payload, "payload intact")
  T.ok(r:stats().duplicates > 0, "duplicates observed")
end)

T.test("incomplete message yields nothing", function()
  local packets = wire.frame("m1", string.rep("q", 30000), 8192)
  local r = wire.newReassembler()
  local result
  for i = 1, #packets - 1 do
    result = r:feed(0, table.unpack(packets[i])) or result
  end
  T.nilish(result, "must not complete")
  T.eq(r:stats().pending, 1, "one pending")
end)

T.test("stale partials are evicted rather than leaked", function()
  local packets = wire.frame("m1", string.rep("q", 30000), 8192)
  local r = wire.newReassembler({ ttl = 5 })
  r:feed(0, table.unpack(packets[1]))
  T.eq(r:stats().pending, 1, "pending before")

  -- A later, unrelated multi-chunk message triggers the sweep.
  local other = wire.frame("m2", string.rep("w", 30000), 8192)
  r:feed(100, table.unpack(other[1]))

  T.eq(r:stats().evicted, 1, "evicted the stale one")
  T.eq(r:stats().pending, 1, "only the new one remains")
end)

T.test("pending table is hard-capped", function()
  local r = wire.newReassembler({ ttl = 1000, maxPending = 4 })
  for i = 1, 20 do
    local packets = wire.frame("msg" .. i, string.rep("a", 30000), 8192)
    r:feed(0, table.unpack(packets[1]))
  end
  T.ok(r:stats().pending <= 4, "cap respected, got " .. r:stats().pending)
end)

T.test("foreign and malformed packets are ignored", function()
  local r = wire.newReassembler()
  T.nilish(r:feed(0, "NOPE", "m1", 1, 1, "data"), "wrong magic")
  T.nilish(r:feed(0, wire.MAGIC, "m1", 0, 1, "data"), "seq below range")
  T.nilish(r:feed(0, wire.MAGIC, "m1", 3, 2, "data"), "seq above total")
  T.nilish(r:feed(0, wire.MAGIC, 12345, 1, 1, "data"), "non-string id")
end)
