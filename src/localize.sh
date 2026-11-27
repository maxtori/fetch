#!/bin/sh
set -e
in=$1 out=$2 prefix=$3
if command -v objcopy >/dev/null 2>&1 && ld -r --whole-archive "$in" -o "$out.o" 2>/dev/null; then
  objcopy --wildcard --keep-global-symbol="${prefix}*" "$out.o"
  rm -f "$out"
  ar rcs "$out" "$out.o"
  rm -f "$out.o"
else
  cp "$in" "$out"
fi
