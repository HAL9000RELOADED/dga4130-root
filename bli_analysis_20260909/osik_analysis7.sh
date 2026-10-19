#!/bin/bash
BIN=/root/build/real_firmware_245/bli_tools/signature_checker
OBJDUMP=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-objdump

$OBJDUMP -d "$BIN" > /tmp/full_dis2.txt
echo "--- calls to 10b84 (d2i_DSAPublicKey) ---"
grep -n 'bl.*10b84' /tmp/full_dis2.txt
echo "--- calls to 10d40 (DSA_verify) ---"
grep -n 'bl.*10d40' /tmp/full_dis2.txt
echo "--- calls to 10bcc (BN_bin2bn) ---"
grep -n 'bl.*10bcc' /tmp/full_dis2.txt
echo "--- calls to 10cc8 (RSA_new) ---"
grep -n 'bl.*10cc8' /tmp/full_dis2.txt
echo "--- disasm 0x11c20-0x11c34 helper (calls RSA_free? check) ---"
$OBJDUMP -d --start-address=0x11c20 --stop-address=0x11c34 "$BIN"
