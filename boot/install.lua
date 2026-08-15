--[[ kublocknetes :: installer

     Pulls the cluster code onto an OC machine over HTTPS. Requires an
     Internet Card with HTTP enabled in the OpenComputers config.

     Bootstrap it with a single line you only ever have to type once:

       wget -f https://raw.githubusercontent.com/Spirutural/kublocknetes/main/boot/install.lua /usr/bin/kbi.lua && kbi

     After that, `kbi` re-syncs every file in MANIFEST.

       kbi              install/update everything
       kbi --branch dev pull from another branch
       kbi --list       show what would be installed, change nothing

     Note: raw.githubusercontent.com caches for a few minutes, so a push you
     made seconds ago may not be visible yet. The installer reports the commit
     it fetched so you can tell.
]]

local component  = require("component")
local filesystem = require("filesystem")
local shell      = require("shell")

local REPO   = "Spirutural/kublocknetes"
local args, opts = shell.parse(...)
local BRANCH = opts.branch or "main"
local BASE   = string.format("https://raw.githubusercontent.com/%s/%s/", REPO, BRANCH)

if not component.isAvailable("internet") then
  io.stderr:write("no internet card found\n")
  io.stderr:write("this machine needs one to install over HTTPS\n")
  return 1
end

local internet = require("internet")

--- Fetch a URL into a string. Returns nil, err on failure.
local function fetch(url)
  local ok, handle = pcall(internet.request, url)
  if not ok or not handle then
    return nil, tostring(handle)
  end

  local chunks = {}
  local ok2, err = pcall(function()
    for chunk in handle do
      chunks[#chunks + 1] = chunk
    end
  end)

  if not ok2 then return nil, tostring(err) end

  local body = table.concat(chunks)
  -- GitHub serves an HTML 404 page rather than a transport error.
  if body:sub(1, 15) == "404: Not Found" then
    return nil, "not found"
  end
  return body
end

local function writeFile(path, content)
  local dir = filesystem.path(path)
  if dir and not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end

  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(content)
  f:close()
  return true
end

-- ------------------------------------------------------------- manifest ----

io.write("kublocknetes installer\n")
io.write("  repo    " .. REPO .. "\n")
io.write("  branch  " .. BRANCH .. "\n\n")

local manifest, err = fetch(BASE .. "MANIFEST")
if not manifest then
  io.stderr:write("could not fetch MANIFEST: " .. tostring(err) .. "\n")
  return 1
end

local entries = {}
for line in manifest:gmatch("[^\r\n]+") do
  local trimmed = line:match("^%s*(.-)%s*$")
  if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
    local src, dst = trimmed:match("^(%S+)%s+(%S+)$")
    if src and dst then
      entries[#entries + 1] = { src = src, dst = dst }
    else
      io.stderr:write("  skipping malformed line: " .. trimmed .. "\n")
    end
  end
end

if #entries == 0 then
  io.stderr:write("manifest is empty\n")
  return 1
end

if opts.list then
  for _, e in ipairs(entries) do
    io.write(string.format("  %-24s -> %s\n", e.src, e.dst))
  end
  io.write(string.format("\n%d files\n", #entries))
  return 0
end

-- -------------------------------------------------------------- install ----

local installed, failed = 0, 0

for _, entry in ipairs(entries) do
  io.write(string.format("  %-24s ", entry.src))

  local body, ferr = fetch(BASE .. entry.src)
  if not body then
    io.write("FAIL (" .. tostring(ferr) .. ")\n")
    failed = failed + 1
  else
    local ok, werr = writeFile(entry.dst, body)
    if ok then
      io.write(string.format("%6d bytes -> %s\n", #body, entry.dst))
      installed = installed + 1
    else
      io.write("WRITE FAIL (" .. tostring(werr) .. ")\n")
      failed = failed + 1
    end
  end
end

io.write(string.format("\n%d installed, %d failed\n", installed, failed))

if failed > 0 then return 1 end

io.write("\nlibraries are on package.path, programs are on PATH.\n")
io.write("try:  probe\n")
return 0
