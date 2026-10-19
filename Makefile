# Shortcuts for building, running and testing CDRip.
#
#   make test
#   make run
#
# The app is built with xcodebuild into Xcode's DerivedData, so builds from
# Xcode and from here share the same incremental state. The engine is a Swift
# package in CDRipKit/ and builds with SwiftPM.

PROJECT = CDRip.xcodeproj
SCHEME = CDRip
PACKAGE = CDRipKit
CONFIG ?= Debug
ARGS ?=

# Debug builds only this Mac's architecture. A Release build goes to a generic
# Mac, so it holds every architecture in ARCHS (Apple silicon and Intel).
ARCH := $(shell uname -m)
comma := ,
DESTINATION = $(if $(filter Release,$(CONFIG)),generic/platform=macOS,platform=macOS$(comma)arch=$(ARCH))
XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -destination '$(DESTINATION)'

SWIFT_SOURCES = $(PACKAGE)/Package.swift $(PACKAGE)/Sources $(PACKAGE)/Tests CDRip

.PHONY: help build run app test core format lint

help:
	@echo "make build          build the app ($(CONFIG)) with xcodebuild"
	@echo "make run            build, then start the app in the foreground; ARGS='...' passes launch arguments"
	@echo "make app            print the path of the built app"
	@echo "make test           run the engine tests (swift test)"
	@echo "make core           build the engine package only (swift build)"
	@echo "make format         reformat the Swift sources with swift-format (settings in .swift-format)"
	@echo "make lint           report formatting problems without changing files"
	@echo "Set CONFIG=Release for a release build (Apple silicon and Intel)."

build:
	$(XCODEBUILD) -quiet build

run: build
	@app="$$($(XCODEBUILD) -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR =/ {dir=$$2} /^ *EXECUTABLE_PATH =/ {exe=$$2} END {print dir "/" exe}')"; \
	echo "Starting $$app $(ARGS)"; \
	"$$app" $(ARGS)

app:
	@$(XCODEBUILD) -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR =/ {dir=$$2} /^ *FULL_PRODUCT_NAME =/ {name=$$2} END {print dir "/" name}'

test:
	swift test --package-path $(PACKAGE)

core:
	swift build --package-path $(PACKAGE)

# .swift-format at the repo root holds the settings (4-space indent, 120 columns).
format:
	xcrun swift-format format --in-place --recursive $(SWIFT_SOURCES)

lint:
	xcrun swift-format lint --strict --recursive $(SWIFT_SOURCES)
