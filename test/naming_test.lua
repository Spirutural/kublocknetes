local T      = require("test.init")
local sim    = require("oc")
local naming = require("naming")

T.describe("naming :: address detection")

T.test("distinguishes addresses from hostnames", function()
  T.ok(naming.looksLikeAddress("b64178fb-4bc9-4be3-853f-0295adc74584"), "full uuid")
  T.ok(naming.looksLikeAddress("b64178fb"), "hex prefix")
  T.eq(naming.looksLikeAddress("smelter-ctl"), false, "hostname with a dash")
  T.eq(naming.looksLikeAddress("worker2"), false, "alphanumeric hostname")
  T.eq(naming.looksLikeAddress("cafe"), false, "short hex is too ambiguous")
  T.eq(naming.looksLikeAddress(nil), false, "nil")
end)

T.describe("naming :: resolution over the network")

local NODE = [[
  local transport = require("transport")
  local naming    = require("naming")

  local t = transport.new({ port = naming.PORT, timeout = 1, retries = 2 }):open()
  naming.serve(t, function() return HOSTNAME end)
  t:serve()
]]

local function cluster(names, worldCfg)
  local world = sim.newWorld(worldCfg or { seed = 61 })
  local nodes = {}

  for i, name in ipairs(names) do
    local node = world:addNode({ name = "n" .. i })
    node:boot(node:loadstring(NODE, "node" .. i))
    node:_env().HOSTNAME = name
    nodes[#nodes + 1] = node
  end

  local client = world:addNode({ name = "client" })
  return world, nodes, client
end

local function ask(world, client, script, env)
  client:boot(client:loadstring(script, "client"))
  for k, v in pairs(env or {}) do client:_env()[k] = v end
  world:run(60)
end

T.test("resolves a hostname to exactly one address", function()
  local world, nodes, client = cluster({ "smelter-ctl", "worker-1", "worker-2" })

  ask(world, client, [[
    local transport = require("transport")
    local naming    = require("naming")
    local t = transport.new({ port = naming.PORT }):open()
    local addr, err = naming.lookup(t, "worker-1")
    SHARED.addr, SHARED.err = addr, err
  ]])

  T.nilish(world.shared.err, "no error")
  T.eq(world.shared.addr, nodes[2].address, "resolved to the right machine")
end)

T.test("only the matching machine answers", function()
  local world, _, client = cluster({ "alpha", "beta", "gamma", "delta" })

  ask(world, client, [[
    local transport = require("transport")
    local naming    = require("naming")
    local t = transport.new({ port = naming.PORT }):open()
    SHARED.found = naming.resolve(t, "gamma")
  ]])

  T.eq(#world.shared.found, 1, "exactly one reply, not four")
  T.eq(world.shared.found[1].name, "gamma")
end)

T.test("resolution is case-insensitive", function()
  local world, nodes, client = cluster({ "Smelter-CTL" })

  ask(world, client, [[
    local transport = require("transport")
    local naming    = require("naming")
    local t = transport.new({ port = naming.PORT }):open()
    SHARED.addr = naming.lookup(t, "smelter-ctl")
  ]])

  T.eq(world.shared.addr, nodes[1].address)
end)

T.test("an unknown name fails with a clear message", function()
  local world, _, client = cluster({ "alpha", "beta" })

  ask(world, client, [[
    local transport = require("transport")
    local naming    = require("naming")
    local t = transport.new({ port = naming.PORT }):open()
    SHARED.addr, SHARED.err = naming.lookup(t, "nonexistent")
  ]])

  T.nilish(world.shared.addr, "no address")
  T.ok(tostring(world.shared.err):find("no machine answers"), "clear reason")
end)

T.test("duplicate hostnames are reported, not silently resolved", function()
  -- Two machines claiming one name is a real misconfiguration. Picking the
  -- first would turn it into a mystery weeks later.
  local world, _, client = cluster({ "worker-1", "worker-1", "worker-2" })

  ask(world, client, [[
    local transport = require("transport")
    local naming    = require("naming")
    local t = transport.new({ port = naming.PORT }):open()
    SHARED.addr, SHARED.err = naming.lookup(t, "worker-1")
  ]])

  T.nilish(world.shared.addr, "refuses to guess")
  T.ok(tostring(world.shared.err):find("2 machines"), "counts them")
  T.ok(tostring(world.shared.err):find("duplicate"), "names the problem")
end)

T.test("an address passes through without a broadcast", function()
  local world, nodes, client = cluster({ "alpha" })
  local addr = nodes[1].address

  ask(world, client, [[
    local transport = require("transport")
    local naming    = require("naming")
    local t = transport.new({ port = naming.PORT }):open()
    local before = t.stats.sent
    SHARED.addr = naming.lookup(t, TARGET)
    SHARED.sent = t.stats.sent - before
  ]], { TARGET = addr })

  T.eq(world.shared.addr, addr, "returned unchanged")
  T.eq(world.shared.sent, 0, "no packets spent resolving an address")
end)

T.test("wildcard lists every named machine", function()
  local world, _, client = cluster({ "alpha", "beta", "gamma" })

  ask(world, client, [[
    local transport = require("transport")
    local naming    = require("naming")
    local t = transport.new({ port = naming.PORT }):open()
    local all = naming.list(t)
    local names = {}
    for _, m in ipairs(all) do names[#names + 1] = m.name end
    table.sort(names)
    SHARED.names = names
  ]])

  T.eq(table.concat(world.shared.names or {}, ","), "alpha,beta,gamma")
end)

T.test("unnamed machines stay silent", function()
  local world, _, client = cluster({ "alpha", "", "gamma" })

  ask(world, client, [[
    local transport = require("transport")
    local naming    = require("naming")
    local t = transport.new({ port = naming.PORT }):open()
    SHARED.count = #naming.list(t)
  ]])

  T.eq(world.shared.count, 2, "the machine with no hostname does not answer")
end)

T.test("discovery still works on a lossy network", function()
  local world, nodes, client = cluster({ "alpha", "worker-1" },
    { seed = 67, lossRate = 0.15 })

  ask(world, client, [[
    local transport = require("transport")
    local naming    = require("naming")
    local t = transport.new({ port = naming.PORT }):open()
    -- Discovery does not retry, so sweep a few times: a miss is normal and
    -- the caller decides how hard to look.
    for _ = 1, 5 do
      local addr = naming.lookup(t, "worker-1")
      if addr then SHARED.addr = addr break end
    end
  ]])

  T.eq(world.shared.addr, nodes[2].address, "found within a few sweeps")
end)
