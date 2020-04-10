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

int luaExecuteCommand(lua_State* L)
{
    cmMakefile* makeFile = static_cast<cmMakefile*>(lua_touserdata(L, 1));

    cmListFileFunction function {};
    function.Name = lua_tostring(L, 2);
    function.Line = 0; // @@@@@ line

    for (int i = 3; i <= lua_gettop(L); ++i)
    {
        function.Arguments.emplace_back(lua_tostring(L, i),
            cmListFileArgument::Quoted, 0); // @@@@@ line
    }

    cmExecutionStatus status(*makeFile);
    makeFile->ExecuteCommand(function, status);

    return 0;
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

  lua_State* L = lua_open();
  luaL_openlibs(L);

  lua_register(L, "executeCommand", luaExecuteCommand);
  lua_register(L, "getDefinition", luaGetDefinition);
  lua_pushlightuserdata(L, &makefile);
  lua_setglobal(L, "cmMakefile");

  bool result = (luaL_dofile(L, inputFile.c_str()) == 0);

  if (!result) {
    status.SetError("Problem executing lua script");
  }

  lua_close(L);

  return result;
}
