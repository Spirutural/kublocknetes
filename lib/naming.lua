--[[ kublocknetes :: naming

     Hostnames for cluster machines, so you address `smelter-ctl` rather than
     b64178fb-4bc9-4be3-853f-0295adc74584.

     Resolution is by broadcast, deliberately: there is no registry to keep
     in sync, nothing to go stale, and it keeps working before the control
     plane exists and after it dies. A node answers only when the name is its
     own -- everything else stays silent via transport.NO_REPLY -- so a lookup
     costs one broadcast and as many replies as there are matches.

     That is ARP, and it has the property that matters here: the answer comes
     from the machine itself, so it cannot be wrong about who it is.

     Duplicate names are surfaced rather than hidden. Two machines answering
     to `worker-2` is a real misconfiguration and silently picking the first
     would make it a mystery later.

     The hostname is read from /etc/hostname by the caller and passed in, so
     this module stays free of OpenOS.
]]

local naming = {}

naming.PORT   = 6444        -- discovery, alongside the apiserver's 6443
naming.METHOD = "kbx.whois"

--- True for something shaped like an OC component address, so callers can
--  tell `b64178fb-…` from `smelter-ctl` without asking the network.
function naming.looksLikeAddress(s)
  if type(s) ~= "string" then return false end
  -- Full UUID, or a leading fragment of one: OpenOS accepts prefixes, and a
  -- bare hex run is far more likely to be an address than a hostname.
  if s:match("^%x%x%x%x%x%x%x%x%-") then return true end
  return s:match("^%x+$") ~= nil and #s >= 6
end

--- Serve name queries. `hostnameFn` is called per request rather than
--  captured, so renaming a live machine takes effect without a restart.
function naming.serve(transport, hostnameFn)
  transport:handle(naming.METHOD, function(args)
    local want = args and args.name
    local mine = hostnameFn()

    if type(want) ~= "string" or not mine or mine == "" then
      return transport.NO_REPLY
    end

    -- Answer "who is X" only when we are X, and "who is anyone" always, so
    -- the same handler serves both lookup and inventory.
    if want ~= "*" and want:lower() ~= mine:lower() then
      return transport.NO_REPLY
    end

    return { name = mine }
  end)
end

--- Resolve a hostname to addresses. Returns a list of
--  { address = ..., name = ... }, empty if nobody answered.
function naming.resolve(transport, name, opts)
  opts = opts or {}

  local replies = transport:discover(naming.METHOD, { name = name },
    { timeout = opts.timeout or 2 })

  local found = {}
  for _, reply in ipairs(replies) do
    if type(reply.result) == "table" and reply.result.name then
      found[#found + 1] = { address = reply.from, name = reply.result.name }
    end
  end

  table.sort(found, function(a, b) return a.address < b.address end)
  return found
end

--- Every named machine that answers. Useful for `kubectl get nodes` before
--  there is a kubectl.
function naming.list(transport, opts)
  return naming.resolve(transport, "*", opts)
end

--- Resolve a target that may be either a name or an address.
--  Returns address, or nil plus a reason.
function naming.lookup(transport, target, opts)
  if naming.looksLikeAddress(target) then
    return target
  end

  local found = naming.resolve(transport, target, opts)

  if #found == 0 then
    return nil, "no machine answers to '" .. tostring(target) .. "'"
  end

  if #found > 1 then
    local addrs = {}
    for _, m in ipairs(found) do addrs[#addrs + 1] = m.address:sub(1, 8) end
    return nil, string.format(
      "'%s' is claimed by %d machines (%s) -- fix the duplicate hostname",
      target, #found, table.concat(addrs, ", "))
  end

  return found[1].address
end

return naming
