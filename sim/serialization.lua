--[[ sim :: serialization

     Stand-in for OpenComputers' `serialization` module so that library code
     can `require("serialization")` unmodified in both the simulator and the
     real machine.

     Deliberately compact rather than pretty: every byte here becomes a byte
     on the wire, and the wire is 8KB per packet.
]]

local ser = {}

local function quote(s)
  return string.format("%q", s):gsub("\\\n", "\\n")
end

local function serializeValue(v, out, seen)
  local t = type(v)

  if t == "nil" or t == "boolean" then
    out[#out + 1] = tostring(v)

  elseif t == "number" then
    if v ~= v then
      out[#out + 1] = "0/0"
    elseif v == math.huge then
      out[#out + 1] = "math.huge"
    elseif v == -math.huge then
      out[#out + 1] = "-math.huge"
    elseif math.type(v) == "integer" then
      out[#out + 1] = tostring(v)
    else
      out[#out + 1] = string.format("%.14g", v)
    end

  elseif t == "string" then
    out[#out + 1] = (quote(v))

  elseif t == "table" then
    if seen[v] then error("serialization: cycle detected", 0) end
    seen[v] = true

    out[#out + 1] = "{"
    local first = true

    -- Array part first, unkeyed, so the common case stays small.
    local n = 0
    for i, item in ipairs(v) do
      if not first then out[#out + 1] = "," end
      serializeValue(item, out, seen)
      first = false
      n = i
    end

    for k, item in pairs(v) do
      local isArrayIndex = math.type(k) == "integer" and k >= 1 and k <= n
      if not isArrayIndex then
        if not first then out[#out + 1] = "," end
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
          out[#out + 1] = k .. "="
        else
          out[#out + 1] = "["
          serializeValue(k, out, seen)
          out[#out + 1] = "]="
        end
        serializeValue(item, out, seen)
        first = false
      end
    end

    out[#out + 1] = "}"
    seen[v] = nil

  else
    error("serialization: cannot serialize " .. t, 0)
  end
end

function ser.serialize(value)
  local out = {}
  serializeValue(value, out, {})
  return table.concat(out)
end

function ser.unserialize(str)
  if type(str) ~= "string" then return nil, "not a string" end
  local chunk, err = load("return " .. str, "=serialized", "t", {
    math = { huge = math.huge },
  })
  if not chunk then return nil, err end
  local ok, result = pcall(chunk)
  if not ok then return nil, result end
  return result
end

return ser
