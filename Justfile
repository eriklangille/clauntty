# Clauntty justfile — `just -l` to list all recipes

# --- Defaults (override with env vars) ---------------------------------------
PROJECT       := "Clauntty.xcodeproj"
SCHEME        := "Clauntty"
SIM_DEVICE    := env("SIM_DEVICE", "iPhone 17")
CONFIGURATION := env("CONFIGURATION", "Debug")

# Release / archive
ARCHIVE_CONFIGURATION := env("ARCHIVE_CONFIGURATION", "Release")
ARCHIVE_PATH          := env("ARCHIVE_PATH", "build/Clauntty.xcarchive")
EXPORT_PATH           := env("EXPORT_PATH", "build/export")
EXPORT_OPTIONS_PLIST  := env("EXPORT_OPTIONS_PLIST", "ExportOptions.plist")
EXPORT_METHOD         := env("EXPORT_METHOD", "")

# Fork identity
BUNDLE_ID  := env("BUNDLE_ID", "com.octerm.clauntty")
TEAM_ID    := env("TEAM_ID", "65533RB4LC")
URL_SCHEME := env("URL_SCHEME", "clauntty")

# Sibling repos (as per repo layout in CLAUDE.md)
GHOSTTY_DIR := env("GHOSTTY_DIR", "../ghostty")
RTACH_DIR   := env("RTACH_DIR", "../rtach")
LIBXEV_DIR  := env("LIBXEV_DIR", "../libxev")

# Sibling repo git URLs and branches
GHOSTTY_REPO   := env("GHOSTTY_REPO", "https://github.com/eriklangille/ghostty.git")
GHOSTTY_BRANCH := env("GHOSTTY_BRANCH", "clauntty")
RTACH_REPO     := env("RTACH_REPO", "https://github.com/eriklangille/rtach.git")
LIBXEV_REPO    := env("LIBXEV_REPO", "https://github.com/eriklangille/libxev.git")

# --- Default ----------------------------------------------------------------

default:
  @just --list

# --- Setup ------------------------------------------------------------------

# Clone sibling repos (ghostty, rtach, libxev) if missing.
[group("setup")]
setup:
  #!/usr/bin/env bash
  set -euo pipefail
  clone_if_missing() {
    local dir="$1" repo="$2"
    if [ -d "$dir" ]; then
      echo "OK: $dir already exists"
    else
      echo "Cloning $repo -> $dir ..."
      git clone "$repo" "$dir"
      echo "OK: cloned $dir"
    fi
  }
  clone_if_missing "{{GHOSTTY_DIR}}" "{{GHOSTTY_REPO}}"
  clone_if_missing "{{RTACH_DIR}}"   "{{RTACH_REPO}}"
  clone_if_missing "{{LIBXEV_DIR}}"  "{{LIBXEV_REPO}}"

  # Ghostty needs the clauntty branch (has iOS-specific APIs)
  current="$(cd "{{GHOSTTY_DIR}}" && git rev-parse --abbrev-ref HEAD)"
  if [ "$current" != "{{GHOSTTY_BRANCH}}" ]; then
    echo "Switching ghostty to branch {{GHOSTTY_BRANCH}}..."
    (cd "{{GHOSTTY_DIR}}" && git checkout "{{GHOSTTY_BRANCH}}")
  fi

# --- Preflight checks -------------------------------------------------------

# Run all environment + layout checks.
[group("check")]
doctor: _check-macos _check-tools _check-xcode _check-metal _check-zig _check-layout

[private]
_check-macos:
  #!/usr/bin/env bash
  set -euo pipefail
  [ "$(uname -s)" = "Darwin" ] || { echo "ERROR: macOS required." >&2; exit 1; }
  echo "OK: macOS"

[private]
_check-tools:
  #!/usr/bin/env bash
  set -euo pipefail
  need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing: $1" >&2; exit 1; }; }
  need git; need xcodebuild; need xcrun; need swift; need plutil; need perl
  [ -x /usr/libexec/PlistBuddy ] || { echo "ERROR: missing PlistBuddy" >&2; exit 1; }
  echo "OK: tools"

[private]
_check-xcode:
  #!/usr/bin/env bash
  set -euo pipefail
  xcodebuild -version >/dev/null 2>&1 || { echo "ERROR: Xcode not found." >&2; exit 1; }
  xver="$(xcodebuild -version | head -1 | awk '{print $2}')"
  major="${xver%%.*}"
  [ -n "$major" ] && [ "$major" -ge 15 ] || { echo "ERROR: Xcode 15+ required (found ${xver})" >&2; exit 1; }
  echo "OK: Xcode ${xver}"

[private]
_check-metal:
  #!/usr/bin/env bash
  set -euo pipefail
  if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
    echo "OK: Metal Toolchain"
  else
    echo "Metal Toolchain missing, installing..."
    xcodebuild -downloadComponent MetalToolchain
    echo "OK: Metal Toolchain installed"
  fi

