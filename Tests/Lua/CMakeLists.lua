local pretty = require 'pl.pretty'
local template = require 'pl.template'

local executeCommand = executeCommand
local getDefinition = getDefinition

_G.verbose = false

-- -----------------------------------------------------------------------------
local function verbose(...)
    if not _G.verbose then
        return
    end

    local argTbl = {...}
    local argCount = #argTbl

    if argCount == 0 then
        error('Missing arg(s) to verbose')
    end

    local firstArg = argTbl[1]
    local firstArgType = type(firstArg)

    if firstArgType == 'string' then
        if argCount > 1 then
            print(string.format(...))
        else
            print(firstArg)
        end
    elseif firstArgType == 'function' then
        firstArg(unpack(argTbl, 2))
    elseif firstArgType == 'table' then
        pretty.dump(firstArg)
    else
        print(tostring(firstArg))
    end
end

-- -----------------------------------------------------------------------------
function errorFmt(...)
    error(string.format(...))
end

-- -----------------------------------------------------------------------------
function toCMakeArg(luaValue)
    -- TODO: expand lists when pushing cmake vars on C++ side?
    local valType = type(luaValue)
    if valType == 'table' then
        -- TODO: reject values that end in unquoted backslash? Or handle quoting/unquoting?
        local escapedVal = {}
        for _,item in pairs(luaValue) do
            escapedVal[#escapedVal + 1] = toCMakeArg(item)
        end
        -- TODO: tests for nested tables
        return table.concat(escapedVal, ';')
    elseif valType == 'string' then
        return string.gsub(luaValue, ';', [[\;]])
    elseif valType == 'number' then
        return tostring(luaValue)
    elseif valType == 'boolean' then
        return (luaValue and 'TRUE') or 'FALSE'
    else
        errorFmt('Invalid type for cmake value %s', valType)
    end
end

-- -----------------------------------------------------------------------------
function cm.eval(cmakeStr)
    -- TODO: support multiple out vars
    executeCommand('set', 'out_var', '""')
    -- TODO cmakeStr = template.substitute(cmakeStr, getfenv())

    executeCommand('cmake_language', 'EVAL', 'CODE', cmakeStr)
    return getDefinition('out_var')
end

local result = cm.eval([[
function (UnaryCondition condition value)
    if (\${condition} "\${value}")
        set(out_var 1 PARENT_SCOPE)
    else()
        set(out_var 0 PARENT_SCOPE)
    endif()
endfunction()
]])

-- -----------------------------------------------------------------------------
function cm.esc(str)
    return string.gsub(str, ';', [[\;]])
end

-- -----------------------------------------------------------------------------
function cm.get(cmakeVar)
    return cm.toLuaValue(getDefinition(cmakeVar))
end

-- -----------------------------------------------------------------------------
function cm.fileAppend(fileName, content)
    executeCommand('file', 'APPEND', fileName, toCMakeArg(content))
end

-- -----------------------------------------------------------------------------
function cm.exists(path)
    assert(path)
    executeCommand('UnaryCondition', 'EXISTS', path)
    return getDefinition('out_var') == '1'
end

-- TODO: directory, policy, target, symlink, test, absolute, version preds, cache or env defined

-- -----------------------------------------------------------------------------
function cm.isCommand(cmdName)
    assert(cmdName)
    -- TODO: native implementation of COMMAND
    executeCommand('UnaryCondition', 'COMMAND', cmdName)
    return getDefinition('out_var') == '1'
end

-- -----------------------------------------------------------------------------
function cm.isDefined(varName)
    -- TODO: native implementation of DEFINED
    executeCommand('UnaryCondition', 'DEFINED', varName)
    return getDefinition('out_var') == '1'
end

setmetatable(cm,
{
    __call = function(tbl, ...) cm.eval(...) end,
    __index = function(_, key)
        return function(argsStr)
            return cm.eval(key .. '(' .. argsStr .. ')')
        end
    end
})

cm [[
add_custom_command(
    COMMAND bash -c "ls -alrt; echo @@DONE2"
    OUTPUT myoutfile2.txt
    )
]]

file3 = 'myoutfile3.txt'
cm.add_custom_command [[
    COMMAND bash -c "ls -alrt; echo @@DONE2"
    OUTPUT $(file3)
    ]]

cm.add_custom_target [[
    testtarget
    DEPENDS myoutfile.txt myoutfile3.txt
    ]]

-- TODO: support other predicates

outFile = 'myoutfile2.txt'

teststring = 'string;with;semis'
cm [[
    add_custom_target(testtarget2 DEPENDS $(outFile))
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/blah.txt $(cm.esc(teststring)))
]]

