-- Simple Lua syntax validator for modified files
local files = {
  "mods/DebugMenu/main.lua",
  "mods/gen1online-gamecorner/main.lua"
}

for _, f in ipairs(files) do
  local fh = assert(io.open(f, "r"), "Could not open " .. f)
  local content = fh:read("*a")
  fh:close()
  local fn, err = loadstring(content, f)
  if not fn then
    print("SYNTAX ERROR in " .. f .. ": " .. tostring(err))
    os.exit(1)
  else
    print("SYNTAX OK: " .. f)
  end
end
print("ALL LUA CHECKS PASSED.")
