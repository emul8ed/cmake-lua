
-- -----------------------------------------------------------------------------
function execLuaScript(luaFile, makefile)
  local env = {}
  setmetatable(env,
    {
      __index = function(tbl, key)
        return _G[key]
      end
    })

  function env.executeCommand(...)
    return _G.executeCommand(makefile, ...)
  end

  function env.getDefinition(...)
    return _G.getDefinition(makefile, ...)
  end

  fn = loadfile(luaFile)
  setfenv(fn, env)

  fn()
end
