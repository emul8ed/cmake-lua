print('Raw print() call from lua')

local executeCommand = executeCommand
local getDefinition = getDefinition

function cmakeEnvIndex(envTable, key)
    if string.upper(key) == key then
        --
        -- Treat all-uppercase variables as cmake function arguments.
        -- @@@@@ This should probably be a type not just a string.
        --
        return key
    end

    local envResult = rawget(getfenv(), key)

    if envResult ~= nil then
        return envResult
    else
        local cmakeCall = { __cmakefn=key }

        setmetatable(cmakeCall,
            {
                __index = function()
                    return nil
                end,
                __call = function(table, ...)
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

        return cmakeCall
    end
end

function cmake(envFn)
    local env = {}
    setfenv(envFn, env)

    local upIdx = 1
    while true do
        local name = debug.getupvalue(envFn, upIdx)
        if name == nil then
            break
        end
        if name == string.upper(name) then
            error(string.format('Captured all-caps upvalue "%s". All-caps names are reserved for cmake call arguments.', name))
        end

        upIdx = upIdx + 1
    end

    setmetatable(env,
    {
        __index = cmakeEnvIndex
    })

    envFn()
end

_G.AGlobalVar = 'global'

cmake(function()
    message(STATUS, 'LUA: Adding cmake subdirectory')

    set(SOME_VAR, 'Cached value', CACHE, INTERNAL, '')

    message(STATUS, 'LUA: SOME_VAR=${SOME_VAR}')

    add_subdirectory('subdir')

    message(STATUS, 'LUA: Return from add_subdirectory')
    message(STATUS, 'LUA: SOME_VAR=${SOME_VER}')
end)

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

