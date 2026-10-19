#!/bin/bash
BIN=/root/build/real_firmware_245/bli_tools/signature_checker
OBJDUMP=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-objdump
READELF=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-readelf

echo "=== PLT disassembly with symbol resolution ==="
$OBJDUMP -d -R "$BIN" | sed -n '/<.plt>:/,/<.text>:/p'

echo ""
echo "=== dynamic relocations (PLT symbol mapping) ==="
$READELF -r "$BIN"
