cmake_minimum_required(VERSION 3.17)
project("Badger")

lua(SCRIPT "CMakeLists.lua")
lua(CALL TestLuaFunction direct)
TestLuaFunction(indirect)
