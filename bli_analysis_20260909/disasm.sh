#!/bin/bash
set -e
DST=/root/build/real_firmware_245/bli_tools
TC=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin
SRC="$(cd "$(dirname "$0")" && pwd)"

for f in signature_checker bli_unseal_rsa_helper bli_parser; do
  "$TC/arm-openwrt-linux-objdump" -d -j .text --no-show-raw-insn "$DST/$f" > "$SRC/${f}.disasm.txt" 2>&1
  "$TC/arm-openwrt-linux-objdump" -R "$DST/$f" > "$SRC/${f}.relocs.txt" 2>&1
done
echo DONE
