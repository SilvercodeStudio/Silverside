# Shortcuts for building, running and testing Silverside.
#
#   make test
#   make run
#
# The app is built with xcodebuild from Silverside.xcworkspace, the workspace to open
# in Xcode, into Xcode's DerivedData, so builds from Xcode and from here share the
# same incremental state. The engine is a Swift package in SilversideKit/ and builds
# with SwiftPM.

WORKSPACE = Silverside.xcworkspace
SCHEME = Silverside
PACKAGE = SilversideKit
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

SWIFT_SOURCES = $(PACKAGE)/Package.swift $(PACKAGE)/Sources $(PACKAGE)/Tests App/Silverside

# The Git commit of the build ("-dirty" with changes not committed), linked into the CLI as its
# Info.plist, where SilversideVersion.commit reads it. The file is named after the commit, so a
# new commit changes the linker's arguments, and SwiftPM links again.
COMMIT := $(shell scripts/commit-id.sh)
COMMIT_PLIST = $(PACKAGE)/.build/commit/Info-$(COMMIT).plist
COMMIT_FLAGS = $(if $(COMMIT),-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(abspath $(COMMIT_PLIST)))

.PHONY: help build run app cli test hwtest core format lint release commit-plist install install-cli-local install-app open-app dist uninstall site rip-art

# Where make install puts silverside and its shell completions. /usr/local may need sudo; PREFIX=~/.local does not.
PREFIX ?= /usr/local
# A ~ that the shell did not expand (zsh leaves the one in PREFIX=~/.local) means the home folder.
override PREFIX := $(patsubst ~%,$(HOME)%,$(PREFIX))
RELEASE_BIN = $(PACKAGE)/.build/out/Products/Release/silverside
# Where make install-app puts the app.
APP_DIR ?= $(HOME)/Applications
# Registers a copied app with Launch Services, so that the Dock and Finder show its new icon.
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

help:
	@echo "make build          build the app ($(CONFIG)) with xcodebuild"
	@echo "make run            build, then start the app in the foreground; ARGS='...' passes launch arguments"
	@echo "make app            print the path of the built app"
	@echo "make cli            build and run the silverside CLI; ARGS='info -d disk14' passes arguments"
	@echo "make test           run the engine tests (swift test)"
	@echo "make hwtest         run the tests that need a drive and an AccurateRip disc (DEVICE=diskN, OFFSET=n to check the drive's offset)"
	@echo "make core           build the engine package only (swift build)"
	@echo "make format         reformat the Swift sources with swift-format (settings in .swift-format)"
	@echo "make lint           report formatting problems without changing files"
	@echo "make release        build silverside for release, for Apple silicon and Intel"
	@echo "make install        install silverside and its zsh, bash, and fish completions under PREFIX ($(PREFIX))"
	@echo "make install-cli-local  the same, under ~/.local (no sudo)"
	@echo "make install-app    build the app for release (Apple silicon and Intel) and copy it to APP_DIR ($(APP_DIR))"
	@echo "make open-app       make install-app, open the app, and install the CLI under ~/.local"
	@echo "make dist           the app for others: Developer ID, notarized, stapled, zipped in build/dist (NOTARIZE=0 stops before Apple)"
	@echo "make uninstall      remove what make install put under PREFIX"
	@echo "make site           serve the website (docs/site) at http://localhost:8000"
	@echo "make rip-art        render the Rip button's pictures from SilversideRipIcon.icon (after the icon changes)"
	@echo "Set CONFIG=Release for a release build (Apple silicon and Intel)."

build:
	$(XCODEBUILD) -quiet build

run: build
	@app="$$($(XCODEBUILD) -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR =/ {dir=$$2} /^ *EXECUTABLE_PATH =/ {exe=$$2} END {print dir "/" exe}')"; \
	echo "Starting $$app $(ARGS)"; \
	"$$app" $(ARGS)

app:
	@$(XCODEBUILD) -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR =/ {dir=$$2} /^ *FULL_PRODUCT_NAME =/ {name=$$2} END {print dir "/" name}'

cli: commit-plist
	@swift build --package-path $(PACKAGE) --product silverside-dvd-helper -q
	@swift build --package-path $(PACKAGE) --product silverside -q $(COMMIT_FLAGS)
	@"$$(swift build --package-path $(PACKAGE) --show-bin-path)/silverside" $(ARGS)

test:
	swift test --package-path $(PACKAGE)

