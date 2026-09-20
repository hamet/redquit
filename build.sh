#!/bin/bash
# Build + ad-hoc sign ./redquit. No install — see install.sh.
NAME=redquit
LABEL=com.user.redquit

cd "$(dirname "$0")" || exit 1

echo "==> build"
swiftc -O "$NAME.swift" -o "$NAME" || { echo "build failed"; exit 1; }

echo "==> sign (ad-hoc, fixed identifier — keeps the TCC grant stable)"
codesign -s - -f --identifier "$LABEL" "$NAME" || { echo "codesign failed"; exit 1; }

echo "built: $(pwd)/$NAME"
