#!/bin/bash
set -e
SRC="$(cd "$(dirname "$0")" && pwd)"
DST=/root/build/real_firmware_245/bli_tools
TC=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin
mkdir -p "$DST"
cp "$SRC/signature_checker" "$SRC/bli_unseal_rsa_helper" "$SRC/bli_parser" "$DST/"
chmod +x "$DST"/*

OUT="$SRC/analysis_output.txt"
: > "$OUT"

for f in signature_checker bli_unseal_rsa_helper bli_parser; do
  echo "=============================================" >> "$OUT"
  echo "===== FILE: $f =====" >> "$OUT"
  echo "=============================================" >> "$OUT"
  echo "--- readelf -h ---" >> "$OUT"
  "$TC/arm-openwrt-linux-readelf" -h "$DST/$f" >> "$OUT" 2>&1
  echo "--- readelf -d (dynamic section / NEEDED libs) ---" >> "$OUT"
  "$TC/arm-openwrt-linux-readelf" -d "$DST/$f" >> "$OUT" 2>&1
  echo "--- readelf -sW (symbol table, dynsym+symtab) ---" >> "$OUT"
  "$TC/arm-openwrt-linux-readelf" -sW "$DST/$f" >> "$OUT" 2>&1
  echo "--- strings (len>=5) ---" >> "$OUT"
  strings -n 5 "$DST/$f" >> "$OUT" 2>&1
  echo "" >> "$OUT"
done

echo "DONE" >> "$OUT"
