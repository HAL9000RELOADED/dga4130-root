#!/bin/bash
set -x
BIN=/root/build/real_firmware_245/bli_tools/signature_checker
OBJDUMP=/root/build/toolchain/toolchain-arm_cortex-a9+neon_gcc-4.8-linaro_glibc_eabi/bin/arm-openwrt-linux-objdump

$OBJDUMP -d "$BIN" > /tmp/full_dis.txt
wc -l /tmp/full_dis.txt

echo "--- refs to 0001219c (OSIK msg) ---"
grep -n '0001219c' /tmp/full_dis.txt

echo "--- refs to 000121e3 (both OSIK/RSA missing msg) ---"
grep -n '000121e3' /tmp/full_dis.txt

echo "--- refs to 000121d1 (RSA key exists msg approx) ---"
grep -n '000121d' /tmp/full_dis.txt

echo "--- section headers ---"
$OBJDUMP -h "$BIN"

echo "--- .text range full disasm (all of it) ---"
cat /tmp/full_dis.txt
