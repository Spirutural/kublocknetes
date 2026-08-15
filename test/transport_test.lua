local T   = require("test.init")
local sim = require("oc")

T.describe("transport :: rpc over the sim network")

-- Server program. Written as a string because that is how it will really
-- travel: node code is shipped over the wire and loaded in a sandbox.
local SERVER = [[
  local transport = require("transport")
  local t = transport.new({ port = 6443, timeout = 2, retries = 4 }):open()

  local calls = 0

  t:handle("ping", function() return { pong = true } end)

  t:handle("echo", function(args) return args end)

  t:handle("big", function(args)
    return { blob = string.rep("B", args.size) }
  end)

  t:handle("explode", function() error("handler blew up") end)

  -- Deliberately non-idempotent, to prove the response cache works.
  t:handle("count", function()
    calls = calls + 1
    return { calls = calls }
  end)

  SHARED.serverStats = t.stats
  t:serve()
]]

local function newCluster(cfg)
  local world  = sim.newWorld(cfg)
  local server = world:addNode({ name = "server" })
  local client = world:addNode({ name = "client" })
  server:boot(server:loadstring(SERVER, "server"))
  return world, server, client
end

T.test("round trip on a clean network", function()
  local world, server, client = newCluster({ seed = 1 })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 6443 }):open()
    SHARED.result = { t:call(SERVER_ADDR, "ping", {}) }
  ]], "client"))

  client:_env().SERVER_ADDR = server.address
  world:run(30)

  local result = world.shared.result
  T.ok(result, "client produced a result")
  T.ok(result[1], "no error: " .. tostring(result[2]))
  T.eq(result[1].pong, true, "pong")
end)

T.test("arguments survive the round trip", function()
  local world, server, client = newCluster({ seed = 2 })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 6443 }):open()
    SHARED.result = t:call(SERVER_ADDR, "echo", {
      name  = "kubelet",
      count = 42,
      flag  = true,
      list  = { 1, 2, 3 },
      nest  = { deep = { value = "ok" } },
    })
  ]], "client"))

  client:_env().SERVER_ADDR = server.address
  world:run(30)

  local r = world.shared.result
  T.ok(r, "got result")
  T.eq(r.name, "kubelet")
  T.eq(r.count, 42)
  T.eq(r.flag, true)
  T.eq(r.list[3], 3)
  T.eq(r.nest.deep.value, "ok")
end)

T.test("payload larger than one packet is chunked and rebuilt", function()
  local world, server, client = newCluster({ seed = 3 })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 6443, timeout = 5 }):open()
    local res, err = t:call(SERVER_ADDR, "big", { size = 50000 })
    SHARED.len = res and #res.blob or nil
    SHARED.err = err
  ]], "client"))

  client:_env().SERVER_ADDR = server.address
  world:run(60)

  T.eq(world.shared.len, 50000, "blob length (err: "
    .. tostring(world.shared.err) .. ")")
end)

T.test("handler errors come back as errors, not hangs", function()
  local world, server, client = newCluster({ seed = 4 })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 6443 }):open()
    local res, err = t:call(SERVER_ADDR, "explode", {})
    SHARED.res, SHARED.err = res, err
  ]], "client"))

  client:_env().SERVER_ADDR = server.address
  world:run(30)

  T.nilish(world.shared.res, "no result")
  T.ok(world.shared.err, "got an error")
  T.ok(tostring(world.shared.err):find("blew up"), "error propagated")
end)

T.test("unknown method is reported immediately", function()
  local world, server, client = newCluster({ seed = 5 })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 6443 }):open()
    local res, err = t:call(SERVER_ADDR, "nope", {})
    SHARED.err = err
  ]], "client"))

  client:_env().SERVER_ADDR = server.address
  world:run(30)

  T.ok(tostring(world.shared.err):find("no such method"), "clear error")
end)

