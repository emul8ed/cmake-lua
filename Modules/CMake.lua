local innerExecuteCommand = _G.executeCommand
local innerGetDefinition = _G.getDefinition

currentMakefile = nil

cm =
{
    _pendingCommands = {}
}
cmc = {}

_G.verbose = false

-- -----------------------------------------------------------------------------
function executeCommand(...)
    if _G.verbose then
        print('executeCommand("' .. table.concat({...}, '", "') .. '")')
    end

  return innerExecuteCommand(currentMakefile, ...)
end

-- -----------------------------------------------------------------------------
function getDefinition(...)
  return innerGetDefinition(currentMakefile, ...)
end

-- -----------------------------------------------------------------------------
function execLuaFn(fn, makefile, ...)

  -- TODO: convert args to lua types

  local prevMakefile = currentMakefile
  currentMakefile = makefile

  local fnTy = type(fn)
  if fnTy == 'string' then
    _G[fn](...)
  elseif fnTy == 'function' then
    fn(...)
  else
    error('Invalid type for fn arg')
 end

  currentMakefile = prevMakefile

  local fail = false
  for _,traceback in pairs(cm._pendingCommands) do
      fail = true
      io.stderr:write('The following command was constructed but not executed: ')
      io.stderr:write(traceback .. '\n')
  end

  if fail then
      error('One or more commands not executed')
  end
end

-- -----------------------------------------------------------------------------
function execLuaScript(luaFile, makefile)

  local fn,err = loadfile(luaFile)

  if fn == nil then
      error(err)
  end
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
