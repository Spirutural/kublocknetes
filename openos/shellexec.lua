--[[ kublocknetes :: shell executor (OpenOS)

     Runs a shell command and captures its output.

     Lives in openos/ rather than lib/ deliberately: it depends on OpenOS's
     shell, so it is exactly the kind of coupling `test/runtime_surface_test`
     keeps out of lib/. Anything here would need rewriting for a custom node
     runtime; anything in lib/ would not.

     stdout is captured via the shell's own redirection, which is reliable.
     stderr is captured by swapping io.stderr for the duration -- programs
     that cached the original stream at load time will still leak to the
     local screen. Good enough to read logs with, and honest about the gap.
]]

local shell = require("shell")

local OUT_PATH = "/tmp/.kbx-out"
local ERR_PATH = "/tmp/.kbx-err"

local function slurp(path)
  local f = io.open(path, "r")
  if not f then return "" end
  local data = f:read("a") or ""
  f:close()
  return data
end

--- Returns output:string, exitCode:number
return function(cmd)
  local errFile = io.open(ERR_PATH, "w")
  local savedStderr = io.stderr
  if errFile then io.stderr = errFile end

  local ok, reason = pcall(shell.execute, cmd .. " > " .. OUT_PATH)

  io.stderr = savedStderr
  if errFile then errFile:close() end

  local parts = { slurp(OUT_PATH) }

  local errText = slurp(ERR_PATH)
  if #errText > 0 then parts[#parts + 1] = errText end

  local code = 0
  if not ok then
    parts[#parts + 1] = "error: " .. tostring(reason) .. "\n"
    code = 1
  elseif reason == false then
    code = 1
  end

  return table.concat(parts), code
end
