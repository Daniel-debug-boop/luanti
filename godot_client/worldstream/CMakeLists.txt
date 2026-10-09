# WorldStream native build.
#
# One tree, three products, built in dependency order:
#
#   worldstream_core   the streaming modules (H3 grid, tile parse, meshing)
#   worldstream_tests  the headless unit suite for those modules
#   worldstream        the GDExtension the Godot client loads (optional)
#
# The third-party dependencies are pinned submodules under third_party/, and
# nothing is fetched at configure time: a build either has its sources or it
# fails loudly, because a build that silently downloads something is a build
# that cannot be reproduced.
#
# Configure with, e.g.:
#   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
#   cmake -S . -B build -DWS_BUILD_GDEXTENSION=ON -DGODOTCPP_DIR=../godot-cpp
#
# ws_build/build.sh drives exactly this; use it rather than calling cmake by
# hand so the profile and the output layout match what the Godot project
# expects.

cmake_minimum_required(VERSION 3.20)

project(worldstream LANGUAGES C CXX)

option(WS_BUILD_TESTS "Build the native unit tests" ON)
option(WS_BUILD_GDEXTENSION "Build the Godot GDExtension" OFF)

set(WS_GODOTCPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../godot-cpp"
    CACHE PATH "Path to the godot-cpp checkout (submodule)")
set(WS_GODOTCPP_PROFILE "${CMAKE_CURRENT_SOURCE_DIR}/ws_build_profile.json"
    CACHE FILEPATH "godot-cpp build profile used for the extension build")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# The GDExtension is a shared object, and it links the core and the third-party
# static libraries into itself. Position-independent code therefore has to be
# on for every target in the tree, not just the last one -- set before the
# subprojects are added so h3 and meshoptimizer get it too.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# --- third-party -------------------------------------------------------------

# h3 (MIT) is a C library built from the pinned submodule. Its own test and
# filter targets are not part of this project's build.
set(BUILD_FILTERS OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/h3 EXCLUDE_FROM_ALL)

# meshoptimizer (MIT): the meshlet builder and the vertex-cache/fetch passes.
set(MESHOPT_BUILD_DEMO OFF CACHE BOOL "" FORCE)
set(MESHOPT_BUILD_GLTFPACK OFF CACHE BOOL "" FORCE)
set(MESHOPT_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(MESHOPT_INSTALL OFF CACHE BOOL "" FORCE)
add_subdirectory(third_party/meshoptimizer EXCLUDE_FROM_ALL)

# vtzero and protozero are header-only; earcut.hpp is a single vendored header.
set(WS_THIRD_PARTY_INCLUDES
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/vtzero/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/protozero/include")

# --- core --------------------------------------------------------------------

add_library(worldstream_core STATIC
    src/ws_streamer.cpp
    src/ws_mesher.cpp)
target_include_directories(worldstream_core
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/src"
    PRIVATE ${WS_THIRD_PARTY_INCLUDES})
# h3's headers are consumed unprefixed (`<h3api.h>`) from its build-tree
# include dirs, which the h3 target exports itself.
target_link_libraries(worldstream_core PUBLIC h3 meshoptimizer)

# --- tests -------------------------------------------------------------------

if(WS_BUILD_TESTS)
    add_executable(worldstream_tests tools/worldstream_test.cpp)
    target_include_directories(worldstream_tests PRIVATE ${WS_THIRD_PARTY_INCLUDES})
    target_link_libraries(worldstream_tests PRIVATE worldstream_core)
    enable_testing()
    add_test(NAME worldstream_native COMMAND worldstream_tests)
endif()

# --- GDExtension -------------------------------------------------------------

if(WS_BUILD_GDEXTENSION)
    if(NOT EXISTS "${WS_GODOTCPP_DIR}/CMakeLists.txt")
        message(FATAL_ERROR
            "WS_BUILD_GDEXTENSION=ON but godot-cpp was not found at "
            "'${WS_GODOTCPP_DIR}'. Run: git submodule update --init "
            "godot_client/godot-cpp")
    endif()

    # The extension uses Variant types and its own registered classes only --
    # no engine class bindings -- so godot-cpp is built from a profile that
    # lists just RefCounted. That turns a 1 964-file build into a few dozen
    # files without changing what the extension can do. See
    # worldstream/ws_build_profile.json.
    set(GODOTCPP_BUILD_PROFILE "${WS_GODOTCPP_PROFILE}" CACHE FILEPATH "" FORCE)
    add_subdirectory("${WS_GODOTCPP_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/godot-cpp")

    add_library(worldstream SHARED
        src/gdextension/register_types.cpp
        src/gdextension/world_stream_native.cpp)
    target_include_directories(worldstream PRIVATE ${WS_THIRD_PARTY_INCLUDES})
    target_link_libraries(worldstream
        PRIVATE worldstream_core godot-cpp::template_release)
    target_compile_definitions(worldstream PRIVATE
        WS_GDEXTENSION_LIBRARY_NAME="worldstream")

    # Output layout the .gdextension file points at:
    #   ws_build/bin/libworldstream.linux.template_release.x86_64.so
    get_target_property(WS_GODOTCPP_SUFFIX godot-cpp::template_release GODOTCPP_SUFFIX)
    # godot-cpp's suffix already carries its leading dot ("
    # .linux.template_release.x86_64"), so it is concatenated, not joined.
    set_target_properties(worldstream PROPERTIES
        OUTPUT_NAME "worldstream${WS_GODOTCPP_SUFFIX}"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../ws_build/bin"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../ws_build/bin"
        POSITION_INDEPENDENT_CODE ON
        CXX_VISIBILITY_PRESET hidden
        BUILD_RPATH_USE_ORIGIN ON)
endif()
