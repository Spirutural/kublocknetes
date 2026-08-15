--[[ kublocknetes :: sshd

     Remote shell over the OC network. OpenOS has no equivalent.

     ON THE NAME. This is not SSH. There is no key exchange, no forward
     secrecy, and no transport encryption -- every modem on the network sees
     the traffic. What it does provide is authentication, replay resistance
     when a Data Card is present, and failed-attempt lockout. Treat it as
     "authenticated remote exec on a trusted wire", and if the wire is not
     trusted, do not rely on this.

     Auth modes, chosen automatically by what you pass in:

       none    no secret configured. Anyone on the network can run commands.
       secret  shared secret sent in the clear. Honest but weak: anyone
               sniffing the wire learns it on first use.
       hmac    a Data Card is present. Server issues a single-use nonce,
               client returns digest(nonce .. secret). The secret never
               crosses the wire and a captured response cannot be replayed.

     This module deliberately knows nothing about OpenOS. Command execution
     arrives as an injected `executor`, and the digest as an injected
     `digest`, so the base-OS surface stays locked (component, computer,
     serialization only) and the whole protocol is testable in the simulator
     against a fake executor. The OpenOS-specific glue lives in bin/sshd.lua.
]]

local computer = require("computer")

local sshd = {}

local PROTOCOL = 1

local S = {}
S.__index = S

--- Create a server.
--  opts.transport   required, a transport bound to a port (22 by convention)
--  opts.executor    required, function(cmd) -> output:string, exitCode:number
--  opts.secret      shared secret; omit for an open server
--  opts.digest      function(string) -> string; enables hmac mode
--  opts.maxOutput   bytes of output per command before truncation
function sshd.new(opts)
  assert(opts and opts.transport, "sshd: transport required")
  assert(opts.executor, "sshd: executor required")

  return setmetatable({
    transport   = opts.transport,
    executor    = opts.executor,
    secret      = opts.secret,
    digest      = opts.digest,
    -- Called per request rather than captured, so renaming a live machine
    -- takes effect without restarting the daemon.
    hostnameFn  = opts.hostname or function() return nil end,

    maxOutput   = opts.maxOutput or 32768,
    maxFailures = opts.maxFailures or 5,
    lockout     = opts.lockout or 60,
    nonceTTL    = opts.nonceTTL or 120,

    nonces      = {},
    failures    = {},
    counter     = 0,

    stats = { execs = 0, denied = 0, lockouts = 0 },
  }, S)
end

function S:mode()
  if not self.secret then return "none" end
  return self.digest and "hmac" or "secret"
end

-- ------------------------------------------------------------- nonces ----

function S:_issueNonce(peer)
  self.counter = self.counter + 1
  local nonce = string.format("%d.%.3f.%s",
    self.counter, computer.uptime(), tostring(peer):sub(1, 8))
  self.nonces[peer] = { value = nonce, at = computer.uptime() }
  return nonce
end

function S:_takeNonce(peer)
  local entry = self.nonces[peer]
  self.nonces[peer] = nil  -- single use, always consumed even on failure
  if not entry then return nil end
  if computer.uptime() - entry.at > self.nonceTTL then return nil end
  return entry.value
end

-- ---------------------------------------------------------------- auth ----

function S:_noteFailure(peer)
  local f = self.failures[peer] or { count = 0 }
  f.count = f.count + 1
  f.at = computer.uptime()
  self.failures[peer] = f
  self.stats.denied = self.stats.denied + 1
  if f.count == self.maxFailures then
    self.stats.lockouts = self.stats.lockouts + 1
  end
end

function S:_lockedOut(peer)
  local f = self.failures[peer]
  if not f or f.count < self.maxFailures then return false end
  if computer.uptime() - f.at >= self.lockout then
    self.failures[peer] = nil  -- lockout expired, forgive
    return false
  end
  return true
end

--- Returns true, or false plus a reason.
function S:_authorize(args, peer)
  local mode = self:mode()
  if mode == "none" then return true end

  if self:_lockedOut(peer) then
    return false, "locked out: too many failed attempts"
  end

  local presented = args and args.cred
  local expected

  if mode == "hmac" then
    local nonce = self:_takeNonce(peer)
    if not nonce then
      return false, "no valid nonce; call ssh.hello first"
    end
    expected = self.digest(nonce .. self.secret)
  else
    expected = self.secret
  end

  -- Not a constant-time comparison. Lua string equality short-circuits, so
  -- this leaks timing. Irrelevant against a Minecraft attacker; stated so
  -- nobody later mistakes this for a hardened implementation.
  if presented ~= expected then
    self:_noteFailure(peer)
    return false, "authentication failed"
  end

  self.failures[peer] = nil
  return true
end

-- ------------------------------------------------------------ handlers ----

function S:_hello(_, ctx)
  return {
    protocol = PROTOCOL,
    mode     = self:mode(),
    host     = computer.address(),
    hostname = self.hostnameFn(),
    nonce    = self.secret and self:_issueNonce(ctx.from) or nil,
  }
end

function S:_exec(args, ctx)
  local ok, reason = self:_authorize(args, ctx.from)
  if not ok then error(reason, 0) end

  local cmd = args and args.cmd
  if type(cmd) ~= "string" or cmd:match("^%s*$") then
    error("no command given", 0)
  end

  local out, code = self.executor(cmd)
  out = tostring(out or "")

  local truncated = false
  if #out > self.maxOutput then
    out = out:sub(1, self.maxOutput)
    truncated = true
  end

  self.stats.execs = self.stats.execs + 1

  return {
    out       = out,
    code      = code or 0,
    truncated = truncated,
    -- Hand out the next nonce here so a session costs one round trip per
    -- command rather than two. Packets are expensive; see docs/hardware.md.
    nonce     = (self:mode() == "hmac") and self:_issueNonce(ctx.from) or nil,
  }
end

function S:install()
  self.transport:handle("ssh.hello", function(a, ctx) return self:_hello(a, ctx) end)
  self.transport:handle("ssh.exec",  function(a, ctx) return self:_exec(a, ctx) end)
  return self
end

return sshd
