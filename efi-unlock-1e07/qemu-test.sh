#!/bin/bash
# OVMF smoke test for TU102-1E07 builds (no GPU present, expect clean abort)
set -u
cd "$(dirname "$0")" || exit 1
IMG="${1:-TU102DUMP.EFI}"
[ -f "$IMG" ] || { echo "usage: $0 [image.efi]"; exit 1; }
T=$(mktemp -d) || exit 1
cp "$IMG" "$T/app.efi" || exit 1
cd "$T" || exit 1
dd if=/dev/zero of=disk.img bs=1M count=64 status=none
printf 'start=2048, type=0c, bootable\n' | sfdisk disk.img >/dev/null 2>&1
mformat -i disk.img@@1M ::
mmd -i disk.img@@1M ::/EFI ::/EFI/BOOT
mcopy -i disk.img@@1M app.efi ::/EFI/BOOT/BOOTX64.EFI
timeout 70 qemu-system-x86_64 -accel kvm -accel tcg -m 512 \
    -drive file=disk.img,format=raw -display none -serial file:serial.log \
    >/dev/null 2>&1
echo "--- serial markers ---"
tr -d '\000' < serial.log | grep -aiE "TU102|RUNNING|GPU|UNLOCK|=====" | head -20
if mcopy -o -i disk.img@@1M ::/50hx_log.txt ./log.txt 2>/dev/null; then
    echo "--- ESP log write-back OK ---"
    cat log.txt | head -30
else
    echo "--- no \\50hx_log.txt on ESP (unexpected if app ran; there is a FAT FS) ---"
fi
echo "scratch: $T"
