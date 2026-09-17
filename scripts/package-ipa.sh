#!/usr/bin/env bash
set -euo pipefail
# Run at repository root on macOS after xcodebuild. No Apple login or private signing key used.
APP_PATH="build/Build/Products/Release-iphoneos/AIBudget.app"
EXTENSION_PATH="$APP_PATH/PlugIns/BudgetWidget.appex"
test -d "$APP_PATH"
test -d "$EXTENSION_PATH"
test -f ios/Generated/App.entitlements
test -f ios/Generated/Widget.entitlements
# Embed ad-hoc signatures so the installer can read the requested entitlements.
# iloader/SideStore subsequently replaces these with the user's provisioned signatures.
codesign --force --sign - --entitlements ios/Generated/Widget.entitlements "$EXTENSION_PATH"
codesign --force --sign - --entitlements ios/Generated/App.entitlements "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
mkdir -p output
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/ai-budget-ipa.XXXXXX")
mkdir -p "$STAGING/Payload"
ditto "$APP_PATH" "$STAGING/Payload/AIBudget.app"
ditto -c -k --keepParent "$STAGING/Payload" output/AIBudget.ipa
# Leave the staging folder to the runner's ephemeral cleanup rather than recursively deleting paths.
unzip -l output/AIBudget.ipa
