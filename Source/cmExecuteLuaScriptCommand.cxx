/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file Copyright.txt or https://cmake.org/licensing for details.  */
#include "cmExecuteLuaScriptCommand.h"

#include "cmExecutionStatus.h"
#include "cmMakefile.h"
#include "cmMessageType.h"
#include "cmNewLineStyle.h"
#include "cmStringAlgorithms.h"
#include "cmSystemTools.h"

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

  if (!status.GetMakefile().ExecLuaScript(inputFile)) {
    status.SetError("Problem executing lua script");
    return false;
  }

  return true;
}