[private]
_check-zig:
  #!/usr/bin/env bash
  set -euo pipefail
  command -v zig >/dev/null 2>&1 || { echo "ERROR: zig not found." >&2; exit 1; }
  zv="$(zig version)"
  zmaj="${zv%%.*}"; _r="${zv#*.}"; zmin="${_r%%.*}"; zp="${_r#*.}"; zp="${zp%%[^0-9]*}"
  ok=0
  [ "$zmaj" -gt 0 ] && ok=1
  [ "$zmaj" -eq 0 ] && [ "$zmin" -gt 15 ] && ok=1
  [ "$zmaj" -eq 0 ] && [ "$zmin" -eq 15 ] && [ "${zp:-0}" -ge 2 ] && ok=1
  [ "$ok" -eq 1 ] || { echo "ERROR: Zig 0.15.2+ required (found ${zv})" >&2; exit 1; }
  echo "OK: Zig ${zv}"

[private]
_check-layout:
  #!/usr/bin/env bash
  set -euo pipefail
  [ -d "{{GHOSTTY_DIR}}" ] || { echo "ERROR: missing {{GHOSTTY_DIR}}" >&2; exit 1; }
  [ -d "{{RTACH_DIR}}" ]   || { echo "ERROR: missing {{RTACH_DIR}}" >&2; exit 1; }
  [ -d "{{LIBXEV_DIR}}" ]  || { echo "ERROR: missing {{LIBXEV_DIR}}" >&2; exit 1; }
  [ -d "{{GHOSTTY_DIR}}/../libxev" ] || { echo "ERROR: ghostty expects ../libxev" >&2; exit 1; }
  echo "OK: layout"

# --- Dependencies ------------------------------------------------------------

# Build GhosttyKit xcframework.
[group("deps")]
deps-ghostty:
  cd "{{GHOSTTY_DIR}}" && zig build -Demit-xcframework -Doptimize=ReleaseFast

# Build rtach cross-compiled binaries.
[group("deps")]
deps-rtach:
  cd "{{RTACH_DIR}}" && zig build cross

# Symlink GhosttyKit.xcframework into Frameworks/ if missing.
[group("deps")]
deps-link:
  #!/usr/bin/env bash
  set -euo pipefail
  dst="Frameworks/GhosttyKit.xcframework"
  rel="../../$(basename "{{GHOSTTY_DIR}}")/macos/GhosttyKit.xcframework"
  if [ -e "$dst" ]; then echo "OK: $dst exists"; exit 0; fi
  abs="$(cd "{{GHOSTTY_DIR}}/macos" && pwd)/GhosttyKit.xcframework"
  [ -e "$abs" ] || { echo "ERROR: build GhosttyKit first (just deps-ghostty)" >&2; exit 1; }
  mkdir -p "$(dirname "$dst")"
  ln -s "$rel" "$dst"
  echo "OK: symlinked $dst -> $rel"

# Copy rtach binaries into app resources (needed after rtach rebuild).
[group("deps")]
copy-rtach:
  #!/usr/bin/env bash
  set -euo pipefail
  mkdir -p Clauntty/Resources/rtach
  cp "{{RTACH_DIR}}"/zig-out/bin/rtach-* Clauntty/Resources/rtach/
  echo "OK: rtach binaries copied"

# Build all deps: setup + doctor + ghostty + rtach (parallel) + link + copy rtach.
[group("deps")]
deps: setup doctor _deps-build deps-link copy-rtach

[private]
[parallel]
_deps-build: deps-ghostty deps-rtach

# --- Build / Test ------------------------------------------------------------

# Build for iOS Simulator (runs deps first).
[group("build")]
build: deps build-only

# Build without re-running deps (faster iteration).
[group("build")]
build-only:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Building for Simulator: {{SIM_DEVICE}} ({{CONFIGURATION}})"
  xcodebuild \
    -project "{{PROJECT}}" -scheme "{{SCHEME}}" \
    -configuration "{{CONFIGURATION}}" \
    -destination "platform=iOS Simulator,name={{SIM_DEVICE}}" \
    -quiet build
  echo "OK: build complete."

# Run unit tests on Simulator.
[group("build")]
test:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Running tests on: {{SIM_DEVICE}}"
  xcodebuild test \
    -project "{{PROJECT}}" -scheme "ClaunttyTests" \
    -destination "platform=iOS Simulator,name={{SIM_DEVICE}}" \
    -quiet
  echo "OK: tests passed."

# --- Release -----------------------------------------------------------------

# Build .xcarchive for device (signing required).
[group("release")]
archive: deps
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Archiving to: {{ARCHIVE_PATH}}"
  mkdir -p "$(dirname "{{ARCHIVE_PATH}}")"
  xcodebuild \
    -project "{{PROJECT}}" -scheme "{{SCHEME}}" \
    -configuration "{{ARCHIVE_CONFIGURATION}}" \
    -destination "generic/platform=iOS" \
    -archivePath "{{ARCHIVE_PATH}}" \
    -allowProvisioningUpdates archive \
    DEVELOPMENT_TEAM="{{TEAM_ID}}" \
    PRODUCT_BUNDLE_IDENTIFIER="{{BUNDLE_ID}}" \
    -quiet
  echo "OK: archive at {{ARCHIVE_PATH}}"

