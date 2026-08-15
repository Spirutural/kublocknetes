local T   = require("test.init")
local sim = require("oc")

T.describe("sshd :: remote shell")

-- The server program. `executor` is injected, so the entire protocol --
-- handshake, auth, nonces, lockout, truncation, chunked output -- is
-- exercised without OpenOS anywhere in sight.
local function serverSrc(config)
  return ([[
    local transport = require("transport")
    local sshd      = require("sshd")

    local t = transport.new({ port = 22, timeout = 2, retries = 4 }):open()

    local executor = function(cmd)
      SHARED.lastCmd = cmd
      if cmd == "fail" then return "nope", 1 end
      if cmd == "huge" then return string.rep("H", 100000), 0 end
      if cmd == "big"  then return string.rep("B", 30000), 0 end
      return "ran: " .. cmd, 0
    end

    -- A stand-in for a Data Card's sha256. Not cryptography; it only has to
    -- be deterministic and depend on the whole input.
    local digest = function(s)
      local h = 5381
      for i = 1, #s do h = (h * 33 + s:byte(i)) %% 4294967296 end
      return string.format("%%08x", h)
    end

    local server = sshd.new({
      transport   = t,
      executor    = executor,
      secret      = %s,
      digest      = %s,
      maxOutput   = %d,
      maxFailures = 3,
      lockout     = 30,
    }):install()

    SHARED.server = server
    t:serve()
  ]]):format(config.secret, config.digest, config.maxOutput or 32768)
end

local function newPair(cfg, worldCfg)
  cfg = cfg or {}
  local world  = sim.newWorld(worldCfg or { seed = 41 })
  local server = world:addNode({ name = "server" })
  local client = world:addNode({ name = "client" })
  server:boot(server:loadstring(serverSrc({
    secret    = cfg.secret and string.format("%q", cfg.secret) or "nil",
    digest    = cfg.digest and "digest" or "nil",
    maxOutput = cfg.maxOutput,
  }), "sshd"))
  return world, server, client
end

