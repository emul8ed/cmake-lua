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
    cmMakefile* makeFile = static_cast<cmMakefile*>(lua_touserdata(L, 1));

    cmListFileFunction function {};
    function.Name = lua_tostring(L, 2);
    function.Line = luaCurrentSourceLine;

    for (int i = 3; i <= lua_gettop(L); ++i)
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
    cmMakefile* makeFile = static_cast<cmMakefile*>(lua_touserdata(L, 1));

    std::string name = lua_tostring(L, 2);

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

int lInitLuaState(lua_State* L)
{
  luaL_openlibs(L);

  lua_register(L, "executeCommand", luaExecuteCommand);
  lua_register(L, "getDefinition", luaGetDefinition);
  lua_register(L, "expandList", luaExpandList);

  lua_sethook(L, luaHookLine, LUA_MASKLINE, 0);

  std::string cmakeLuaPath = cmSystemTools::GetCMakeRoot() + "/Modules/CMake.lua";

  int result = luaL_loadfile(L, cmakeLuaPath.c_str());
  if (result != 0)
  {
    lua_error(L);
  }

  lua_call(L, 0, 0);

  return 0;
}

// cmExecLuaScriptCommand
bool cmExecLuaScriptCommand(std::vector<std::string> const& args,
                            cmExecutionStatus& status)
{
  if (args.size() != 1) {
    status.SetError("called with incorrect number of arguments, expected 1");
    return false;
  }

  bool result = true;
  cmMakefile& makefile = status.GetMakefile();

  lua_State* L = makefile.GetState()->GetLuaState();

  int initTop = lua_gettop(L);

  lua_getglobal(L, "executeCommand");

  bool initRequired = lua_isnil(L, -1);
  lua_pop(L, 1);
  if (initRequired) {
    int result = lua_cpcall(L, lInitLuaState, nullptr);
    if (result != 0)
    {
      status.SetError(lua_tostring(L, 1));
      result = false;
    }
  }

  std::string inputFile;
  if (result) {
    std::string const& inFile = args[0];
    inputFile = cmSystemTools::CollapseFullPath(
      inFile, status.GetMakefile().GetCurrentSourceDirectory());

    // If the input location is a directory, error out.
    if (cmSystemTools::FileIsDirectory(inputFile)) {
      status.SetError(cmStrCat("input location\n  ", inputFile,
                               "\n"
                               "is a directory but a file was expected."));
      result = false;
    }
  }

  if (result) {
    makefile.AddCMakeDependFile(inputFile);

    lua_getglobal(L, "execLuaScript");
    lua_pushstring(L, inputFile.c_str());
    lua_pushlightuserdata(L, &makefile);
    result = (lua_pcall(L, 2, 0, 0) == 0);

    if (!result) {
      status.SetError(lua_tostring(L, 1));
    }
  }

  lua_settop(L, initTop);

  return result;
}