local content = cm.file [[
    READ ${CMAKE_CURRENT_BINARY_DIR}/blah.txt
    out_var
    ]]
print('OUT VAR: ' .. content)

-- -----------------------------------------------------------------------------
function cm.addArgsToCmd(cmakeCmd, ...)
    local retVarCount = cmakeCmd._retVarCount
    for _,arg in pairs({...}) do
        local argType = type(arg)
        if argType == 'table' then
            if arg._isRetVar or arg._isOutVar then
                local outVars = rawget(cmakeCmd, '_outVars')
                outVars = outVars or {}
                cmakeCmd._outVars = outVars
                table.insert(outVars, arg)
                if arg._isRetVar then
                    arg._cmVarName = '_lua_ret_val_' .. tostring(#outVars)
                end
                arg = arg._cmVarName
            else
                arg = toCMakeArg(arg)
            end
        else
            arg = toCMakeArg(arg)
        end
        table.insert(cmakeCmd, arg)
    end
    cmakeCmd._retVarCount = retVarCount
end

-- -----------------------------------------------------------------------------
function cm.toLuaValueScalar(cmakeStr)
    if cmakeStr == nil then
        return nil
    end

    --
    -- Try coercing to number first, so '0' and '1' will be converted to number
    -- instead of boolean.
    --
    local asNum = tonumber(cmakeStr)
    if asNum ~= nil then
        return asNum
    end

    local asBool = cm.toBool(cmakeStr)
    if asBool ~= nil then
        return asBool
    end

    return cmakeStr
end

-- -----------------------------------------------------------------------------
function cm.toLuaValue(cmakeStr)
    if cmakeStr == nil then
        return nil
    end

    local valTbl,count = expandList(cmakeStr);
    for idx=1,count do
        valTbl[idx] = cm.toLuaValueScalar(valTbl[idx])
    end

    if count > 1 then
        return valTbl
    else
        return valTbl[1]
    end
end

local cmakeCmdMeta =
{
    __call = function(tbl)
        verbose('__call:')
        verbose(tbl)

        cm._pendingCommands[tbl] = nil

        local outVars = rawget(tbl, '_outVars')

        --
        -- Clear all out vars, so we don't unintentionally return a stale
        -- value
        --
        if outVars then
            for _,var in ipairs(outVars) do
                executeCommand('set', var._cmVarName, '')
            end
        end

        local result, err = executeCommand(unpack(tbl))

        if not result then
            error(err)
        end

        if outVars then
            local expandList = expandList
            local getDefinition = getDefinition
            local toLuaValue = cm.toLuaValue

            local retTable = {}
            local unpackTable = false

            for _,var in ipairs(outVars) do
                local val = getDefinition(var._cmVarName)
                if val ~= nil and not var._raw then
                    val = toLuaValue(val)
                end

                if var._isOutVar then
                    retTable[var._luaVarName] = val
                else
                    assert(var._isRetVar)
                    table.insert(retTable, val)
                    unpackTable = true
                end
            end

            if unpackTable then
                return unpack(retTable), retTable
            else
                return retTable
            end
        else
            return nil
        end
    end,
    __index = function(cmakeCmd, key)
        verbose('__index: %s', key)
        return function(...)
            table.insert(cmakeCmd, string.upper(key))
            cm.addArgsToCmd(cmakeCmd, ...)
            return cmakeCmd
        end
    end
}

local boolValues =
{
    ['0'] = false,
    ['false'] = false,
    ignore = false,
    n = false,
    no = false,
    off = false,

    ['1'] = true,
    on = true,
    ['true'] = true,
    y = true,
    yes = true
}

-- -----------------------------------------------------------------------------
function cm.isNotFound(cmakeStr)
    if cmakeStr == 'NOTFOUND'
        or (#cmakeStr >= 9 and string.sub(cmakeStr, -9) == '-NOTFOUND')
            then
        return true
    else
        return false
    end
end

-- -----------------------------------------------------------------------------
function cm.isTrue(cmakeStr)
    if #cmakeStr == 0 then
        return false
    end

    local cmakeStrLower = string.lower(cmakeStr)

    local boolVal = boolValues[cmakeStrLower]
    if boolVal ~= nil then
        return boolVal
    end

    if cm.isNotFound(cmakeStr) then
        return false
    else
        return true
    end
end

-- -----------------------------------------------------------------------------
function cm.toBool(cmakeStr)
    local result = boolValues[string.lower(cmakeStr)]

    if result ~= nil then
        return result
    end

    if cm.isNotFound(cmakeStr) then
        return false
    end

    return nil
end

assert(not cm.isTrue('NOTFOUND'))
assert(not cm.isTrue('-NOTFOUND'))
assert(cm.isTrue('blah-NOTFOUND') == false)
assert(cm.isTrue('nOTFOUND'))
assert(cm.isTrue('blah-nOTFOUND'))

assert(cm.toBool('TRUE') == true)
assert(cm.toBool('true') == true)
assert(cm.toBool('on') == true)
assert(cm.toBool('1') == true)
assert(cm.toBool('yes') == true)
assert(cm.toBool('tru') == nil)
assert(cm.toBool('tru') == nil)

-- TODO: returnRaw

-- -----------------------------------------------------------------------------
function cm.returnVar()
    return { _isRetVar = true }
end

-- -----------------------------------------------------------------------------
function cm.out(varName)
    local outVar =
    {
        _isOutVar = true,
        _luaVarName = varName,
        _cmVarName = '_lua_out_' .. varName
    }

    setmetatable(outVar,
    {
        __tostring = function(tbl)
            return tbl._cmVarName
        end
    })

    return outVar
end

-- -----------------------------------------------------------------------------
function cm.outRaw(varName)
    local outVar = cm.out(varName)
    outVar._raw = true
    return outVar
end

setmetatable(cmc,
{
    __index = function(_, key)
        return function(...)
            local cmakeCmd = {key}
            cmakeCmd._retVarCount = 0
            cm.addArgsToCmd(cmakeCmd, ...)
            setmetatable(cmakeCmd, cmakeCmdMeta)

            cm._pendingCommands[cmakeCmd] = debug.traceback(key, 2)

            return cmakeCmd
        end
    end
})

cmc.add_custom_command()
    .output 'test.txt'
    .command('ls', '-alrt')()

cmc.add_custom_target 'anotherscheme'
    .depends 'test.txt'()

local isDefined = cmc.get_property(cm.returnVar())
    .target('anotherscheme')
    .property('non_existent_property')
    .defined()()

print('DEFINED: ' .. tostring(cm.toBool(isDefined)))

----
assert(not cm.isDefined('avariable'))

cmc.set('avariable', 'avalue')()

assert(cm.isDefined('avariable'))

assert(cm.isCommand('add_custom_command'))

assert(not cm.isCommand('non_existent'))

local result = cmc.file()
    .read('${CMAKE_CURRENT_BINARY_DIR}/blah.txt', cm.returnVar()) ()

print(result)

local result = cmc.file()
    .read('${CMAKE_CURRENT_BINARY_DIR}/blah.txt', cm.out [[test]]) ()

print('RESULT.TEST: ')
pretty.dump(result.test)

local result = cmc.file()
    .read('${CMAKE_CURRENT_BINARY_DIR}/blah.txt', cm.outRaw [[test]]) ()

print('RESULT.TEST RAW: ')
print(result.test)

-- -----------------------------------------------------------------------------
function cm.retry(attempts, cmakeCmd)
    local result = false
    local err
    local attempt = 1

    local returns
    while not result and attempt <= attempts do
        result, err = pcall(function() returns = {cmakeCmd()} end)
        attempt = attempt + 1
    end

    if not result then
        error(err)
    end

    return unpack(returns)
end

--[=[
result = cm.retry(3,
    cmc.file()
        .read('${CMAKE_CURRENT_BINARY_DIR}/bladfh.txt', cm.outRaw [[test]])
    )

print(result.test)
--]=]

cmc.message()
    .status 'A status message'()

local cmd = cmc.execute_process()
    .command('ls', '-alrt', 'badger')
    .result_variable(cm.returnVar())
    .output_variable(cm.returnVar())
    .error_variable(cm.returnVar())

local result, out, err = cmd()

local cmd = cmc.execute_process()
    .command('ls', '-alrt', 'badger')
    .result_variable(cm.out 'result')
    .output_variable(cm.out 'output')
    .error_variable(cm.out 'error')

local outVals = cmd()

print('Result: ' .. tostring(outVals.result))
print('Out: ' .. outVals.output)
print('Err: ' .. outVals.error)

local result, tbl = cmc.execute_process()
    .command('ls', '-alrt')
    .result_variable(cm.returnVar())
    .output_variable(cm.out 'output')
    .error_variable(cm.out 'error') ()

print('Result: ' .. result)
print('Out: ' .. tbl.output)
print('Err: ' .. tbl.error)

_G.AGlobalVar = 'global'

cmc.set('SOME_VAR', {'Initial value', 'b', 0})()
local val = cm.get('SOME_VAR')
print(val)
assert(type(val) == 'table')
assert(val[1] == 'Initial value')
assert(val[2] == 'b')
assert(val[3] == 0)

cmc.add_subdirectory 'subdir'()
print(getDefinition('SOME_VAR'))

cmc.set('CACHE_VAR', {'a','cache','var'})
    .cache()
    .string('Doc string')
    .force()()

cm.eval([[
function (ExpectStringEqual lhs)
    if (NOT "\${lhs}" STREQUAL "\${ARGN}")
        message(SEND_ERROR "\${lhs} not string-equal to \${ARGN}")
    endif()
endfunction()

function (ExpectStringNotEqual lhs)
    message(STATUS "\${lhs}")
    if ("\${lhs}" STREQUAL "\${ARGN}")
        message(SEND_ERROR "\${lhs} is string-equal to \${ARGN}")
    endif()
endfunction()
]])

cmc.ExpectStringEqual(true, 'TRUE')()
cmc.ExpectStringEqual(false, 'FALSE')()
cmc.ExpectStringEqual({'a','b','c'}, 'a', 'b', 'c')()
cmc.ExpectStringEqual({1,2,3}, '1', '2', '3')()
cmc.ExpectStringNotEqual("a;b;c", 'a', 'b', 'c')()

--[[
result = cm.retry(3,
    cmc.ExpectStringEqual(true, 'FALSE')
    )
    --]]

function _G.TestLuaFunction(arg1)
    print('Success! ' .. arg1)
end

-- -----------------------------------------------------------------------------
function cm.registerCMakeFunction(name)
  local str = string.format([[
    function (%s)
      lua(CALL %s \${ARGN})
    endfunction()
    ]], name, name
    )
  cm.eval(str)
end

cm.registerCMakeFunction('TestLuaFunction')
