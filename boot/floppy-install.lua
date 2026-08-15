--[[ kublocknetes :: floppy installer

     Copies the cluster libraries and programs from this floppy onto the
     local machine, so a node can be provisioned by walking a disk over to it.

     Run it from wherever the floppy mounted:

       /mnt/xxx/install

     It works out its own location rather than assuming a mount point, so it
     does not care what letter OpenOS gave the disk.

     On a tight machine, install just the probe first:

       /mnt/xxx/install --probe-only
]]

local filesystem = require("filesystem")
local computer   = require("computer")
local shell      = require("shell")

local _, opts = shell.parse(...)

-- Finding our own floppy is fiddlier than it looks. OpenOS chunk names are
-- not consistently prefixed and the working directory may be anywhere, so
-- try three strategies in order of reliability:
--
--   1. an explicit --root, which always wins
--   2. the marker file mkfloppy writes to every floppy, found under /mnt
--   3. debug.getinfo, accepting either @ or = as the chunkname prefix
--
-- Strategy 3 alone used to be the whole implementation. It failed when the
-- program was invoked by path from another directory -- which is the obvious
-- way to run it -- because the chunkname did not carry the "@" it assumed.

local function looksLikeFloppy(path)
  return filesystem.exists(path .. "/.kbx-floppy")
     and filesystem.exists(path .. "/lib")
end

local function findRoot()
  if opts.root then
    return opts.root, "--root"
  end

  if filesystem.exists("/mnt") then
    for name in filesystem.list("/mnt") do
      local path = "/mnt/" .. name:gsub("/$", "")
      if looksLikeFloppy(path) then return path, "marker" end
    end
  end

  local source = debug.getinfo(1, "S").source or ""
  local guess  = source:match("^[@=]?(.*)/[^/]+$")
  if guess and guess ~= "" and filesystem.exists(guess .. "/lib") then
    return guess, "chunkname"
  end

  return nil, source
end

local ROOT, how = findRoot()

if not ROOT then
  io.stderr:write("install: cannot locate the floppy\n")
  io.stderr:write("  no .kbx-floppy marker found under /mnt\n")
  io.stderr:write("  chunkname was: " .. tostring(how) .. "\n")
  io.stderr:write("  try:  install --root=/mnt/xxx\n")
  return 1
end

io.write("kublocknetes installer\n")
io.write("  from    " .. ROOT .. "  (found by " .. how .. ")\n")
io.write("  free    " .. computer.freeMemory() .. " bytes\n\n")

local function copyFile(from, to)
  local src = io.open(from, "rb")
  if not src then return nil, "cannot read " .. from end

  local dir = filesystem.path(to)
  if dir and not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end

  local dst = io.open(to, "wb")
  if not dst then
    src:close()
    return nil, "cannot write " .. to
  end

  -- Copied in chunks rather than slurped: this runs on the smallest machine
  -- in the cluster, and a whole file in memory is exactly the habit that
  -- kills these things.
  while true do
    local chunk = src:read(4096)
    if not chunk or #chunk == 0 then break end
    dst:write(chunk)
  end

  src:close()
  dst:close()
  return true
end

local function copyTree(from, to, filter)
  if not filesystem.exists(from) then return 0, 0 end

  local copied, failed = 0, 0
  for name in filesystem.list(from) do
    if not name:match("/$") then
      if not filter or filter(name) then
        local ok, err = copyFile(from .. "/" .. name, to .. "/" .. name)
        if ok then
          io.write(string.format("  %-22s -> %s\n", name, to))
          copied = copied + 1
        else
          io.write(string.format("  %-22s FAILED: %s\n", name, tostring(err)))
          failed = failed + 1
        end
      end
    end
  end
  return copied, failed
end

local probeOnly = opts["probe-only"] or opts.p

local filter
if probeOnly then
  filter = function(name) return name:match("^probe") ~= nil end
  io.write("probe-only mode: installing diagnostics, nothing else\n\n")
end

local libCopied, libFailed = copyTree(ROOT .. "/lib", "/usr/lib",
  probeOnly and function() return false end or nil)
local binCopied, binFailed = copyTree(ROOT .. "/bin", "/usr/bin", filter)

-- rc.d services, so the node comes back on its own after a reboot.
local rcCopied, rcFailed = 0, 0
if not probeOnly then
  rcCopied, rcFailed = copyTree(ROOT .. "/rc.d", "/etc/rc.d")
end

io.write(string.format("\n%d installed, %d failed\n",
  libCopied + binCopied + rcCopied, libFailed + binFailed + rcFailed))
io.write(string.format("free memory now %d bytes\n", computer.freeMemory()))

if probeOnly then
  io.write("\nrun:  probe\n")
  io.write("then read /home/probe.txt before installing the rest.\n")
else
  io.write("\nnext:\n")
  io.write("  hostname <name>              name this machine\n")
  io.write("  rc kbxsshd enable            start sshd at boot\n")
  io.write("  rc kbxdropbox enable         start the file channel at boot\n")
  io.write("  rc kbxsshd start             or just start it now\n")
end

return 0
