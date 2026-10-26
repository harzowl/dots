-- Merge Nix sandbox overrides into a Project Zomboid server's SandboxVars file.
-- Usage: lua sandbox-vars.lua <overrides.lua> <target.lua>
-- The overrides file returns a table. The target is left alone until the game
-- has created it, so mod-provided sandbox options are never seeded from the
-- stock preset.
local overridesPath, targetPath = ...

local overrides = assert(loadfile(overridesPath))()

local target = io.open(targetPath, "r")
if not target then
  io.stderr:write(
    "sandbox overrides skipped: " .. targetPath .. " does not exist yet; the game creates it on first start\n"
  )
  os.exit(0)
end
target:close()

local env = {}
assert(loadfile(targetPath, "t", env))()
local current = assert(env.SandboxVars, targetPath .. " does not define SandboxVars")

local function merge(destination, source)
  for key, value in pairs(source) do
    if type(value) == "table" and type(destination[key]) == "table" then
      merge(destination[key], value)
    else
      destination[key] = value
    end
  end
end

local function keyLiteral(key)
  if type(key) == "number" then
    return "[" .. tostring(key) .. "]"
  end
  return string.format("[%q]", key)
end

local function serialize(value, indent)
  local kind = type(value)
  if kind == "string" then
    return string.format("%q", value)
  elseif kind == "number" or kind == "boolean" then
    return tostring(value)
  elseif kind == "table" then
    local keys = {}
    for key in pairs(value) do
      keys[#keys + 1] = key
    end
    if #keys == 0 then
      return "{}"
    end
    table.sort(keys, function(a, b)
      local typeA, typeB = type(a), type(b)
      if typeA ~= typeB then
        return typeA < typeB
      end
      if typeA == "number" then
        return a < b
      end
      return tostring(a) < tostring(b)
    end)
    local padding = string.rep("    ", indent + 1)
    local entries = {}
    for _, key in ipairs(keys) do
      entries[#entries + 1] = padding .. keyLiteral(key) .. " = " .. serialize(value[key], indent + 1)
    end
    return "{\n" .. table.concat(entries, ",\n") .. "\n" .. string.rep("    ", indent) .. "}"
  end
  error("unsupported sandbox value type: " .. kind)
end

merge(current, overrides)

local out = assert(io.open(targetPath, "w"))
out:write("SandboxVars = ", serialize(current, 0), ";\n")
out:close()
