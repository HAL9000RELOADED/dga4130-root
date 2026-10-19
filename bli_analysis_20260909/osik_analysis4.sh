#!/bin/bash
BIN=/root/build/real_firmware_245/bli_tools/signature_checker
OBJDUMP=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-objdump

echo "=== 0x10e00 - 0x11620 (before main, likely contains OSIK/DSA verify function) ==="
$OBJDUMP -d --start-address=0x10e00 --stop-address=0x11620 "$BIN"
