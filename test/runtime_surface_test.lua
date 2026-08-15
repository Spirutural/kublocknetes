local T = require("test.init")

T.describe("runtime :: base OS surface is locked")

--[[ Why this test exists.

     Whether nodes run OpenOS, a stripped OpenOS with a custom init, or a
     bare EEPROM netboot runtime is a decision we deliberately have not made
     yet -- it should be made with measurements from real rack hardware, not
     guessed at now.

     That option only stays open if lib/ depends on a small, explicit slice
     of the base OS. Every extra module lib/ reaches for is another thing a
     replacement runtime would have to provide.

     So this test does not forbid growth. It forbids growth by ACCIDENT.
     Adding to the allowlist is fine; doing it silently is not, because the
     cost lands on a future runtime port that nobody is thinking about while
     writing the require().
]]

-- Provided by OpenComputers itself, or trivially reimplementable on any
-- replacement runtime. Extend deliberately, with a note on the cost.
local ALLOWED_BASE = {
  component     = "OC core: hardware access. Any runtime must provide it.",
  computer      = "OC core: memory, uptime, signals. Unavoidable.",
  serialization = "OpenOS library, ~40 lines to reimplement if we drop it.",
}

local function ownModules()
  local own = {}
  local pipe = assert(io.popen("ls lib/*.lua 2>/dev/null"))
  for path in pipe:lines() do
    own[path:match("([^/]+)%.lua$")] = true
  end
  pipe:close()
  return own
end

local function libFiles()
  local files = {}
  local pipe = assert(io.popen("ls lib/*.lua 2>/dev/null"))
  for path in pipe:lines() do files[#files + 1] = path end
  pipe:close()
  return files
end

T.test("lib/ requires only the locked base surface", function()
  local own   = ownModules()
  local files = libFiles()

  T.ok(#files > 0, "found lib files to check")

  local violations = {}

  for _, path in ipairs(files) do
    local f = assert(io.open(path, "r"))
    local src = f:read("a")
    f:close()

    -- Strip block comments so the rationale prose above doesn't trip us.
    src = src:gsub("%-%-%[%[.-%]%]", "")

    for module in src:gmatch('require%s*%(%s*["\']([%w_%.]+)["\']') do
      if not ALLOWED_BASE[module] and not own[module] then
        violations[#violations + 1] = string.format(
          "%s requires '%s'", path, module)
      end
    end
  end

  if #violations > 0 then
    error("base OS surface widened:\n         "
      .. table.concat(violations, "\n         ")
      .. "\n       If that is intended, add it to ALLOWED_BASE with a note on"
      .. "\n       what a replacement runtime would have to provide.", 0)
  end
end)

T.test("the allowlist stays small enough to be portable", function()
  local n = 0
  for _ in pairs(ALLOWED_BASE) do n = n + 1 end
  T.ok(n <= 6,
    "base surface is " .. n .. " modules; past ~6 a runtime port stops being cheap")
end)
