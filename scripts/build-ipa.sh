#!/bin/bash
# Build a Clauntty .ipa (archive + export)
#
# Usage:
#   ./scripts/build-ipa.sh              # Local .ipa under build/export/
#   ./scripts/build-ipa.sh --upload     # Export + upload to App Store Connect
#   ./scripts/build-ipa.sh --no-clean   # Reuse existing archive if present
#   ./scripts/build-ipa.sh --archive-only
#   ./scripts/build-ipa.sh --export-only  # Export from existing archive
#
# Options:
#   --upload          Upload to App Store Connect (TestFlight)
#   --no-clean        Skip clean; keep prior archive unless rebuilding
#   --archive-only    Stop after archive (no export)
#   --export-only     Skip archive; export existing build/Clauntty.xcarchive
#   --method METHOD   Export method: app-store-connect (default), ad-hoc, development
#   -h, --help        Show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT="$PROJECT_DIR/Clauntty.xcodeproj"
SCHEME="Clauntty"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/Clauntty.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
TEAM_ID="65533RB4LC"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

UPLOAD=false
CLEAN=true
ARCHIVE_ONLY=false
EXPORT_ONLY=false
METHOD="app-store-connect"

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --upload) UPLOAD=true; shift ;;
        --no-clean) CLEAN=false; shift ;;
        --archive-only) ARCHIVE_ONLY=true; shift ;;
        --export-only) EXPORT_ONLY=true; CLEAN=false; shift ;;
        --method) METHOD="$2"; shift 2 ;;
        -h|--help) usage ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}" >&2
            usage
            ;;
    esac
done

if [[ "$ARCHIVE_ONLY" == true && "$EXPORT_ONLY" == true ]]; then
    echo -e "${RED}Cannot combine --archive-only and --export-only${NC}" >&2
    exit 1
fi

case "$METHOD" in
    app-store-connect|ad-hoc|development|enterprise) ;;
    *)
        echo -e "${RED}Invalid --method: $METHOD${NC}" >&2
        echo "Valid: app-store-connect, ad-hoc, development, enterprise" >&2
        exit 1
        ;;
esac

write_export_options() {
    local dest="$1"
    local destination="$2"  # "export" or "upload"
    cat > "$dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>${METHOD}</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>${destination}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
}

do_archive() {
    mkdir -p "$BUILD_DIR"

    if [[ "$CLEAN" == true ]]; then
        echo -e "${BLUE}Cleaning...${NC}"
        rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" clean -quiet
    fi

    echo -e "${BLUE}Archiving (generic iOS device)...${NC}"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        archive

    echo -e "${GREEN}Archive ready: $ARCHIVE_PATH${NC}"
}

do_export() {
    if [[ ! -d "$ARCHIVE_PATH" ]]; then
        echo -e "${RED}No archive at $ARCHIVE_PATH${NC}" >&2
        echo "Run without --export-only first, or pass a path after archiving." >&2
        exit 1
    fi

    mkdir -p "$EXPORT_PATH"
    local opts_plist="$BUILD_DIR/ExportOptions.generated.plist"
    local destination="export"
    if [[ "$UPLOAD" == true ]]; then
        destination="upload"
    fi

    write_export_options "$opts_plist" "$destination"

    if [[ "$UPLOAD" == true ]]; then
        echo -e "${BLUE}Exporting + uploading to App Store Connect...${NC}"
    else
        echo -e "${BLUE}Exporting local .ipa...${NC}"
    fi

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportOptionsPlist "$opts_plist" \
        -exportPath "$EXPORT_PATH" \
        -allowProvisioningUpdates

    local ipa
    ipa=$(find "$EXPORT_PATH" -name "*.ipa" -type f 2>/dev/null | head -1 || true)

    if [[ -n "$ipa" ]]; then
        local size
        size=$(du -h "$ipa" | awk '{print $1}')
        echo -e "${GREEN}IPA: $ipa ($size)${NC}"
    elif [[ "$UPLOAD" == true ]]; then
        echo -e "${GREEN}Upload complete (App Store Connect processing may take 5–30 min).${NC}"
    else
        echo -e "${YELLOW}Export finished but no .ipa found under $EXPORT_PATH${NC}"
        ls -la "$EXPORT_PATH" 2>/dev/null || true
        exit 1
    fi
}

cd "$PROJECT_DIR"

if [[ "$EXPORT_ONLY" != true ]]; then
    do_archive
fi

if [[ "$ARCHIVE_ONLY" == true ]]; then
    exit 0
fi

do_export
