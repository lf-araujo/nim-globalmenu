#!/bin/sh
# Regenerates the C glue for the Wayland protocols in protocols/ into
# src/globalmenu/proto/. Run after updating an XML file.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
out="$here/src/globalmenu/proto"
mkdir -p "$out"
for xml in "$here"/protocols/*.xml; do
  name=$(basename "$xml" .xml)
  wayland-scanner client-header "$xml" "$out/$name-client-protocol.h"
  wayland-scanner private-code "$xml" "$out/$name-protocol.c"
done
