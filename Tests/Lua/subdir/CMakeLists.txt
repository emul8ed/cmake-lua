message(STATUS "CMAKE: Sub directory")
message(STATUS "CMAKE: SOME_VAR=${SOME_VAR}")
set(SOME_VAR "Updated in cmake subdir" PARENT_SCOPE)

Lua("cmakelists.lua")
