# Thin CMake wrapper for editor task runners.

BUILD_DIR ?= build
SWIFT_BUILD_DIR ?= .build
BUILD_TYPE ?= Release
CODESIGN_ID ?= -
NOTARY_PROFILE ?=

-include Makefile.local

CMAKE ?= cmake
CONFIGURE_ARGS = -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) -DCODESIGN_ID="$(CODESIGN_ID)"
ifneq ($(strip $(NOTARY_PROFILE)),)
CONFIGURE_ARGS += -DNOTARY_PROFILE="$(NOTARY_PROFILE)"
endif

.PHONY: help configure app driver icon notarize run clean distclean

help:
	@printf '%s\n' \
		'make configure   Configure the CMake build' \
		'make app         Build and sign Cacophony.app' \
		'make driver      Build the CoreAudio driver' \
		'make icon        Regenerate app icons' \
		'make notarize    Build, sign, notarize, and staple' \
		'make run         Open the built app' \
		'make clean       Remove the CMake build directory' \
		'make distclean   Remove CMake and SwiftPM build artifacts'

$(BUILD_DIR)/CMakeCache.txt:
	$(CMAKE) -S . -B "$(BUILD_DIR)" $(CONFIGURE_ARGS)

configure:
	$(CMAKE) -S . -B "$(BUILD_DIR)" $(CONFIGURE_ARGS)

app: $(BUILD_DIR)/CMakeCache.txt
	$(CMAKE) --build "$(BUILD_DIR)" --target app

driver: $(BUILD_DIR)/CMakeCache.txt
	$(CMAKE) --build "$(BUILD_DIR)" --target CacophonyAudio

icon: $(BUILD_DIR)/CMakeCache.txt
	$(CMAKE) --build "$(BUILD_DIR)" --target icon

notarize:
	@test -n "$(NOTARY_PROFILE)" || { echo "Set NOTARY_PROFILE=<keychain-profile>"; exit 1; }
	@test "$(CODESIGN_ID)" != "-" || { echo "Set CODESIGN_ID=<Developer ID Application>"; exit 1; }
	$(CMAKE) -S . -B "$(BUILD_DIR)" $(CONFIGURE_ARGS)
	$(CMAKE) --build "$(BUILD_DIR)" --target notarize

run: app
	open "$(BUILD_DIR)/Cacophony.app"

clean:
	rm -rf "$(BUILD_DIR)"

distclean:
	rm -rf "$(BUILD_DIR)" "$(SWIFT_BUILD_DIR)"