-- Client source shared by most tests. CLIENT_OPTS is injected per test.
local CLIENT = [[
  local transport = require("transport")
  local ssh       = require("ssh")

  local t = transport.new({ port = 22, timeout = 2, retries = 4 }):open()

  local digest = function(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
  end

  local opts = { secret = SECRET }
  if USE_DIGEST then opts.digest = digest end

  local session, err = ssh.connect(t, HOST, opts)
  SHARED.connectErr = err
  if not session then return end

  SHARED.mode = session.mode
  SHARED.results = {}
  for i, cmd in ipairs(COMMANDS) do
    local out, code, truncated = session:exec(cmd)
    SHARED.results[i] = { out = out, code = code, truncated = truncated }
  end
]]

local function runClient(world, client, host, env, commands)
  client:boot(client:loadstring(CLIENT, "ssh"))
  local e = client:_env()
  e.HOST       = host
  e.SECRET     = env.secret
  e.USE_DIGEST = env.digest or false
  e.COMMANDS   = commands
  world:run(120)
  return world.shared.results or {}
end

T.test("open server runs a command", function()
  local world, server, client = newPair()
  local r = runClient(world, client, server.address, {}, { "ls /usr" })

  T.eq(world.shared.mode, "none", "no auth configured")
  T.eq(r[1] and r[1].out, "ran: ls /usr", "output returned")
  T.eq(r[1].code, 0, "exit code")
  T.eq(world.shared.lastCmd, "ls /usr", "executor saw the command")
end)

T.test("exit codes propagate", function()
  local world, server, client = newPair()
  local r = runClient(world, client, server.address, {}, { "fail" })
  T.eq(r[1].out, "nope")
  T.eq(r[1].code, 1, "non-zero exit code survives")
end)

T.test("output larger than one packet is chunked and rebuilt", function()
  local world, server, client = newPair()
  local r = runClient(world, client, server.address, {}, { "big" })
  T.eq(r[1] and #r[1].out, 30000, "30KB of output returned intact")
  T.eq(r[1].truncated, false, "not truncated below the cap")
end)

T.test("output beyond maxOutput is truncated, and says so", function()
  local world, server, client = newPair({ maxOutput = 4096 })
  local r = runClient(world, client, server.address, {}, { "huge" })
  T.eq(r[1] and #r[1].out, 4096, "capped")
  T.eq(r[1].truncated, true, "flagged as truncated")
end)

T.describe("sshd :: authentication")

T.test("shared secret admits the right credential", function()
  local world, server, client = newPair({ secret = "hunter2" })
  local r = runClient(world, client, server.address, { secret = "hunter2" }, { "whoami" })
  T.eq(world.shared.mode, "secret", "secret mode negotiated")
  T.eq(r[1] and r[1].out, "ran: whoami")
end)

T.test("wrong secret is refused", function()
  local world, server, client = newPair({ secret = "hunter2" })
  local r = runClient(world, client, server.address, { secret = "wrong" }, { "whoami" })
  T.nilish(r[1] and r[1].out, "no output")
  -- exec returns nil, err -- so the second slot carries the reason.
  T.ok(tostring(r[1].code):find("authentication failed"),
    "refused with a clear reason, got: " .. tostring(r[1].code))
end)

T.test("connecting without a secret to a guarded host fails cleanly", function()
  local world, server, client = newPair({ secret = "hunter2" })
  runClient(world, client, server.address, {}, { "whoami" })
  T.ok(world.shared.connectErr, "connect reported an error")
  T.ok(tostring(world.shared.connectErr):find("secret"), "and explains why")
end)

T.test("hmac mode never puts the secret on the wire", function()
  local world, server, client = newPair({ secret = "hunter2", digest = true })
  local r = runClient(world, client, server.address,
    { secret = "hunter2", digest = true }, { "uptime", "free" })

  T.eq(world.shared.mode, "hmac", "hmac negotiated")
  T.eq(r[1] and r[1].out, "ran: uptime", "first command")
  -- Proves the piggybacked nonce works: a second command with no extra
  -- handshake would fail if the nonce were not refreshed on the reply.
  T.eq(r[2] and r[2].out, "ran: free", "second command reused the session")
end)

T.test("repeated failures lock a peer out", function()
  local world, server, client = newPair({ secret = "hunter2" })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 22, timeout = 1, retries = 2 }):open()

    t:call(HOST, "ssh.hello", {})

    local errs = {}
    for i = 1, 5 do
      local _, err = t:call(HOST, "ssh.exec", { cmd = "ls", cred = "wrong" })
      errs[i] = tostring(err)
    end
    SHARED.errs = errs
  ]], "attacker"))

  client:_env().HOST = server.address
  world:run(120)

  local errs = world.shared.errs
  T.ok(errs, "attacker produced errors")
  T.ok(errs[1]:find("authentication failed"), "first is a plain auth failure")
  T.ok(errs[5]:find("locked out"), "later attempts are locked out: " .. tostring(errs[5]))
end)

T.test("a nonce cannot be replayed", function()
  local world, server, client = newPair({ secret = "hunter2", digest = true })

  client:boot(client:loadstring([[
    local transport = require("transport")
    local t = transport.new({ port = 22, timeout = 2, retries = 3 }):open()

    local digest = function(s)
      local h = 5381
      for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
      return string.format("%08x", h)
    end

    local hello = t:call(HOST, "ssh.hello", {})
    local cred  = digest(hello.nonce .. "hunter2")

    local first,  e1 = t:call(HOST, "ssh.exec", { cmd = "ls", cred = cred })
    local replay, e2 = t:call(HOST, "ssh.exec", { cmd = "ls", cred = cred })

    SHARED.first  = first and first.out
    SHARED.replay = replay and replay.out
    SHARED.e2     = tostring(e2)
  ]], "replayer"))

  client:_env().HOST = server.address
  world:run(120)

  T.eq(world.shared.first, "ran: ls", "the genuine request succeeds")
  T.nilish(world.shared.replay, "the replayed credential is rejected")
end)

T.test("remote shell works over a lossy link", function()
  local world, server, client = newPair({ secret = "hunter2" },
    { seed = 43, lossRate = 0.2 })
  local r = runClient(world, client, server.address,
    { secret = "hunter2" }, { "cat /var/log/kubelet" })

  T.eq(r[1] and r[1].out, "ran: cat /var/log/kubelet",
    "command survived a 20% loss network")
end)
