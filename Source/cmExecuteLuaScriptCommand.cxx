/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file Copyright.txt or https://cmake.org/licensing for details.  */
#include "cmExecuteLuaScriptCommand.h"

#include <lua5.1/lua.hpp>

#include "cmExecutionStatus.h"
#include "cmMakefile.h"
#include "cmMessageType.h"
#include "cmNewLineStyle.h"
#include "cmStringAlgorithms.h"
#include "cmSystemTools.h"
#include "cmState.h"

int luaCurrentSourceLine = 0;

int luaExecuteCommand(lua_State* L)
{
    cmMakefile* makeFile = static_cast<cmMakefile*>(lua_touserdata(L, lua_upvalueindex(1)));

    cmListFileFunction function {};
    function.Name = lua_tostring(L, 1);
    function.Line = luaCurrentSourceLine;

    for (int i = 2; i <= lua_gettop(L); ++i)
    {
        function.Arguments.emplace_back(lua_tostring(L, i),
            cmListFileArgument::Quoted, 0); // @@@@@ line
    }

    cmExecutionStatus status(*makeFile);
    bool result = makeFile->ExecuteCommand(function, status);

    lua_pushboolean(L, result);
    if (!result)
    {
        lua_pushstring(L, status.GetError().c_str());
    }
    else
    {
        lua_pushnil(L);
    }

    return 2;
}

int luaGetDefinition(lua_State* L)
{
    cmMakefile* makeFile = static_cast<cmMakefile*>(lua_touserdata(L, lua_upvalueindex(1)));

    std::string name = lua_tostring(L, 1);

    const char* def = makeFile->GetDefinition(name);

    if (def)
    {
        lua_pushstring(L, def);
    }
    else
    {
        lua_pushnil(L);
    }

    return 1;
}

void luaHookLine(lua_State* L, lua_Debug* ar)
{
    (void)L;
    luaCurrentSourceLine = ar->currentline;
}

int luaExpandList(lua_State* L)
{
    cm::string_view value = luaL_checkstring(L, 1);

    std::vector<std::string> list;
    constexpr bool emptyArgs = true;
    cmExpandList(value, list, emptyArgs);

    lua_newtable(L);
    int tableIdx = lua_gettop(L);
    int idx = 1;
    for (auto const& item : list)
    {
        lua_pushstring(L, item.c_str());
        lua_rawseti(L, tableIdx, idx++);
    }

    lua_settop(L, tableIdx);
    lua_pushinteger(L, list.size());

    return 2;
}

lua_State* InitLuaState()
{
  lua_State* L = lua_open();
  luaL_openlibs(L);

  lua_register(L, "executeCommand", luaExecuteCommand);
  lua_register(L, "getDefinition", luaGetDefinition);

  lua_sethook(L, luaHookLine, LUA_MASKLINE, 0);
  return L;
}

// cmExecLuaScriptCommand
bool cmExecLuaScriptCommand(std::vector<std::string> const& args,
                            cmExecutionStatus& status)
{
  if (args.size() != 1) {
    status.SetError("called with incorrect number of arguments, expected 1");
    return false;
  }

  std::string const& inFile = args[0];
  const std::string inputFile = cmSystemTools::CollapseFullPath(
    inFile, status.GetMakefile().GetCurrentSourceDirectory());

  // If the input location is a directory, error out.
  if (cmSystemTools::FileIsDirectory(inputFile)) {
    status.SetError(cmStrCat("input location\n  ", inputFile,
                             "\n"
                             "is a directory but a file was expected."));
    return false;
  }

  cmMakefile& makefile = status.GetMakefile();

  makefile.AddCMakeDependFile(inputFile);

  lua_State* L = makefile.GetState()->GetLuaState();

  // @@@@@ Set this in the function env
  lua_pushlightuserdata(L, &makefile);
  lua_pushcclosure(L, luaExecuteCommand, 1);
  lua_setglobal(L, "executeCommand");

  lua_pushlightuserdata(L, &makefile);
  lua_pushcclosure(L, luaGetDefinition, 1);
  lua_setglobal(L, "getDefinition");

  lua_pushlightuserdata(L, &makefile);
  lua_pushcclosure(L, luaExpandList, 1);
  lua_setglobal(L, "expandList");

  bool result = (luaL_dofile(L, inputFile.c_str()) == 0);

  if (!result) {
    status.SetError(lua_tostring(L, 1));
  }

  return result;
}
