cmake_minimum_required(VERSION 3.18)
project(scanforge_engine CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(SF_BUILD_TOOLS "Build the desktop command line tool" OFF)

# OpenCV (Apache 2.0). Point OpenCV_DIR at the OpenCV package for the target:
#  Android : <OpenCV-android-sdk>/sdk/native/jni
#  Windows : <opencv>/build
#  iOS     : provided by the Xcode project
find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs features2d calib3d flann)

set(SF_SOURCES
    src/util.cpp
    src/features.cpp
    src/sfm.cpp
    src/ba.cpp
    src/dense.cpp
    src/fusion.cpp
    src/mesh.cpp
    src/export.cpp
    src/api.cpp
)

add_library(scanforge SHARED ${SF_SOURCES})
target_include_directories(scanforge PUBLIC include PRIVATE src ${OpenCV_INCLUDE_DIRS})
target_link_libraries(scanforge PRIVATE ${OpenCV_LIBS})
set_target_properties(scanforge PROPERTIES CXX_VISIBILITY_PRESET hidden)

if(NOT MSVC)
    target_compile_options(scanforge PRIVATE -O3 -Wall -Wno-sign-compare)
else()
    target_compile_options(scanforge PRIVATE /O2 /EHsc /utf-8)
    target_compile_definitions(scanforge PRIVATE _USE_MATH_DEFINES NOMINMAX)
endif()

if(ANDROID)
    find_library(log-lib log)
    target_link_libraries(scanforge PRIVATE ${log-lib})
    # 16 KB page size support (Android 15+ devices)
    target_link_options(scanforge PRIVATE "-Wl,-z,max-page-size=16384")
endif()

if(UNIX AND NOT ANDROID AND NOT APPLE)
    find_package(Threads REQUIRED)
    target_link_libraries(scanforge PRIVATE Threads::Threads)
endif()

if(SF_BUILD_TOOLS)
    add_executable(sf_cli tools/sf_cli.cpp)
    target_include_directories(sf_cli PRIVATE include ${OpenCV_INCLUDE_DIRS})
    target_link_libraries(sf_cli PRIVATE scanforge ${OpenCV_LIBS})
endif()
