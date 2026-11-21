# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright © 2026 Jean-Christophe Baptiste
#
# Studio EQ — build, test, install and release. `make help` lists the targets.
# Written for the GNU Make 3.81 that ships with macOS (no .ONESHELL: one shell per line).

SHELL := /bin/bash
.DEFAULT_GOAL := build

PROJECT    := StudioEQ.xcodeproj
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme StudioEQ
DERIVED    := build/DerivedData
APP        := $(DERIVED)/Build/Products/Release/StudioEQ.app
VDERIVED   := build/Validation
VAPP       := $(VDERIVED)/Build/Products/Release/StudioEQ.app
INSTALLED  := /Applications/StudioEQ.app
AUDIOCTL   := build/audioctl

# Release parameters. VERSION defaults to MARKETING_VERSION in project.yml, TEAM_ID to the one
# in Config/Local.xcconfig; both can be given on the command line (make release VERSION=1.2.0).
VERSION      ?= $(shell sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
BUILD_NUMBER ?= 1
TEAM_ID      ?= $(shell sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig 2>/dev/null)
DEVICE       ?=

.PHONY: help project build test install validation selftest scenario dmg release clean

help: ## List the targets
	@awk -F ':.*## ' '/^[a-z-]+:.*## / { printf "  make %-12s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

project: ## Generate StudioEQ.xcodeproj from project.yml (XcodeGen)
	@command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
	@xcodegen generate --quiet

build: project ## Release build (signed per Config/Signing.xcconfig)
	@mkdir -p build && rm -rf $(APP)
	@echo "Building Release…"
	@$(XCODEBUILD) -configuration Release -derivedDataPath $(DERIVED) build > build/build.log 2>&1 \
	  || { grep -E "error:" build/build.log | sort -u >&2; echo "Build failed (log: build/build.log)" >&2; exit 1; }
	@codesign --verify --strict $(APP)
	@echo "Built $(APP)"

test: project ## Unit tests
	@mkdir -p build
	@echo "Running unit tests…"
	@$(XCODEBUILD) -derivedDataPath $(DERIVED) test > build/test.log 2>&1 \
	  || { grep -E "error:|failed \(" build/test.log | sort -u >&2; echo "Tests failed (log: build/test.log)" >&2; exit 1; }
	@grep -E "Executed [0-9]+ tests" build/test.log | tail -1 | sed 's/^[[:space:]]*/Tests: /'

install: build ## Build, then replace /Applications/StudioEQ.app and launch it
	@mkdir -p dist && rm -rf dist/StudioEQ.app && cp -R $(APP) dist/
	@osascript -e 'tell application id "com.jcbaptiste.StudioEQ" to quit' >/dev/null 2>&1 || true
	@pkill -x StudioEQ 2>/dev/null || true
	@rm -rf $(INSTALLED) && cp -R $(APP) $(INSTALLED)
	@open $(INSTALLED)
	@echo "Installed $(INSTALLED)"

validation: project ## Optimized build with the validation tools (self-test, A/B, overrides)
	@mkdir -p build
	@echo "Building validation app…"
	@$(XCODEBUILD) -configuration Release -derivedDataPath $(VDERIVED) \
	  SWIFT_ACTIVE_COMPILATION_CONDITIONS=VALIDATION build > build/validation.log 2>&1 \
	  || { grep -E "error:" build/validation.log | sort -u >&2; echo "Build failed (log: build/validation.log)" >&2; exit 1; }
	@echo "Built $(VAPP)"

$(AUDIOCTL): scripts/audioctl.swift
	@mkdir -p build
	@swiftc -O $< -o $@

selftest: validation ## End-to-end test on the Studio Display (DEVICE=<uid> for another output); plays test tones
	@pkill -x StudioEQ 2>/dev/null; sleep 1; true
	@open -W -n --stdout $(CURDIR)/build/selftest.txt $(VAPP) --args --selftest $(if $(DEVICE),--device "$(DEVICE)"); \
	  cat build/selftest.txt; \
	  if [ -d $(INSTALLED) ]; then open $(INSTALLED); fi; \
	  grep -q "RESULT: PASS" build/selftest.txt

scenario: validation $(AUDIOCTL) ## Automated output-switching scenarios (moves the system output for ~45 s)
	@$(AUDIOCTL) tone build/scenario-tone.wav 90 >/dev/null
	@zsh scripts/scenario.sh "$(CURDIR)/$(VAPP)" "$(CURDIR)/build/scenario-tone.wav" | tee build/scenario.txt
	@if [ -d $(INSTALLED) ]; then open $(INSTALLED); fi
	@! grep -q "FAIL" build/scenario.txt

dmg: ## Signed Developer ID DMG, checked but NOT notarized (local trial)
	@VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" TEAM_ID="$(TEAM_ID)" SKIP_NOTARIZATION=1 zsh scripts/release.sh

release: ## Signed, checked, notarized and stapled DMG (VERSION=x.y.z; credentials: docs/RELEASE.md)
	@VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" TEAM_ID="$(TEAM_ID)" zsh scripts/release.sh

clean: ## Remove build products (build/, dist/, generated project)
	@rm -rf build dist $(PROJECT)
