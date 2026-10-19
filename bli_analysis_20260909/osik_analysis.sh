#!/bin/bash
set -e
BIN=/root/build/real_firmware_245/bli_tools/signature_checker
OBJDUMP=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-objdump
READELF=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-readelf

echo "=== Full disassembly around OSIK/DSA region 0x11900-0x11c00 ==="
$OBJDUMP -d $BIN --start-address=0x11900 --stop-address=0x11c00

echo ""
echo "=== All strings in .rodata ==="
$READELF -p .rodata $BIN

echo ""
echo "=== Search for OSIK-related strings in whole binary ==="
$READELF -p .rodata $BIN | grep -i -A2 -B2 osik || true
strings -a -t x $BIN | grep -i osik || true

echo ""
echo "=== Search for /proc/rip paths ==="
strings -a -t x $BIN | grep -i "proc/rip" || true

echo ""
echo "=== Search for any /etc or key-like paths ==="
strings -a -t x $BIN | grep -iE "\.pem|\.key|/etc/|/proc/" || true
