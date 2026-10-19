#!/bin/bash
set -e
BIN=/root/build/real_firmware_245/bli_tools/signature_checker
OBJDUMP=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-objdump
READELF=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-readelf

echo "=== Section headers (need .rodata VMA + file offset) ==="
$READELF -S $BIN | grep -A1 rodata

echo ""
echo "=== Full disassembly, wider range 0x11600-0x11e50 (main + OSIK/DSA area) ==="
$OBJDUMP -d $BIN --start-address=0x11600 --stop-address=0x11e50

echo ""
echo "=== Disassembly from 0x11e50 to end of .text (look for more literal pools / DSA func) ==="
$OBJDUMP -d $BIN --start-address=0x11e50 --stop-address=0x12400
