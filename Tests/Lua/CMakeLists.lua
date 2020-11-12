print('Raw print() call from lua')

local executeCommand = executeCommand
local getDefinition = getDefinition

function cmakeEnvIndex(envTable, key)
    --[[
    if string.upper(key) == key then
        --
        -- Treat all-uppercase variables as cmake function arguments.
        -- @@@@@ This should probably be a type not just a string.
        --
        return key
    end
    --]]

    if envTable.__root then
        local cmakeCall = { __cmakefn=key }

        setmetatable(cmakeCall,
            {
                __index = function()
                    return nil
                end,
                __call = function(table, ...)
                    envTable.__root = true

                    print(table.__cmakefn .. '(' .. _G.table.concat({...}, ', ') .. ')')
                    executeCommand(table.__cmakefn, ...)

                    local result = {}
                    setmetatable(result, {
                        __tostring = function(table)
                            error(string.format('Attempt to convert cmake call to string (key=%s)', key))
                        end }
                        )
                    return result
                end,
                __newindex = function()
                    error('Cmake function call table is read-only')
                end
            })

        envTable.__root = false

        return cmakeCall
    else
        local envResult = rawget(getfenv(), key)

        if envResult ~= nil then
            return envResult
        else
            return key
        end
    end
end

function cmake(envFn)
    local env =
    {
        __root = true
    }
    setfenv(envFn, env)

    local upIdx = 1
    while true do
        local name = debug.getupvalue(envFn, upIdx)
        if name == nil then
            break
        end
        error('Upvalue capture not allowed')
        if name == string.upper(name) then
            error(string.format('Captured all-caps upvalue "%s". All-caps names are reserved for cmake call arguments.', name))
        end

        upIdx = upIdx + 1
    end

    setmetatable(env,
    {
        __index = cmakeEnvIndex,
        __newindex = function()
            error('Cmake env is read-only')
        end
    })

    envFn()
end

_G.AGlobalVar = 'global'

message = 'foo'

cmake(function()
    message(STATUS, 'LUA: Adding cmake subdirectory')

    set(SOME_VAR, 'Cached value', CACHE, INTERNAL, '')

    message(STATUS, 'LUA: SOME_VAR=${SOME_VAR}')
    message(STATUS, message)

    add_subdirectory('subdir')

    message(STATUS, 'LUA: Return from add_subdirectory')
    message(STATUS, 'LUA: SOME_VAR=${SOME_VAR}')
end)

function toCMakeArg(luaValue)
    -- TODO: expand lists when pushing cmake vars on C++ side
    local valType = type(luaValue)
    if valType == 'table' then
        -- TODO: reject values that end in unquoted backslash? Or handle quoting/unquoting?
        return table.concat(luaValue, ';')
    elseif valType == 'string' then
        return luaValue
    elseif valType == 'boolean' then
        return (luaValue and 'TRUE') or 'FALSE'
    else
        errorFmt('Invalid type for cmake value %s', valType)
    end
end

function doCommand(commandTable, argTable)

    local cmakeCmd =
    {
        commandTable.cmakeFunction
    }

    for idx,value in ipairs(argTable) do
        -- TODO: registerCommand valueCount arg
        if not commandTable[idx] then
            errorFmt('Unexpected value argument in call to %s', commandTable.luaFunction)
        end
        cmakeCmd[#cmakeCmd+1] = toCMakeArg(value)
    end

    -- TODO: catch unrecognized args
    for _,argDef in ipairs(commandTable) do
        local arg = argTable[argDef.name]
        if not arg then
            next -- TODO: is this right?
        end

        if argDef.type == 'list' or argDef.type == 'value' then
            cmakeCmd[#cmakeCmd+1] = argDef.cmakeArg
            cmakeCmd[#cmakeCmd+1] = toCMakeArg(value)
        elseif argDef.type == 'option' then
            -- TODO
            if type(value) ~= 'boolean' then
                errorFmt('Unexpected type for argument %s in %s', key, commandTable.luaFunction)
            end
            if value then
                cmakeCmd[#cmakeCmd+1] = argDef.cmakeArg
            end
        end
    end
end

function registerCommand(commandTable)
    assert(type(commandTable.luaFunction) == 'string')

    _G[commandTable.luaFunction] = function(argTable)
        doCommand(commandTable, argTable)
    end
end

registerCommand {
    luaFunction = 'addCustomCommand',
    cmakeFunction = 'add_custom_command',
    args =
    {
        outputs = list('OUTPUT'),
        commands = multiple('COMMAND'),
        mainDependency = value('MAIN_DEPENDENCY'),
        depends = value('DEPENDS'),
        byproducts = value('BYPRODUCTS'),
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

cmake.addCustomCommand
{
    outputs = 'myoutfile.txt',
}

--[[
executeCommand('message', 'STATUS', 'LUA: Adding cmake subdirectory')
-- executeCommand('set', 'SOME_VAR', 'Variable set in lua')
executeCommand('set', 'SOME_VAR', 'Cached value', 'CACHE', 'INTERNAL', '')

executeCommand('message', 'STATUS', 'LUA: SOME_VAR=${SOME_VAR}')
executeCommand('add_subdirectory', 'subdir')
executeCommand('message', 'STATUS', 'LUA: Return from add_subdirectory')
executeCommand('message', 'STATUS', 'LUA: SOME_VAR=${SOME_VAR}')
--]]

local someVar = getDefinition('SOME_VAR');
print('RAW: ' .. someVar)

local foo = 'foovalue'

cmake(function()
    add_custom_target('acustomtarget', ALL)
    set('ValueX', 'CachedValue', CACHE, STRING, 'Doc')
    message(STATUS, 'This is a message from lua')
    -- add_subdirectory('foo')
end)

