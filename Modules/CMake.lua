local innerExecuteCommand = _G.executeCommand
local innerGetDefinition = _G.getDefinition

currentMakefile = nil

-- -----------------------------------------------------------------------------
function executeCommand(...)
  return innerExecuteCommand(currentMakefile, ...)
end

-- -----------------------------------------------------------------------------
function getDefinition(...)
  return innerGetDefinition(currentMakefile, ...)
end

-- -----------------------------------------------------------------------------
function execLuaFn(fn, makefile)

  local prevMakefile = currentMakefile
  currentMakefile = makefile

  fn()

  currentMakefile = prevMakefile
end

-- -----------------------------------------------------------------------------
function execLuaScript(luaFile, makefile)

  local fn = loadfile(luaFile)
  local env = {}

  setmetatable(env,
    {
      __index = function(tbl, key)
        return _G[key]
      end
    })

  setfenv(fn, env)

  execLuaFn(fn, makefile)
end
