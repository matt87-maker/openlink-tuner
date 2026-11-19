#!/bin/bash
# Xcode build phase: bundle libftdi + libusb (LGPL-2.1) inside OpenLink Tuner so users don't
# need Homebrew. Both stay separate, replaceable dylibs, shipped with their license texts.
set -euo pipefail
FTDI=/opt/homebrew/opt/libftdi/lib/libftdi1.2.dylib
USB=/opt/homebrew/opt/libusb/lib/libusb-1.0.0.dylib
if [[ ! -f "$FTDI" || ! -f "$USB" ]]; then
  echo "warning: libftdi/libusb not found (brew install libftdi) — the app will look for a system copy at runtime"
  exit 0
fi
FW="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
LIC="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Licenses"
mkdir -p "$FW" "$LIC"
cp -f "$FTDI" "$FW/libftdi1.2.dylib"
cp -f "$USB"  "$FW/libusb-1.0.0.dylib"
chmod u+w "$FW/libftdi1.2.dylib" "$FW/libusb-1.0.0.dylib"
install_name_tool -id "@rpath/libusb-1.0.0.dylib" "$FW/libusb-1.0.0.dylib"
install_name_tool -id "@rpath/libftdi1.2.dylib" "$FW/libftdi1.2.dylib"
install_name_tool -change "$USB" "@loader_path/libusb-1.0.0.dylib" "$FW/libftdi1.2.dylib"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$FW/libusb-1.0.0.dylib" "$FW/libftdi1.2.dylib"
cp -f /opt/homebrew/opt/libftdi/COPYING.LIB "$LIC/libftdi-LGPL-2.1.txt" 2>/dev/null || true
cp -f /opt/homebrew/opt/libusb/COPYING "$LIC/libusb-LGPL-2.1.txt" 2>/dev/null || true
echo "embedded libftdi + libusb"
