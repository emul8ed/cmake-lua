local pretty = require 'pl.pretty'
local template = require 'pl.template'

local executeCommand = executeCommand
local getDefinition = getDefinition

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

-- -----------------------------------------------------------------------------
function processArgTable(functionName, argDefs, argTable, cmakeCmd)

    function processArg(argDef, value)
        pretty.dump(argDef)
        if argDef.type == 'list' then
            cmakeCmd[#cmakeCmd+1] = argDef.key
            for _,item in pairs(value) do
                cmakeCmd[#cmakeCmd+1] = toCMakeArg(item)
            end
        elseif argDef.type == 'value' then
            cmakeCmd[#cmakeCmd+1] = argDef.key
            cmakeCmd[#cmakeCmd+1] = toCMakeArg(value)
        elseif argDef.type == 'multiple' then
            for _,subVal in pairs(value) do
                processArg(list(argDef.key), subVal)
            end
        elseif argDef.type == 'option' then
            -- TODO
            if type(value) ~= 'boolean' then
                errorFmt('Unexpected type for argument %s in %s', key, commandTable.luaFunction)
            end
            if value then
                cmakeCmd[#cmakeCmd+1] = argDef.key
            end
        end
    end

    for idx,value in ipairs(argTable) do
        --[[
        if not commandTable[idx] then
            errorFmt('Unexpected value argument in call to %s', commandTable.luaFunction)
        end
        --]]
        cmakeCmd[#cmakeCmd+1] = toCMakeArg(value)
    end

    for name,value in pairs(argTable) do
        if type(name) ~= 'number' then
            local argDef = argDefs[name]
            if argDef == nil then
                errorFmt('Unrecognized argument %s in call to %s',
                    name, functionName
                    )
            end

            processArg(argDef, value)
        end
    end

end

function doCommand(commandTable, argTable)

    local explicitArgCount = commandTable.explicitArgCount
    explicitArgCount = explicitArgCount ~= nil and explicitArgCount or 0

    if #argTable ~= explicitArgCount then
        errorFmt('Expected %s arguments in call to %s; got %s',
            tostring(explicitArgCount), commandTable.luaFunction,
            tostring(#argTable)
            )
    end

    local cmakeCmd =
    {
        commandTable.cmakeFunction
    }

    processArgTable(commandTable.luaFunction, commandTable.args, argTable, cmakeCmd)

    pretty.dump(cmakeCmd)
    executeCommand(unpack(cmakeCmd))
end

cm = {}
cmc = {}

-- -----------------------------------------------------------------------------
function cm.eval(cmakeStr)
    -- TODO: support multiple out vars
    executeCommand('set', 'out_var', '""')
    cmakeStr = template.substitute(cmakeStr, getfenv())
    print(cmakeStr)
    executeCommand('cmake_language', 'EVAL', 'CODE', cmakeStr)
    return getDefinition('out_var')
end

-- -----------------------------------------------------------------------------
function registerCommand(commandTable)

    local luaFunction = commandTable.luaFunction or commandTable.cmakeFunction

    assert(type(luaFunction) == 'string')

    cm[luaFunction] = function(argTable)
        doCommand(commandTable, argTable)
    end
end

-- -----------------------------------------------------------------------------
function list(cmakeArgKey)
    return { type='list', key=cmakeArgKey }
end

-- -----------------------------------------------------------------------------
function multiple(cmakeArgKey)
    return { type='multiple', key=cmakeArgKey }
end

-- -----------------------------------------------------------------------------
function value(cmakeArgKey)
    return { type='value', key=cmakeArgKey }
end

-- -----------------------------------------------------------------------------
function option(cmakeArgKey)
    return { type='option', key=cmakeArgKey }
end

registerCommand {
    luaFunction = 'addCustomCommand',
    cmakeFunction = 'add_custom_command',
    args =
    {
        outputs = list 'OUTPUT',
        commands = multiple 'COMMAND',
        mainDependency = value 'MAIN_DEPENDENCY',
        depends = list 'DEPENDS',
        byproducts = value 'BYPRODUCTS',
        implictDepends = list('IMPLICIT_DEPENDS'),
        workingDir = value('WORKING_DIRECTORY'),
        comment = value('COMMENT'),
        depFile = value('DEPFILE'),
        verbatim = option('VERBATIM'),
        append = option('APPEND'),
        usesTerminal = option('USES_TERMINAL'),
        commandExpandLists = option('COMMAND_EXPAND_LISTS')
    }
}

registerCommand {
    luaFunction = 'addCustomTarget',
    cmakeFunction = 'add_custom_target',
    explicitArgCount = 1,
    args =
    {
        commands = multiple 'COMMAND',
        depends = list 'DEPENDS'
    }
}

registerCommand {
    luaFunction = 'fileWriteImpl',
    cmakeFunction = 'file',
    explicitArgCount = 3,
}

-- -----------------------------------------------------------------------------
function cm.esc(str)
    return string.gsub(str, ';', [[\;]])
end

-- -----------------------------------------------------------------------------
function cm.fileAppend(fileName, content)
    executeCommand('file', 'APPEND', fileName, toCMakeArg(content))
end

local fileReadArgs = {
    offset = value 'OFFSET',
    limit = value 'LIMIT',
    hex = option 'HEX'
}

-- -----------------------------------------------------------------------------
function cm.fileRead(fileName, argTable)

    local cmakeCmd = {'file', 'READ', fileName, '_lua_tmp'}

    if argTable then
        processArgTable('fileRead', fileReadArgs, argTable, cmakeCmd)
    end

    executeCommand(unpack(cmakeCmd))
    return getDefinition('_lua_tmp')
end

-- -----------------------------------------------------------------------------
function cm.fileWrite(fileName, content)
    executeCommand('file', 'WRITE', fileName, toCMakeArg(content))
end

-- -----------------------------------------------------------------------------
function cm.isCommand(cmdName)
    -- TODO: native implementation of DEFINED
    local result = cm.eval(string.format([[
    if (COMMAND %s)
        set(out_var 1)
    else()
        set(out_var 0)
    endif()
    ]], cmdName))

    return result == '1'
end
-- -----------------------------------------------------------------------------
function cm.isDefined(varName)
    -- TODO: native implementation of DEFINED
    local result = cm.eval(string.format([[
    if (DEFINED %s)
        set(out_var 1)
    else()
        set(out_var 0)
    endif()
    ]], varName))

    return result == '1'
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

cm.addCustomCommand {
    commands = { {'bash', '-c', 'ls -alrt; echo "@@DONE"'} },
    outputs = { 'myoutfile.txt' }
}
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

    --[[
cm.addCustomTarget {
    'testtarget',
    depends = { 'myoutfile.txt', 'myoutfile3.txt' }
}
--]]

cm.add_custom_target [[
    testtarget
    DEPENDS myoutfile.txt myoutfile3.txt
    ]]

-- TODO: support DEFINED, COMMAND and other predicates

outFile = 'myoutfile2.txt'

teststring = 'string;with;semis'
cm [[
    add_custom_target(testtarget2 DEPENDS $(outFile))
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/blah.txt $(cm.esc(teststring)))
]]

print('READ: ' .. cm.fileRead('${CMAKE_CURRENT_BINARY_DIR}/blah.txt'))
print('READ OFS: ' ..
    cm.fileRead(
        '${CMAKE_CURRENT_BINARY_DIR}/blah.txt',
        { offset = 2 }
        )
    )
local content = cm.file [[
    READ ${CMAKE_CURRENT_BINARY_DIR}/blah.txt
    out_var
    ]]
print('OUT VAR: ' .. content)

--[[
executeCommand('message', 'STATUS', 'LUA: Adding cmake subdirectory')
-- executeCommand('set', 'SOME_VAR', 'Variable set in lua')
executeCommand('set', 'SOME_VAR', 'Cached value', 'CACHE', 'INTERNAL', '')

executeCommand('message', 'STATUS', 'LUA: SOME_VAR=${SOME_VAR}')
executeCommand('add_subdirectory', 'subdir')
executeCommand('message', 'STATUS', 'LUA: Return from add_subdirectory')
executeCommand('message', 'STATUS', 'LUA: SOME_VAR=${SOME_VAR}')
--]]

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
        end
        table.insert(cmakeCmd, arg)
    end
    cmakeCmd._retVarCount = retVarCount
end

local cmakeCmdMeta =
{
    __call = function(tbl)
        print('__call')
        pretty.dump(tbl)
        local retVarCount = tbl._retVarCount
        tbl._retVarCount = nil

        --
        -- Clear all out vars, so we don't unintentionally return a stale
        -- value
        --
        for i=1,retVarCount do
            executeCommand('set', '_lua_out_var_' .. tostring(i), '')
        end

        executeCommand(unpack(tbl))

        local retTable = {}
        for i=1,retVarCount do
            table.insert(retTable, getDefinition('_lua_out_var_' .. tostring(i)))
        end

        return unpack(retTable)
    end,
    __index = function(cmakeCmd, key)
        print('__index: ' .. key)
        return function(...)
            table.insert(cmakeCmd, string.upper(key))
            cm.addArgsToCmd(cmakeCmd, ...)
            return cmakeCmd
        end
    end
}

-- -----------------------------------------------------------------------------
function cm.returnVar()
    return { _isOutVar = true }
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

print('Result: ' .. tostring(result))
print('Out: ' .. out)
print('Err: ' .. err)

_G.AGlobalVar = 'global'
cmc.add_subdirectory 'subdir'()
