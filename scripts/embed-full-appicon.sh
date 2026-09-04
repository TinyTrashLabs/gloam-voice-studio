#!/bin/zsh
# Replace actool's AppIcon.icns with a complete one.
#
# App Store Connect takes the store icon from AppIcon.icns in the app bundle --
# the build's iconAssetToken literally points at ".../AppIcon.icns" -- and NOT
# from Assets.car. But modern actool only writes a small compatibility icns:
# 16, 32, 128 and 256 (ic04/ic11/ic07/ic13), with no 512 and no 1024. That is
# actool working as intended, and it is NOT fixed by giving each slot its own
# source file; a from-scratch actool run over ten distinct per-slot images
# emits the same four.
#
# The visible result was that ASC only ever had a 256px icon and upscaled it,
# so the listing showed a soft, wrong-looking logo while Assets.car held a
# perfectly good 1024. iconutil honours every size, so we rebuild it here.
#
# Runs after the resource phase and before signing, so the signature covers the
# file we write.
set -euo pipefail

SRC="${SRCROOT:?}/App/Assets.xcassets/AppIcon.appiconset"
# TARGET_BUILD_DIR, not BUILT_PRODUCTS_DIR: during an archive/install build the
# two diverge, and the sandbox grants write only to the declared output path.
DEST="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/AppIcon.icns"
# Staged in a temp dir, not DERIVED_FILE_DIR: user script sandboxing only
# grants write access to this phase's declared outputFiles, so building the
# iconset anywhere under the build directory is denied.
WORK="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$WORK")"' EXIT
mkdir -p "$WORK"

# Slot name -> source file. 32, 256 and 512 each serve two slots (the @2x of
# the size below, and the 1x of their own), and iconutil wants a distinct file
# per slot name.
cp "$SRC/icon-16.png"   "$WORK/icon_16x16.png"
cp "$SRC/icon-32.png"   "$WORK/icon_16x16@2x.png"
cp "$SRC/icon-32.png"   "$WORK/icon_32x32.png"
cp "$SRC/icon-64.png"   "$WORK/icon_32x32@2x.png"
cp "$SRC/icon-128.png"  "$WORK/icon_128x128.png"
cp "$SRC/icon-256.png"  "$WORK/icon_128x128@2x.png"
cp "$SRC/icon-256.png"  "$WORK/icon_256x256.png"
cp "$SRC/icon-512.png"  "$WORK/icon_256x256@2x.png"
cp "$SRC/icon-512.png"  "$WORK/icon_512x512.png"
cp "$SRC/icon-1024.png" "$WORK/icon_512x512@2x.png"

# Build to a temp path, then overwrite $DEST in place. iconutil unlinks its
# output first, and during an archive/install build the sandbox permits
# writing this phase's declared output but NOT unlinking it
# ("deny(1) file-write-unlink"). Truncating via cat sidesteps that.
iconutil -c icns "$WORK" -o "$WORK.icns"
cat "$WORK.icns" > "$DEST"

# Fail the build rather than silently ship a truncated icon again: ic09 is the
# 512 and ic10 the 1024.
"$SRCROOT/scripts/verify-appicon-icns.py" "$DEST" "$SRC/icon-1024.png"
