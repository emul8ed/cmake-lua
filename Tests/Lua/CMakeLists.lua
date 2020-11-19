local pretty = require 'pl.pretty'
local template = require 'pl.template'

local executeCommand = executeCommand
local getDefinition = getDefinition

_G.verbose = true

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
            escapedVal[#escapedVal + 1] = toCMakeArg(tostring(item))
        end
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

cm = {}
cmc = {}

-- -----------------------------------------------------------------------------
function cm.eval(cmakeStr)
    -- TODO: support multiple out vars
    executeCommand('set', 'out_var', '""')
    cmakeStr = template.substitute(cmakeStr, getfenv())

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

--[[
local someVar = getDefinition('SOME_VAR');
print('RAW: ' .. someVar)

local foo = 'foovalue'
--]]

--[[
cmake(function()
    add_custom_target('acustomtarget', ALL, DEPENDS, 'myoutfile.txt')
    set('ValueX', 'CachedValue', CACHE, STRING, 'Doc')
    message(STATUS, 'This is a message from lua')
    -- add_subdirectory('foo')
end)
--]]

-- -----------------------------------------------------------------------------
function cm.addArgsToCmd(cmakeCmd, ...)
    local retVarCount = cmakeCmd._retVarCount
    for _,arg in pairs({...}) do
        if type(arg) == 'table' and arg._isOutVar then
            retVarCount = retVarCount + 1
            arg = '_lua_out_var_' .. tostring(retVarCount)
        elseif type(arg) == 'table' and arg._isOutVar2 then
            local outVars = rawget(cmakeCmd, '_outVars')
            outVars = outVars or {}
            cmakeCmd._outVars = outVars
            table.insert(outVars, arg)
            arg = arg._cmVarName
        end
        table.insert(cmakeCmd, arg)
    end
    cmakeCmd._retVarCount = retVarCount
end

local cmakeCmdMeta =
{
    __call = function(tbl)
        verbose('__call:')
        verbose(tbl)

        local retVarCount = tbl._retVarCount
        tbl._retVarCount = nil

        local outVars = rawget(tbl, '_outVars')
        tbl._outVars = nil

        if outVars and retVarCount > 0 then
            error('Out vars and ret vars are mutually exclusive')
        end

        --
        -- Clear all out vars, so we don't unintentionally return a stale
        -- value
        --
        for i=1,retVarCount do
            executeCommand('set', '_lua_out_var_' .. tostring(i), '')
        end

        if outVars then
            for _,var in ipairs(outVars) do
                executeCommand('set', var._cmVarName, '')
            end
        end

        executeCommand(unpack(tbl))

        if retVarCount > 0 then
            local retTable = {}
            for i=1,retVarCount do
                table.insert(retTable, getDefinition('_lua_out_var_' .. tostring(i)))
            end

            return unpack(retTable)
        elseif outVars then
            local retTable = {}
            for _,var in ipairs(outVars) do
                local val = getDefinition(var._cmVarName)
                if false and string.find(val, ';') ~= nil then
                    -- TODO: explicit raw/string value for data with semicolons
                    executeCommand('list', var._cmVarName, 'out_var')
                    local itemCount = tonumber(getDefinition('out_var'))
                    if itemCount == 0 then
                        val = nil
                    elseif itemCount == 1 then
                        -- TODO: extract scalar.
                        -- TODO: test this case (e.g. escaped semicolon?)
                    else
                        val = {}
                        -- TODO: extract each item
                        -- TODO: move this to a helper function
                    end
                end
                retTable[var._luaVarName] = val
            end

            return retTable
        else
            return nil
        end
    end,
    __index = function(cmakeCmd, key)
        verbose('__index: %s', key)
        return function(...)
            table.insert(cmakeCmd, string.upper(key))
            -- TODO: auto convert lua types?
            cm.addArgsToCmd(cmakeCmd, ...)
            return cmakeCmd
        end
    end
}

local falseValues =
{
    [''] = true,
    ['0'] = true,
    ['false'] = true,
    ignore = true,
    n = true,
    no = true
}

-- -----------------------------------------------------------------------------
function cm.toBool(cmakeStr)
    local cmakeStrLower = string.lower(cmakeStr)

    local isFalse = falseValues[cmakeStrLower]
    if isFalse then
        return false
    end

    if cmakeStr == 'NOTFOUND' then
        return false
    end

    if #cmakeStr >= 9 and string.sub(cmakeStr, -9) == '-NOTFOUND' then
        return false
    end

    return true
end

assert(cm.toBool('NOTFOUND') == false)
assert(cm.toBool('-NOTFOUND') == false)
assert(cm.toBool('blah-NOTFOUND') == false)
assert(cm.toBool('nOTFOUND') == true)
assert(cm.toBool('blah-nOTFOUND') == true)

-- -----------------------------------------------------------------------------
function cm.returnVar()
    return { _isOutVar = true }
end

-- -----------------------------------------------------------------------------
function cm.out(varName)
    local outVar =
    {
        _isOutVar2 = true,
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

setmetatable(cmc,
{
    __call = function(tbl, ...) cm.eval(...) end,
    __index = function(_, key)
        return function(...)
            local cmakeCmd = {key}
            cmakeCmd._retVarCount = 0
            cm.addArgsToCmd(cmakeCmd, ...)
            setmetatable(cmakeCmd, cmakeCmdMeta)
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

_G.AGlobalVar = 'global'

cmc.set('SOME_VAR', 'Initial value')
cmc.add_subdirectory 'subdir'()
print(getDefinition('SOME_VAR'))