T.test("rpc survives a 25% packet loss network", function()
  local world, server, client = newCluster({ seed = 7, lossRate = 0.25 })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 6443, timeout = 2, retries = 12 }):open()

    local ok, failed = 0, 0
    for i = 1, 20 do
      local res = t:call(SERVER_ADDR, "ping", {})
      if res then ok = ok + 1 else failed = failed + 1 end
    end

    SHARED.ok, SHARED.failed, SHARED.retries = ok, failed, t.stats.retries
  ]], "client"))

  client:_env().SERVER_ADDR = server.address
  world:run(600)

  T.eq(world.shared.ok, 20,
    "all calls eventually succeeded (failed=" .. tostring(world.shared.failed) .. ")")
  T.ok(world.shared.retries > 0, "retries were actually exercised")
  T.ok(world.stats.lost > 0, "the network really did drop packets")
end)

T.test("retried request is answered from cache, not re-executed", function()
  -- Loss high enough that responses get dropped and the client resends a
  -- request the server has already run.
  local world, server, client = newCluster({ seed = 11, lossRate = 0.4 })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 6443, timeout = 2, retries = 15 }):open()
    local res = t:call(SERVER_ADDR, "count", {})
    SHARED.calls   = res and res.calls
    SHARED.retries = t.stats.retries
  ]], "client"))

  client:_env().SERVER_ADDR = server.address
  world:run(600)

  T.eq(world.shared.calls, 1,
    "handler ran exactly once despite " .. tostring(world.shared.retries) .. " retries")
end)

T.test("a dead node times out instead of hanging forever", function()
  local world, server, client = newCluster({ seed = 13 })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 6443, timeout = 1, retries = 3 }):open()
    local res, err = t:call(SERVER_ADDR, "ping", {})
    SHARED.err = err
    SHARED.finishedAt = os.clock()
  ]], "client"))

  client:_env().SERVER_ADDR = server.address

  -- Kill it while the first request is still in flight, which is the case a
  -- reconciler actually hits: the node was alive when we decided to call it.
  world:run(0.01)
  server:crash()
  world:run(60)

  T.eq(world.shared.err, "timeout", "timed out cleanly")
  T.ok(world.shared.finishedAt < 10, "gave up promptly")
end)

T.test("packets above maxPacketSize are rejected at send time", function()
  local world = sim.newWorld({ seed = 17, maxPacketSize = 1024 })
  local a = world:addNode({ name = "a" })
  local b = world:addNode({ name = "b" })

  b:boot(b:loadstring([[
    local component = require("component")
    component.getPrimary("modem").open(100)
    require("computer").pullSignal()
  ]], "b"))

  a:boot(a:loadstring([[
    local component = require("component")
    local modem = component.getPrimary("modem")
    SHARED.ok, SHARED.err = pcall(modem.send, TARGET, 100, string.rep("x", 5000))
  ]], "a"))

  a:_env().TARGET = b.address
  world:run(10)

  T.eq(world.shared.ok, false, "send should have failed")
  T.ok(tostring(world.shared.err):find("too big"), "clear error message")
end)

T.test("a full signal queue drops packets silently", function()
  local world = sim.newWorld({ seed = 19, maxQueueSize = 8, latency = 0.01, jitter = 0 })
  local sender = world:addNode({ name = "sender" })
  local victim = world:addNode({ name = "victim" })

  -- Opens its port, then never pumps the queue.
  victim:boot(victim:loadstring([[
    require("component").getPrimary("modem").open(100)
    require("computer").pullSignal()
  ]], "victim"))

  sender:boot(sender:loadstring([[
    local modem = require("component").getPrimary("modem")
    for i = 1, 100 do modem.send(TARGET, 100, "flood " .. i) end
  ]], "sender"))

  sender:_env().TARGET = victim.address
  world:run(10)

  T.ok(world.stats.dropped > 0,
    "overflow dropped packets (dropped=" .. world.stats.dropped .. ")")
  T.ok(victim.dropped > 0, "the victim is the one that dropped them")
end)