# Export .ipa from archive (needs ExportOptions.plist).
[group("release")]
ipa: archive
  #!/usr/bin/env bash
  set -euo pipefail
  [ -d "{{ARCHIVE_PATH}}" ] || { echo "ERROR: no archive at {{ARCHIVE_PATH}}" >&2; exit 1; }
  [ -f "{{EXPORT_OPTIONS_PLIST}}" ] || { echo "ERROR: missing {{EXPORT_OPTIONS_PLIST}}" >&2; exit 1; }
  mkdir -p "{{EXPORT_PATH}}"
  _tmp="{{EXPORT_PATH}}/_ExportOptions.plist"
  cp "{{EXPORT_OPTIONS_PLIST}}" "$_tmp"
  [ -z "{{EXPORT_METHOD}}" ] || plutil -replace method -string "{{EXPORT_METHOD}}" "$_tmp"
  [ -z "{{TEAM_ID}}" ]       || plutil -replace teamID -string "{{TEAM_ID}}" "$_tmp"
  echo "Exporting IPA to: {{EXPORT_PATH}}"
  xcodebuild -exportArchive \
    -archivePath "{{ARCHIVE_PATH}}" \
    -exportPath "{{EXPORT_PATH}}" \
    -exportOptionsPlist "$_tmp" \
    -allowProvisioningUpdates -quiet
  rm -f "$_tmp"
  echo "OK: IPA exported to {{EXPORT_PATH}}"

# --- Configure ---------------------------------------------------------------

# Patch bundle ID, team ID, URL scheme into pbxproj + plists + sim.sh.
[group("config")]
configure $bundle_id $team_id $url_scheme:
  #!/usr/bin/env bash
  set -euo pipefail
  echo "Patching: BUNDLE_ID=$bundle_id  TEAM_ID=$team_id  URL_SCHEME=$url_scheme"
  pbxproj="Clauntty.xcodeproj/project.pbxproj"

  if [ -f "{{EXPORT_OPTIONS_PLIST}}" ]; then
    plutil -replace teamID -string "$team_id" "{{EXPORT_OPTIONS_PLIST}}"
    echo "  OK: {{EXPORT_OPTIONS_PLIST}}"
  fi

  if [ -f "Clauntty/Info.plist" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $bundle_id" "Clauntty/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $url_scheme" "Clauntty/Info.plist" 2>/dev/null || true
    echo "  OK: Clauntty/Info.plist"
  fi

  if [ -f "scripts/sim.sh" ]; then
    perl -pi -e 's/^BUNDLE_ID="[^"]+"/BUNDLE_ID="'"${bundle_id//\//\\/}"'"/' "scripts/sim.sh"
    perl -pi -e 's/[A-Za-z0-9+.-]+:\/\//'"${url_scheme//\//\\/}"':\/\//g' "scripts/sim.sh"
    echo "  OK: scripts/sim.sh"
  fi

  if [ -f "$pbxproj" ]; then
    perl -pi -e 's/PRODUCT_BUNDLE_IDENTIFIER = [^;]+;/PRODUCT_BUNDLE_IDENTIFIER = '"${bundle_id//\//\\/}"';/g' "$pbxproj"
    perl -pi -e 's/DEVELOPMENT_TEAM = [^;]+;/DEVELOPMENT_TEAM = '"${team_id//\//\\/}"';/g' "$pbxproj"
    echo "  OK: $pbxproj"
  fi

  echo "Done. Run 'just doctor' to verify."

# --- Clean -------------------------------------------------------------------

# Clean everything: Xcode, DerivedData, zig outputs, framework link.
[group("clean")]
[confirm("This will remove build artifacts, DerivedData, and zig outputs. Continue?")]
clean: clean-xcode clean-derived clean-zig clean-link

# Xcode clean only.
[group("clean")]
clean-xcode:
  -xcodebuild -project "{{PROJECT}}" -scheme "{{SCHEME}}" -quiet clean 2>/dev/null

# Remove DerivedData for Clauntty.
[group("clean")]
clean-derived:
  @rm -rf "${HOME}/Library/Developer/Xcode/DerivedData/Clauntty-"* && echo "OK: DerivedData cleaned"

# Remove zig-out/zig-cache in ghostty + rtach.
[group("clean")]
clean-zig:
  @rm -rf "{{GHOSTTY_DIR}}/zig-out" "{{GHOSTTY_DIR}}/zig-cache" "{{RTACH_DIR}}/zig-out" "{{RTACH_DIR}}/zig-cache" 2>/dev/null; echo "OK: zig outputs cleaned"

# Remove the GhosttyKit framework symlink.
[group("clean")]
clean-link:
  @rm -rf Frameworks/GhosttyKit.xcframework 2>/dev/null; echo "OK: framework link removed"
