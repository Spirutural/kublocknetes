--[[ kublocknetes :: ssh client

     Companion to lib/sshd.lua. Knows nothing about OpenOS -- the CLI lives
     in bin/ssh.lua -- so the whole client is exercisable in the simulator.

     Usage:

       local session, err = ssh.connect(transport, hostAddress, {
         secret = "hunter2",
         digest = myDigestFn,     -- required only if the server runs hmac
       })

       local out, code = session:exec("ls /usr/lib")
]]

local ssh = {}

local Session = {}
Session.__index = Session

--- Handshake with a host. Returns a session, or nil plus an error.
function ssh.connect(transport, host, opts)
  opts = opts or {}

  local hello, err = transport:call(host, "ssh.hello", {},
    { timeout = opts.timeout, retries = opts.retries })
  if not hello then
    return nil, "handshake failed: " .. tostring(err)
  end

  if hello.mode == "hmac" and not opts.digest then
    return nil, "host requires hmac auth but no digest function was provided "
             .. "(needs a Data Card)"
  end
  if hello.mode ~= "none" and not opts.secret then
    return nil, "host requires authentication but no secret was provided"
  end

  return setmetatable({
    transport = transport,
    host      = host,
    mode      = hello.mode,
    protocol  = hello.protocol,
    remote    = hello.host,
    nonce     = hello.nonce,
    secret    = opts.secret,
    digest    = opts.digest,
    timeout   = opts.timeout,
    retries   = opts.retries,
  }, Session)
end

function Session:_credential()
  if self.mode == "none" then return nil end
  if self.mode == "hmac" then
    if not self.nonce then return nil, "no nonce available; reconnect" end
    return self.digest(self.nonce .. self.secret)
  end
  return self.secret
end

--- Run a command. Returns output and exit code, or nil plus an error.
function Session:exec(cmd)
  local cred, err = self:_credential()
  if err then return nil, err end

  local res, callErr = self.transport:call(self.host, "ssh.exec",
    { cmd = cmd, cred = cred },
    { timeout = self.timeout, retries = self.retries })

  if not res then
    -- A refused nonce means our cached one is stale; force a fresh
    -- handshake on the next attempt rather than looping on a dead one.
    if self.mode == "hmac" then self.nonce = nil end
    return nil, callErr
  end

  -- The server piggybacks the next nonce onto the reply, saving a round trip.
  if res.nonce then self.nonce = res.nonce end

  return res.out, res.code, res.truncated
end

--- Re-run the handshake, e.g. after a nonce expires or the host reboots.
function Session:reconnect()
  local hello, err = self.transport:call(self.host, "ssh.hello", {},
    { timeout = self.timeout, retries = self.retries })
  if not hello then return false, err end
  self.mode  = hello.mode
  self.nonce = hello.nonce
  return true
end

return ssh
