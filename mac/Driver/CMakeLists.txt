cmake_minimum_required(VERSION 3.25)
project(CodexMic LANGUAGES CXX)

include(CTest)

option(CODEX_MIC_COMPAT_USB_TRANSPORT
       "Report the wireless-backed input as USB for strict microphone pickers"
       ON)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(CodexMic MODULE Sources/CodexMicDriver.cpp)
if(CODEX_MIC_COMPAT_USB_TRANSPORT)
    target_compile_definitions(CodexMic PRIVATE CODEX_MIC_COMPAT_USB_TRANSPORT=1)
endif()
target_compile_options(CodexMic PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
target_link_libraries(CodexMic PRIVATE
    "-framework CoreAudio"
    "-framework CoreFoundation"
)
set_target_properties(CodexMic PROPERTIES
    PREFIX ""
    OUTPUT_NAME "CodexMic"
    BUNDLE TRUE
    BUNDLE_EXTENSION "driver"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Resources/Info.plist"
)

if(BUILD_TESTING)
    add_executable(test_ring_buffer Tests/test_ring_buffer.cpp)
    target_include_directories(test_ring_buffer PRIVATE Sources)
    target_compile_options(test_ring_buffer PRIVATE -Wall -Wextra -Werror)
    add_test(NAME ring_buffer COMMAND test_ring_buffer)

    add_executable(test_unix_audio_server Tests/test_unix_audio_server.cpp)
    target_include_directories(test_unix_audio_server PRIVATE Sources)
    target_compile_options(test_unix_audio_server PRIVATE -Wall -Wextra -Werror)
    add_test(NAME unix_audio_server COMMAND test_unix_audio_server)
endif()
