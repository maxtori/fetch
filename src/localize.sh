#!/bin/sh
# localize.sh IN.a OUT.a PREFIX
#
# A Rust staticlib bundles Rust's standard library (and its other crates):
# two of them in one program (fetch and idb, say) define the same symbols,
# and the link fails. Turn IN.a into a single object where only the
# symbols starting with PREFIX (the C entry points) stay global, so that
# each library keeps its copy private.
#
# Needs GNU ld and objcopy; elsewhere, IN.a is copied as is (then only one
# Rust library per program).
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
