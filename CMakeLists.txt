cmake_minimum_required(VERSION 3.28)

set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum macOS version")

project(Cacophony LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CACOPHONY_VERSION "0.1.0" CACHE STRING "Cacophony version")
set(CACOPHONY_BUNDLE_ID "com.stonerl.Cacophony" CACHE STRING "Application bundle identifier")
set(CODESIGN_ID "-" CACHE STRING "codesign identity, or - for ad-hoc signing")

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(CACOPHONY_SWIFT_CONFIGURATION "debug")
else()
    set(CACOPHONY_SWIFT_CONFIGURATION "release")
endif()

find_program(SWIFT_EXECUTABLE swift REQUIRED)
find_program(CODESIGN_EXECUTABLE codesign REQUIRED)
find_program(ACTOOL_EXECUTABLE actool REQUIRED)

execute_process(
    COMMAND "${SWIFT_EXECUTABLE}" build
        --package-path "${CMAKE_SOURCE_DIR}"
        --configuration "${CACOPHONY_SWIFT_CONFIGURATION}"
        --show-bin-path
    OUTPUT_VARIABLE CACOPHONY_SWIFT_BIN_DIR
    OUTPUT_STRIP_TRAILING_WHITESPACE
    RESULT_VARIABLE CACOPHONY_SWIFT_BIN_RESULT
)
if(NOT CACOPHONY_SWIFT_BIN_RESULT EQUAL 0)
    message(FATAL_ERROR "Could not determine the Swift build output directory")
endif()

file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/generated")
configure_file(
    "${CMAKE_SOURCE_DIR}/App/Info.plist.in"
    "${CMAKE_BINARY_DIR}/generated/Info.plist"
    @ONLY
)

add_subdirectory(Driver driver)

set(CACOPHONY_APP "${CMAKE_BINARY_DIR}/Cacophony.app")
add_custom_target(app
    COMMAND "${SWIFT_EXECUTABLE}" build
        --package-path "${CMAKE_SOURCE_DIR}"
        --configuration "${CACOPHONY_SWIFT_CONFIGURATION}"
    COMMAND "${CMAKE_COMMAND}" -E rm -rf "${CACOPHONY_APP}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory
        "${CACOPHONY_APP}/Contents/MacOS"
        "${CACOPHONY_APP}/Contents/Resources"
    COMMAND "${CMAKE_COMMAND}" -E copy
        "${CACOPHONY_SWIFT_BIN_DIR}/cacophony"
        "${CACOPHONY_APP}/Contents/MacOS/Cacophony"
    COMMAND "${CMAKE_COMMAND}" -E copy
        "${CMAKE_SOURCE_DIR}/Resources/Cacophony.icns"
        "${CACOPHONY_APP}/Contents/Resources/Cacophony.icns"
    COMMAND "${CMAKE_COMMAND}" -E copy
        "${CMAKE_SOURCE_DIR}/Resources/Assets.car"
        "${CACOPHONY_APP}/Contents/Resources/Assets.car"
    COMMAND "${CMAKE_COMMAND}" -E copy
        "${CMAKE_BINARY_DIR}/generated/Info.plist"
        "${CACOPHONY_APP}/Contents/Info.plist"
    COMMAND "${CMAKE_COMMAND}" -E copy_directory
        "$<TARGET_BUNDLE_DIR:CacophonyDriver>"
        "${CACOPHONY_APP}/Contents/Resources/CacophonyDriver.driver"
    COMMAND "${CODESIGN_EXECUTABLE}" --force --sign "${CODESIGN_ID}"
        "${CACOPHONY_APP}/Contents/Resources/CacophonyDriver.driver"
    COMMAND "${CODESIGN_EXECUTABLE}" --force --sign "${CODESIGN_ID}"
        "${CACOPHONY_APP}"
    DEPENDS CacophonyDriver icon
    COMMENT "Building Cacophony.app"
    VERBATIM
    USES_TERMINAL
)

add_custom_target(install-driver
    COMMAND "${CMAKE_COMMAND}" --install "${CMAKE_BINARY_DIR}" --component driver
    COMMENT "Installing the HAL driver; run this target with sudo"
    USES_TERMINAL
)

add_custom_target(uninstall-driver
    COMMAND "${CMAKE_COMMAND}" -E rm -rf
        "/Library/Audio/Plug-Ins/HAL/CacophonyDriver.driver"
    COMMAND /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod
    COMMENT "Removing the HAL driver; run this target with sudo"
    USES_TERMINAL
)

add_custom_target(icon
    COMMAND "${CMAKE_COMMAND}" -E rm -rf
        "${CMAKE_BINARY_DIR}/Cacophony.iconset"
        "${CMAKE_BINARY_DIR}/Cacophony.icon"
        "${CMAKE_BINARY_DIR}/icon-assets"
    COMMAND "${CMAKE_COMMAND}" -E make_directory
        "${CMAKE_BINARY_DIR}/Cacophony.iconset"
        "${CMAKE_BINARY_DIR}/Cacophony.icon"
        "${CMAKE_BINARY_DIR}/icon-assets"
    COMMAND "${SWIFT_EXECUTABLE}"
        "${CMAKE_SOURCE_DIR}/Scripts/make-icon.swift"
        "${CMAKE_BINARY_DIR}/Cacophony.iconset"
        "${CMAKE_BINARY_DIR}/Cacophony.icon"
    COMMAND /usr/bin/iconutil -c icns
        "${CMAKE_BINARY_DIR}/Cacophony.iconset"
        -o "${CMAKE_SOURCE_DIR}/Resources/Cacophony.icns"
    COMMAND "${ACTOOL_EXECUTABLE}"
        "${CMAKE_BINARY_DIR}/Cacophony.icon"
        --compile "${CMAKE_BINARY_DIR}/icon-assets"
        --output-format human-readable-text
        --notices
        --warnings
        --errors
        --output-partial-info-plist
        "${CMAKE_BINARY_DIR}/icon-assets/assetcatalog_generated_info.plist"
        --app-icon Cacophony
        --include-all-app-icons
        --enable-on-demand-resources NO
        --development-region en
        --target-device mac
        --minimum-deployment-target "${CMAKE_OSX_DEPLOYMENT_TARGET}"
        --platform macosx
    COMMAND "${CMAKE_COMMAND}" -E copy
        "${CMAKE_BINARY_DIR}/icon-assets/Assets.car"
        "${CMAKE_SOURCE_DIR}/Resources/Assets.car"
    COMMENT "Generating Resources/Cacophony.icns and Resources/Assets.car"
    VERBATIM
    USES_TERMINAL
)

install(TARGETS CacophonyDriver
    BUNDLE DESTINATION "/Library/Audio/Plug-Ins/HAL"
    LIBRARY DESTINATION "/Library/Audio/Plug-Ins/HAL"
    COMPONENT driver
)

install(CODE [[
    execute_process(
        COMMAND /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod
        RESULT_VARIABLE CACOPHONY_LAUNCHCTL_RESULT
    )
    if(NOT CACOPHONY_LAUNCHCTL_RESULT EQUAL 0)
        execute_process(COMMAND /usr/bin/killall -9 coreaudiod)
    endif()
]] COMPONENT driver)
