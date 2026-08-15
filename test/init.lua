-- Minimal test harness. No dependencies, no magic.

local T = { passed = 0, failed = 0, suite = "" }

function T.describe(name)
  T.suite = name
  io.write("\n" .. name .. "\n")
end

function T.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    T.passed = T.passed + 1
    io.write(string.format("  \27[32mok\27[0m   %s\n", name))
  else
    T.failed = T.failed + 1
    io.write(string.format("  \27[31mFAIL\27[0m %s\n         %s\n", name, tostring(err)))
  end
end

function T.eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      msg or "eq", tostring(expected), tostring(actual)), 2)
  end
end

function T.ok(value, msg)
  if not value then error(msg or "expected truthy value", 2) end
end

function T.nilish(value, msg)
  if value ~= nil then
    error(string.format("%s: expected nil, got %s", msg or "nil", tostring(value)), 2)
  end
end

function T.report()
  io.write(string.format("\n%d passed, %d failed\n", T.passed, T.failed))
  os.exit(T.failed > 0 and 1 or 0)
end

return T
