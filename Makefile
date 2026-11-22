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
# in Config/Local.xcconfig, BUILD_NUMBER to the commit count (always increasing); all can be given
# on the command line (make publish VERSION=1.2.0). NOTARY_PROFILE names the notarization
# credentials stored in the login keychain by `xcrun notarytool store-credentials` (docs/RELEASE.md).
VERSION        ?= $(shell sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
BUILD_NUMBER   ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
TEAM_ID        ?= $(shell sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Local.xcconfig 2>/dev/null)
NOTARY_PROFILE ?= studio-eq
DEVICE         ?=
TAG            := v$(VERSION)
DMG            := build/release/StudioEQ-$(VERSION).dmg

.PHONY: help project build test install validation selftest scenario dmg release publish clean

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

release: ## Signed, checked, notarized and stapled DMG, not published (credentials: docs/RELEASE.md)
	@VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" TEAM_ID="$(TEAM_ID)" \
	  NOTARY_PROFILE="$(NOTARY_PROFILE)" zsh scripts/release.sh

# The DMG is built on this Mac: the Developer ID private key never leaves its keychain. The source
# must be committed and pushed first, so the published binary matches the published source (GPL).
# The tag is pushed only once the DMG is notarized: a failed run leaves nothing on GitHub.
publish: ## Test, release, then tag vX.Y.Z and upload the DMG as a GitHub release
	@test -z "$$(git status --porcelain)" || { echo "publish: commit your changes first" >&2; exit 1; }
	@git fetch --quiet origin && test "$$(git rev-parse HEAD)" = "$$(git rev-parse @{u})" \
	  || { echo "publish: push the branch first, the release must match the published source" >&2; exit 1; }
	@! git ls-remote --exit-code --tags origin "refs/tags/$(TAG)" >/dev/null \
	  || { echo "publish: $(TAG) already exists on GitHub (bump MARKETING_VERSION in project.yml)" >&2; exit 1; }
	@$(MAKE) --no-print-directory test
	@$(MAKE) --no-print-directory release
	@git tag -a $(TAG) -m "Studio EQ $(VERSION)" && git push --quiet origin $(TAG)
	@gh release create $(TAG) $(DMG) $(DMG).sha256 --verify-tag --title "Studio EQ $(VERSION)" --generate-notes
	@echo "Published $$(gh release view $(TAG) --json url -q .url)"

clean: ## Remove build products (build/, dist/, generated project)
	@rm -rf build dist $(PROJECT)