hwtest:
	@[ -n "$(DEVICE)" ] || { echo "No disc found. Insert one, or set DEVICE=diskN."; exit 1; }
	SILVERSIDE_TEST_DEVICE=$(DEVICE) SILVERSIDE_TEST_OFFSET=$(OFFSET) swift test --package-path $(PACKAGE) --filter HardwareTests

core:
	swift build --package-path $(PACKAGE)

# .swift-format at the repo root holds the settings (4-space indent, 120 columns).
format:
	xcrun swift-format format --in-place --recursive $(SWIFT_SOURCES)

lint:
	xcrun swift-format lint --strict --recursive $(SWIFT_SOURCES)

release: commit-plist
	swift build --package-path $(PACKAGE) -c release --arch arm64 --arch x86_64 --product silverside-dvd-helper
	swift build --package-path $(PACKAGE) -c release --arch arm64 --arch x86_64 --product silverside $(COMMIT_FLAGS)

commit-plist:
	@mkdir -p "$(dir $(COMMIT_PLIST))"
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict><key>SilversideCommit</key><string>$(COMMIT)</string></dict></plist>' \
		> "$(COMMIT_PLIST)"

install: release
	install -d "$(PREFIX)/bin" "$(PREFIX)/share/zsh/site-functions" "$(PREFIX)/etc/bash_completion.d" \
		"$(PREFIX)/share/fish/vendor_completions.d"
	install -m 755 "$(RELEASE_BIN)" "$(PREFIX)/bin/silverside"
	install -m 755 "$(dir $(RELEASE_BIN))silverside-dvd-helper" "$(PREFIX)/bin/silverside-dvd-helper"
	"$(RELEASE_BIN)" --generate-completion-script zsh > "$(PREFIX)/share/zsh/site-functions/_silverside"
	"$(RELEASE_BIN)" --generate-completion-script bash > "$(PREFIX)/etc/bash_completion.d/silverside"
	"$(RELEASE_BIN)" --generate-completion-script fish > "$(PREFIX)/share/fish/vendor_completions.d/silverside.fish"
	@echo "Installed $(PREFIX)/bin/silverside $$("$(PREFIX)/bin/silverside" --version), and its shell completions."

install-cli-local:
	@$(MAKE) install PREFIX=$(HOME)/.local

# A universal release build of the app, copied whole; an older copy is replaced.
install-app:
	@$(MAKE) build CONFIG=Release
	@app="$$($(MAKE) app CONFIG=Release)"; \
	install -d "$(APP_DIR)"; \
	rm -rf "$(APP_DIR)/$$(basename "$$app")"; \
	ditto "$$app" "$(APP_DIR)/$$(basename "$$app")"; \
	touch "$(APP_DIR)/$$(basename "$$app")"; \
	$(LSREGISTER) -f "$(APP_DIR)/$$(basename "$$app")"; \
	echo "Installed $(APP_DIR)/$$(basename "$$app")"

# install-app, then open the app. The CLI builds and installs under ~/.local at the same time;
# its output goes to SilversideKit/.build/open-app-cli.log.
open-app:
		@if pgrep -f "$(APP_DIR)/Silverside.app/Contents/MacOS/Silverside" >/dev/null; then \
				echo "Quit Silverside first: install-app replaces it."; exit 1; fi
		@mkdir -p "$(PACKAGE)/.build"
		@( $(MAKE) install-cli-local > "$(PACKAGE)/.build/open-app-cli.log" 2>&1 \
				|| echo "The CLI did not install: see $(PACKAGE)/.build/open-app-cli.log" ) &
		@$(MAKE) install-app && open "$(APP_DIR)/Silverside.app"

# The app as others get it: archived, exported with Developer ID, notarized, stapled, and zipped
# in build/dist. See scripts/dist.sh for NOTARY_PROFILE, NOTARIZE=0, and ALLOW_DIRTY=1.
dist:
	@scripts/dist.sh

uninstall:
	rm -f "$(PREFIX)/bin/silverside" "$(PREFIX)/bin/silverside-dvd-helper" "$(PREFIX)/share/zsh/site-functions/_silverside" "$(PREFIX)/etc/bash_completion.d/silverside" \
		"$(PREFIX)/share/fish/vendor_completions.d/silverside.fish"

# The website, as GitHub Pages serves it.
site:
	python3 -m http.server 8000 --bind 127.0.0.1 --directory docs/site

# Xcode does not build SilversideRipIcon.icon; this renders it with Icon Composer into the asset catalog.
rip-art:
	swift App/Icon/make_rip_art.swift
