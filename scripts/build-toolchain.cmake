# Build Beam with an explicitly selected native Lean installation. No elan or installer side effects.
cmake_minimum_required(VERSION 3.21)
if(NOT DEFINED LEAN_PREFIX)
  message(FATAL_ERROR "pass -DLEAN_PREFIX=/path/to/lean/installation")
endif()
file(REAL_PATH "${LEAN_PREFIX}" LEAN_PREFIX)
get_filename_component(BEAM_SOURCE "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
execute_process(COMMAND git rev-parse HEAD WORKING_DIRECTORY "${BEAM_SOURCE}"
  OUTPUT_VARIABLE SOURCE_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
if(CMAKE_HOST_WIN32)
  set(EXE ".exe")
  set(PLUGIN "beam_Beam_LSP.dll")
  # Resolve native SDK headers before Lake prepends the selected Lean's bin directory to PATH.
  if(NOT DEFINED NATIVE_CLANG_RESOURCE_DIR)
    find_program(BEAM_NATIVE_CLANG NAMES clang REQUIRED)
    execute_process(COMMAND "${BEAM_NATIVE_CLANG}" --print-resource-dir
      OUTPUT_VARIABLE NATIVE_CLANG_RESOURCE_DIR OUTPUT_STRIP_TRAILING_WHITESPACE
      COMMAND_ERROR_IS_FATAL ANY)
  endif()
  if(NOT EXISTS "${NATIVE_CLANG_RESOURCE_DIR}/include/x86intrin.h")
    message(FATAL_ERROR "select a full native clang SDK with -DNATIVE_CLANG_RESOURCE_DIR=/sdk/lib/clang/VERSION")
  endif()
  set(NATIVE_SDK_ENV "BEAM_NATIVE_CLANG_RESOURCE_DIR=${NATIVE_CLANG_RESOURCE_DIR}")
elseif(CMAKE_HOST_APPLE)
  set(EXE "")
  set(PLUGIN "libbeam_Beam_LSP.dylib")
else()
  set(EXE "")
  set(PLUGIN "libbeam_Beam_LSP.so")
endif()
set(LEAN "${LEAN_PREFIX}/bin/lean${EXE}")
set(LAKE "${LEAN_PREFIX}/bin/lake${EXE}")
set(BUILD "${BEAM_SOURCE}/.lake/toolchain-build")
set(NATIVE_CONFIG "${BEAM_SOURCE}/.lake/toolchain-lakefile.lean")
file(MAKE_DIRECTORY "${BEAM_SOURCE}/.lake")
configure_file("${BEAM_SOURCE}/lakefile.lean" "${NATIVE_CONFIG}" COPYONLY)
execute_process(COMMAND "${LEAN}" --version OUTPUT_VARIABLE LEAN_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${LEAN}" --githash OUTPUT_VARIABLE LEAN_GITHASH OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${LAKE}" --version OUTPUT_VARIABLE LAKE_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
string(LENGTH "${LEAN_GITHASH}" GITHASH_LENGTH)
if(NOT GITHASH_LENGTH EQUAL 40 OR NOT LEAN_GITHASH MATCHES "^[0-9a-f]+$")
  message(FATAL_ERROR "selected Lean must report an exact 40-character compiler commit")
endif()
execute_process(COMMAND "${CMAKE_COMMAND}" -E env --unset=LAKE_HOME --unset=LEAN_PATH --unset=LEAN_SRC_PATH
  "LEAN=${LEAN}" "LEAN_SYSROOT=${LEAN_PREFIX}"
  "${LAKE}" --file "${NATIVE_CONFIG}" --reconfigure -KbeamToolchain=true script run beamToolchainCompilerId
  WORKING_DIRECTORY "${BEAM_SOURCE}" OUTPUT_VARIABLE LAKE_GITHASH
  OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
if(LEAN_GITHASH STREQUAL "" OR NOT LAKE_GITHASH STREQUAL LEAN_GITHASH)
  message(FATAL_ERROR "selected Lean and Lake must have the same exact compiler commit")
endif()
execute_process(COMMAND "${CMAKE_COMMAND}" -E env --unset=LAKE_HOME --unset=LEAN_PATH --unset=LEAN_SRC_PATH
  --unset=LEAN_CC --unset=LEAN_AR --unset=LEAN_ABORT_ON_PANIC
  "LEAN=${LEAN}" "LEAN_SYSROOT=${LEAN_PREFIX}" "LAKE_CACHE_DIR=${BEAM_SOURCE}/.lake/toolchain-cache"
  ${NATIVE_SDK_ENV}
  "${LAKE}" --file "${NATIVE_CONFIG}" -KbeamToolchain=true --no-cache build beam-cli beam-daemon lean-beam-mcp Beam.LSP:shared
  WORKING_DIRECTORY "${BEAM_SOURCE}" COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${BUILD}/bin/beam-cli${EXE}" toolchain-build-info
  OUTPUT_VARIABLE BUILD_INFO COMMAND_ERROR_IS_FATAL ANY)
string(JSON COMPILED_GITHASH GET "${BUILD_INFO}" leanGithash)
if(NOT COMPILED_GITHASH STREQUAL LEAN_GITHASH)
  message(FATAL_ERROR "Beam compiled with another Lean compiler; selected Lean/Lake libraries must match exactly")
endif()
foreach(ARTIFACT "bin/beam-cli${EXE}" "bin/beam-daemon${EXE}" "bin/lean-beam-mcp${EXE}" "lib/${PLUGIN}")
  file(SHA256 "${BUILD}/${ARTIFACT}" HASH)
  string(APPEND BUILD_HASHES "set(BEAM_BUILD_HASH_${ARTIFACT} ${HASH})\n")
endforeach()
file(WRITE "${BEAM_SOURCE}/.lake/toolchain-build.cmake"
  "set(BEAM_BUILD_SOURCE_COMMIT ${SOURCE_COMMIT})\nset(BEAM_BUILD_LEAN_VERSION [==[${LEAN_VERSION}]==])\nset(BEAM_BUILD_LEAN_GITHASH [==[${LEAN_GITHASH}]==])\nset(BEAM_BUILD_LAKE_VERSION [==[${LAKE_VERSION}]==])\n${BUILD_HASHES}")
