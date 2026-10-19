#!/bin/bash
BIN=/root/build/real_firmware_245/bli_tools/signature_checker
OBJDUMP=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-objdump

echo "=== function start 0x10d88 - 0x10e70 (prologue, getopt, path setup) ==="
$OBJDUMP -d --start-address=0x10d88 --stop-address=0x10e70 "$BIN"
