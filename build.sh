#!/bin/bash
# Build dav-remount. Needs only the Xcode Command Line Tools (xcode-select --install).
#   ./build.sh              native binary for this Mac
#   ./build.sh --universal  arm64 + x86_64 fat binary
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools:  xcode-select --install" >&2
  exit 1
fi
mkdir -p build
FLAGS=(-O -swift-version 5 -framework NetFS -framework Security -framework IOKit)
if [[ "${1:-}" == "--universal" ]]; then
  swiftc "${FLAGS[@]}" -target arm64-apple-macos13.0  -o build/dav-remount-arm64  Sources/main.swift
  swiftc "${FLAGS[@]}" -target x86_64-apple-macos13.0 -o build/dav-remount-x86_64 Sources/main.swift
  lipo -create -output build/dav-remount build/dav-remount-arm64 build/dav-remount-x86_64
  rm -f build/dav-remount-arm64 build/dav-remount-x86_64
else
  swiftc "${FLAGS[@]}" -o build/dav-remount Sources/main.swift
fi
# Ad-hoc signature with a stable identifier, so the Keychain item created by
# `set-token` stays readable by this binary (a rebuild changes the code hash and
# the Keychain will ask once more; that is expected).
codesign --force --sign - --identifier dev.dav-remount.agent build/dav-remount
echo "built build/dav-remount — $(file -b build/dav-remount | cut -d, -f1-2)"
./build/dav-remount --version
