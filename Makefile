# Shortcuts for building, running and testing CDRip.
#
#   make test
#   make run
#
# The app is built with xcodebuild from CDRip.xcworkspace, the workspace to open
# in Xcode, into Xcode's DerivedData, so builds from Xcode and from here share the
# same incremental state. The engine is a Swift package in CDRipKit/ and builds
# with SwiftPM.

WORKSPACE = CDRip.xcworkspace
SCHEME = CDRip
PACKAGE = CDRipKit
CONFIG ?= Debug
ARGS ?=
# The disc for hardware tests; the first disc that drutil reports, unless set.
DEVICE ?= $(shell drutil status 2>/dev/null | sed -n 's|.*Name: /dev/||p' | head -1)
# The drive's known read offset for hardware tests. If empty, the tests only list matching offsets.
OFFSET ?=

# Debug builds only this Mac's architecture. A Release build goes to a generic
# Mac, so it holds every architecture in ARCHS (Apple silicon and Intel).
ARCH := $(shell uname -m)
comma := ,
DESTINATION = $(if $(filter Release,$(CONFIG)),generic/platform=macOS,platform=macOS$(comma)arch=$(ARCH))
XCODEBUILD = xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)'

SWIFT_SOURCES = $(PACKAGE)/Package.swift $(PACKAGE)/Sources $(PACKAGE)/Tests App/CDRip

.PHONY: help build run app cli test hwtest core format lint release install install-cli-local install-app uninstall

# Where make install puts cdrip and its shell completions. /usr/local may need sudo; PREFIX=~/.local does not.
PREFIX ?= /usr/local
# A ~ that the shell did not expand (zsh leaves the one in PREFIX=~/.local) means the home folder.
override PREFIX := $(patsubst ~%,$(HOME)%,$(PREFIX))
RELEASE_BIN = $(PACKAGE)/.build/out/Products/Release/cdrip
# Where make install-app puts the app.
APP_DIR ?= $(HOME)/Applications

help:
	@echo "make build          build the app ($(CONFIG)) with xcodebuild"
	@echo "make run            build, then start the app in the foreground; ARGS='...' passes launch arguments"
	@echo "make app            print the path of the built app"
	@echo "make cli            build and run the cdrip CLI; ARGS='info -d disk14' passes arguments"
	@echo "make test           run the engine tests (swift test)"
	@echo "make hwtest         run the tests that need a drive and an AccurateRip disc (DEVICE=diskN, OFFSET=n to check the drive's offset)"
	@echo "make core           build the engine package only (swift build)"
	@echo "make format         reformat the Swift sources with swift-format (settings in .swift-format)"
	@echo "make lint           report formatting problems without changing files"
	@echo "make release        build cdrip for release, for Apple silicon and Intel"
	@echo "make install        install cdrip and its zsh, bash, and fish completions under PREFIX ($(PREFIX))"
	@echo "make install-cli-local  the same, under ~/.local (no sudo)"
	@echo "make install-app    build the app for release (Apple silicon and Intel) and copy it to APP_DIR ($(APP_DIR))"
	@echo "make uninstall      remove what make install put under PREFIX"
	@echo "Set CONFIG=Release for a release build (Apple silicon and Intel)."

build:
	$(XCODEBUILD) -quiet build

run: build
	@app="$$($(XCODEBUILD) -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR =/ {dir=$$2} /^ *EXECUTABLE_PATH =/ {exe=$$2} END {print dir "/" exe}')"; \
	echo "Starting $$app $(ARGS)"; \
	"$$app" $(ARGS)

app:
	@$(XCODEBUILD) -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR =/ {dir=$$2} /^ *FULL_PRODUCT_NAME =/ {name=$$2} END {print dir "/" name}'

cli:
	@swift build --package-path $(PACKAGE) --product cdrip -q
	@"$$(swift build --package-path $(PACKAGE) --show-bin-path)/cdrip" $(ARGS)

test:
	swift test --package-path $(PACKAGE)

hwtest:
	@[ -n "$(DEVICE)" ] || { echo "No disc found. Insert one, or set DEVICE=diskN."; exit 1; }
	CDRIP_TEST_DEVICE=$(DEVICE) CDRIP_TEST_OFFSET=$(OFFSET) swift test --package-path $(PACKAGE) --filter HardwareTests

core:
	swift build --package-path $(PACKAGE)

# .swift-format at the repo root holds the settings (4-space indent, 120 columns).
format:
	xcrun swift-format format --in-place --recursive $(SWIFT_SOURCES)

lint:
	xcrun swift-format lint --strict --recursive $(SWIFT_SOURCES)

release:
	swift build --package-path $(PACKAGE) -c release --arch arm64 --arch x86_64 --product cdrip

install: release
	install -d "$(PREFIX)/bin" "$(PREFIX)/share/zsh/site-functions" "$(PREFIX)/etc/bash_completion.d" \
		"$(PREFIX)/share/fish/vendor_completions.d"
	install -m 755 "$(RELEASE_BIN)" "$(PREFIX)/bin/cdrip"
	"$(RELEASE_BIN)" --generate-completion-script zsh > "$(PREFIX)/share/zsh/site-functions/_cdrip"
	"$(RELEASE_BIN)" --generate-completion-script bash > "$(PREFIX)/etc/bash_completion.d/cdrip"
	"$(RELEASE_BIN)" --generate-completion-script fish > "$(PREFIX)/share/fish/vendor_completions.d/cdrip.fish"
	@echo "Installed $(PREFIX)/bin/cdrip $$("$(PREFIX)/bin/cdrip" --version), and its shell completions."

install-cli-local:
	@$(MAKE) install PREFIX=$(HOME)/.local

# A universal release build of the app, copied whole; an older copy is replaced.
install-app:
	@$(MAKE) build CONFIG=Release
	@app="$$($(MAKE) app CONFIG=Release)"; \
	install -d "$(APP_DIR)"; \
	rm -rf "$(APP_DIR)/$$(basename "$$app")"; \
	ditto "$$app" "$(APP_DIR)/$$(basename "$$app")"; \
	echo "Installed $(APP_DIR)/$$(basename "$$app")"

uninstall:
	rm -f "$(PREFIX)/bin/cdrip" "$(PREFIX)/share/zsh/site-functions/_cdrip" "$(PREFIX)/etc/bash_completion.d/cdrip" \
		"$(PREFIX)/share/fish/vendor_completions.d/cdrip.fish"
