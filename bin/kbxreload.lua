--[[ kublocknetes :: reload

     Drops our modules from OpenOS's module cache so the next `require` reads
     them from disk again.

     WHY THIS EXISTS. `require` caches by name in `package.loaded`, and that
     table lives in OpenOS's package library -- so it is machine-wide and
     survives for as long as the computer is running. Push a new
     transport.lua and every program on that machine keeps getting the old
     one until reboot. The failure looks like the file on disk being ignored,
     which sends you hunting in exactly the wrong place.

       kbxreload            clear the cache
       kbxreload --sshd     clear, then restart sshd
       kbxreload --list     show what is currently cached

     A running daemon holds direct references to the old module tables in its
     own closures, so clearing the cache does not fix an already-running
     daemon -- it has to be restarted too. Clearing helps every program
     started afterwards, which is usually what you actually want.

     Deliberately does NOT restart the dropbox agent: if you invoked this
     through the dropbox, stopping it would kill the job mid-flight and you
     would never see this output. Restart that one by hand or reboot.
]]

local shell = require("shell")

local _, opts = shell.parse(...)

local MODULES = {
  "wire", "transport", "naming", "sshd", "ssh", "dropbox", "shellexec",
}

if opts.list then
  print(string.format("%-14s %s", "MODULE", "STATE"))
  for _, name in ipairs(MODULES) do
    print(string.format("%-14s %s", name,
      package.loaded[name] and "cached" or "-"))
  end
  return 0
end

local cleared = {}
for _, name in ipairs(MODULES) do
  if package.loaded[name] then
    package.loaded[name] = nil
    cleared[#cleared + 1] = name
  end
end

if #cleared == 0 then
  print("nothing was cached; next require reads from disk anyway")
else
  print("cleared: " .. table.concat(cleared, ", "))
end

if opts.sshd then
  print("restarting sshd...")
  shell.execute("rc kbxsshd restart")
else
  print("running daemons still hold the old code. to pick it up:")
  print("  rc kbxsshd restart")
  print("  rc kbxdropbox restart   (not from inside a dropbox job)")
end

return 0
