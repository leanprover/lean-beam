# Build Beam with an explicitly selected native Lean installation. No elan or installer side effects.
cmake_minimum_required(VERSION 3.21)
include("${CMAKE_CURRENT_LIST_DIR}/toolchain-manifest.cmake")
if(NOT DEFINED LEAN_PREFIX)
  message(FATAL_ERROR "pass -DLEAN_PREFIX=/path/to/lean/installation")
endif()
file(REAL_PATH "${LEAN_PREFIX}" LEAN_PREFIX)
get_filename_component(BEAM_SOURCE "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
execute_process(COMMAND git rev-parse HEAD WORKING_DIRECTORY "${BEAM_SOURCE}"
  OUTPUT_VARIABLE SOURCE_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
if(CMAKE_HOST_WIN32)
  set(EXE ".exe")
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
  string(REPLACE ";" "\\;" NATIVE_RESOURCE_ENV "BEAM_NATIVE_CLANG_RESOURCE_DIR=${NATIVE_CLANG_RESOURCE_DIR}")
  set(NATIVE_SDK_ENV "${NATIVE_RESOURCE_ENV}")
  set(NATIVE_SYSTEM_INCLUDES "[]")
  set(index 0)
  foreach(directory IN LISTS NATIVE_SYSTEM_INCLUDE_DIRS)
    if(NOT IS_DIRECTORY "${directory}")
      message(FATAL_ERROR "native Windows system include directory does not exist: ${directory}")
    endif()
    file(REAL_PATH "${directory}" directory)
    beam_json_string("${directory}" value)
    string(JSON NATIVE_SYSTEM_INCLUDES SET "${NATIVE_SYSTEM_INCLUDES}" ${index} "${value}")
    math(EXPR index "${index}+1")
  endforeach()
  string(REPLACE ";" "\\;" NATIVE_INCLUDE_ENV "BEAM_NATIVE_SYSTEM_INCLUDE_DIRS=${NATIVE_SYSTEM_INCLUDES}")
  list(APPEND NATIVE_SDK_ENV "${NATIVE_INCLUDE_ENV}")
else()
  set(EXE "")
endif()
set(LEAN "${LEAN_PREFIX}/bin/lean${EXE}")
set(LAKE "${LEAN_PREFIX}/bin/lake${EXE}")
set(BUILD "${BEAM_SOURCE}/.lake/toolchain-build")
set(NATIVE_CONFIG "${BEAM_SOURCE}/.lake/toolchain-lakefile.lean")
file(MAKE_DIRECTORY "${BEAM_SOURCE}/.lake")
# A generation identifies these executables independently of subsequently replaced metadata.
string(RANDOM LENGTH 32 ALPHABET 0123456789abcdef BEAM_BUILD_ID)
configure_file("${BEAM_SOURCE}/lakefile.lean" "${NATIVE_CONFIG}" COPYONLY)
execute_process(COMMAND "${LEAN}" --version OUTPUT_VARIABLE LEAN_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${LEAN}" --githash OUTPUT_VARIABLE LEAN_GITHASH OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
execute_process(COMMAND "${LAKE}" --version OUTPUT_VARIABLE LAKE_VERSION OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
string(LENGTH "${LEAN_GITHASH}" GITHASH_LENGTH)
if(NOT GITHASH_LENGTH EQUAL 40 OR NOT LEAN_GITHASH MATCHES "^[0-9a-f]+$")
  message(FATAL_ERROR "selected Lean must report an exact 40-character compiler commit")
endif()
set(BEAM_LAKE_ENV_FILTER --unset=LAKE_HOME --unset=LEAN_PATH --unset=LEAN_SRC_PATH
  --unset=LEAN_CC --unset=LEAN_AR --unset=LEAN_ABORT_ON_PANIC)
execute_process(COMMAND "${CMAKE_COMMAND}" -E env ${BEAM_LAKE_ENV_FILTER}
  "LEAN=${LEAN}" "LEAN_SYSROOT=${LEAN_PREFIX}"
  "${LAKE}" --file "${NATIVE_CONFIG}" --reconfigure -KbeamToolchain=true
  "-KbeamBuildId=${BEAM_BUILD_ID}" "-KbeamSourceRevision=${SOURCE_COMMIT}"
  script run beamToolchainCompilerId
  WORKING_DIRECTORY "${BEAM_SOURCE}" OUTPUT_VARIABLE LAKE_GITHASH
  OUTPUT_STRIP_TRAILING_WHITESPACE COMMAND_ERROR_IS_FATAL ANY)
if(LEAN_GITHASH STREQUAL "" OR NOT LAKE_GITHASH STREQUAL LEAN_GITHASH)
  message(FATAL_ERROR "selected Lean and Lake must have the same exact compiler commit")
endif()
execute_process(COMMAND "${CMAKE_COMMAND}" -E env ${BEAM_LAKE_ENV_FILTER}
  "LEAN=${LEAN}" "LEAN_SYSROOT=${LEAN_PREFIX}" "LAKE_CACHE_DIR=${BEAM_SOURCE}/.lake/toolchain-cache"
  ${NATIVE_SDK_ENV}
  "${LAKE}" --file "${NATIVE_CONFIG}" -KbeamToolchain=true
  "-KbeamBuildId=${BEAM_BUILD_ID}" "-KbeamSourceRevision=${SOURCE_COMMIT}"
  --no-cache build beam-cli beam-daemon lean-beam-mcp Beam.LSP:shared
  WORKING_DIRECTORY "${BEAM_SOURCE}" COMMAND_ERROR_IS_FATAL ANY)
# Lake's artifact cache hard-links executables. Darwin may identify that inode by its cache
# pathname, making @loader_path relative to the cache instead of this runtime directory.
# Give the complete native payload independent executable files before probing or publishing it.
if(CMAKE_HOST_APPLE)
  foreach(NAME beam-cli beam-daemon lean-beam-mcp)
    set(EXECUTABLE "${BUILD}/bin/${NAME}${EXE}")
    set(MATERIALIZED "${EXECUTABLE}.beam-stage-${BEAM_BUILD_ID}")
    file(COPY_FILE "${EXECUTABLE}" "${MATERIALIZED}")
    file(CHMOD "${MATERIALIZED}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
      GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
    file(RENAME "${MATERIALIZED}" "${EXECUTABLE}")
  endforeach()
endif()
execute_process(COMMAND "${BUILD}/bin/beam-cli${EXE}" toolchain-build-info
  OUTPUT_VARIABLE BUILD_INFO COMMAND_ERROR_IS_FATAL ANY)
string(JSON COMPILED_GITHASH GET "${BUILD_INFO}" compiledLeanRevision)
string(JSON LOADED_GITHASH GET "${BUILD_INFO}" loadedLeanRevision)
string(JSON COMPILED_BUILD_ID GET "${BUILD_INFO}" buildId)
string(JSON COMPILED_SOURCE GET "${BUILD_INFO}" sourceRevision)
if(NOT COMPILED_GITHASH STREQUAL LEAN_GITHASH OR NOT LOADED_GITHASH STREQUAL LEAN_GITHASH)
  message(FATAL_ERROR "Beam compiled with another Lean compiler; selected Lean/Lake libraries must match exactly")
endif()
if(NOT COMPILED_BUILD_ID STREQUAL BEAM_BUILD_ID OR NOT COMPILED_SOURCE STREQUAL SOURCE_COMMIT)
  message(FATAL_ERROR "Beam objects belong to a different source/build generation; rebuild Beam")
endif()
beam_write_native_manifest("${BEAM_SOURCE}/.lake/toolchain-build.json" "${BEAM_SOURCE}"
  "${SOURCE_COMMIT}" "${BEAM_BUILD_ID}" "${LEAN_VERSION}" "${LEAN_GITHASH}" "${LAKE_VERSION}")
