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

.PHONY: help build run app cli test hwtest core format lint release commit-plist install-cli-local install-app open-app dist uninstall-cli-local site rip-art

# Never as root: a build with sudo leaves files in .build that only root can replace, and every
# build after it fails to link. /usr/local gets the command from the app's Install Command Line Tool.
ifeq ($(shell id -u),0)
$(error Do not run make as root (sudo): it leaves build files that only root can replace. Run it as yourself; make install-cli-local needs no sudo, and the app's Install Command Line Tool... puts the command in /usr/local)
endif

# Where make install-cli-local puts silverside and its shell completions.
CLI_PREFIX = $(HOME)/.local
RELEASE_BIN = $(PACKAGE)/.build/out/Products/Release/silverside
# Where make install-app puts the app. A leading ~ becomes the home folder: zsh leaves it
# alone in APP_DIR=~/..., and make once made a folder named ~ in the repository.
APP_DIR ?= $(HOME)/Applications
override APP_DIR := $(patsubst ~%,$(HOME)%,$(APP_DIR))
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
	@echo "make lint           report formatting problems, trailing whitespace, and versions that differ, without changing files"
	@echo "make release        build silverside for release, for Apple silicon and Intel"
	@echo "make install-cli-local  install silverside and its zsh, bash, and fish completions under ~/.local"
	@echo "make install-app    build the app for release (Apple silicon and Intel) and copy it to APP_DIR ($(APP_DIR))"
	@echo "make open-app       make install-app, open the app, and install the CLI under ~/.local"
	@echo "make dist           the app for others: Developer ID, notarized, stapled, in a disk image in build/dist (NOTARIZE=0 stops before Apple)"
	@echo "make uninstall-cli-local  remove what make install-cli-local put under ~/.local"
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

# Text files with spaces or tabs at the ends of lines; .editorconfig has editors trim them. License
# texts, vendored code, and drawings stay as their authors and tools wrote them.
WHITESPACE_EXCEPTIONS = ':!LICENSE' ':!NOTICE' ':!*.svg' ':!App/Silverside/Licenses' ':!SilversideKit/Vendor'

lint:
	xcrun swift-format lint --strict --recursive $(SWIFT_SOURCES)
	@if git grep -nI -E '[[:blank:]]+$$' -- . $(WHITESPACE_EXCEPTIONS); then \
		echo "Spaces or tabs at the end of the lines above: remove them."; exit 1; fi
	@scripts/version.sh check

release: commit-plist
	swift build --package-path $(PACKAGE) -c release --arch arm64 --arch x86_64 --product silverside $(COMMIT_FLAGS)

commit-plist:
	@mkdir -p "$(dir $(COMMIT_PLIST))"
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict><key>SilversideCommit</key><string>$(COMMIT)</string></dict></plist>' \
		> "$(COMMIT_PLIST)"

install-cli-local: release
	install -d "$(CLI_PREFIX)/bin" "$(CLI_PREFIX)/share/zsh/site-functions" "$(CLI_PREFIX)/etc/bash_completion.d" \
		"$(CLI_PREFIX)/share/fish/vendor_completions.d"
	install -m 755 "$(RELEASE_BIN)" "$(CLI_PREFIX)/bin/silverside"
	"$(RELEASE_BIN)" --generate-completion-script zsh > "$(CLI_PREFIX)/share/zsh/site-functions/_silverside"
	"$(RELEASE_BIN)" --generate-completion-script bash > "$(CLI_PREFIX)/etc/bash_completion.d/silverside"
	"$(RELEASE_BIN)" --generate-completion-script fish > "$(CLI_PREFIX)/share/fish/vendor_completions.d/silverside.fish"
	@echo "Installed $(CLI_PREFIX)/bin/silverside $$("$(CLI_PREFIX)/bin/silverside" --version), and its shell completions."

# A universal release build of the app, copied whole; an older copy is replaced. The path is
# checked before anything is removed: make -n still runs a line with $(MAKE) in it, and then
# the path is the printed command, and an empty answer from xcodebuild gives "/", which would
# remove the whole of APP_DIR.
install-app:
	@$(MAKE) build CONFIG=Release
	@set -e; app="$$($(MAKE) -s app CONFIG=Release)"; \
	case "$$app" in *.app) ;; *) echo "install-app: not an app path: '$$app'" >&2; exit 1 ;; esac; \
	if [ ! -d "$$app" ]; then echo "install-app: no app at $$app" >&2; exit 1; fi; \
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

# The app as others get it: archived, exported with Developer ID, notarized, stapled, and put in a
# signed, notarized disk image in build/dist, and added to the update feed (docs/site/appcast.xml). See scripts/dist.sh for
# NOTARY_PROFILE, NOTARIZE=0, FEED=0, and ALLOW_DIRTY=1, and docs/internal/Releasing.md.
dist:
	@scripts/dist.sh

uninstall-cli-local:
	rm -f "$(CLI_PREFIX)/bin/silverside" "$(CLI_PREFIX)/share/zsh/site-functions/_silverside" \
		"$(CLI_PREFIX)/etc/bash_completion.d/silverside" "$(CLI_PREFIX)/share/fish/vendor_completions.d/silverside.fish"

# The website, as GitHub Pages serves it.
site:
	python3 -m http.server 8000 --bind 127.0.0.1 --directory docs/site

# Xcode does not build SilversideRipIcon.icon; this renders it with Icon Composer into the asset catalog.
rip-art:
	swift App/Icon/make_rip_art.swift
