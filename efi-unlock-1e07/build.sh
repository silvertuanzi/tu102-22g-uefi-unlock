#!/bin/bash
# build.sh — TU102 Rev.A (RTX 2080 Ti 22G mod, 10de:1e07) UEFI tensor-unlock
# Port of tu102-22g-uefi-unlock/efi-unlock-tu102 (same exploit chain).
#
# Modes:
#   DUMP_ONLY=1 ./build.sh   -> TU102DUMP.EFI  (no firmware inputs; read-only
#                                PROM/register capture, then chainload/return)
#   ./build.sh               -> TU102-1E07.EFI (unlock; needs the four TU102
#                                CMP blobs + this card's fwsec_native.bin)
#
# Outputs embed NVIDIA firmware: NOT redistributable, do not commit.
set -euo pipefail
cd "$(dirname "$0")"

EFI_INC="${EFI_INC:-/usr/include/efi}"
EFI_LIB="${EFI_LIB:-/usr/lib}"
if [ ! -d "$EFI_INC" ]; then
    echo "gnu-efi headers not found at $EFI_INC (pacman -S gnu-efi)" >&2
    exit 1
fi

SRC=unlock50x_v1.c
OBJ=tu102.o
OUT=tu102.so
EFIOUT=TU102-1E07.EFI
EXTRA_DEFS=""
BASE_DEFS="-DGNU_EFI_USE_MS_ABI -DDIRECT_SEC2 -DRELEASE_BUILD"

# ---- expected hashes -------------------------------------------------------
# Four TU102 blobs pinned to xrip/cmp50hx-unlock @ df2fe11 (identical to the
# 1e04 port; local copy: ../part/cmp50hx-unlock/efi-unlock/blobs/):
BL_V67=de7288bcfb80c2d4b259a59e823c926ba0a9adcab594219cc6802c94257ce271
BL_BOOTER=e0f0fc93da097b5b68e5af3adb58b2235ed1fad5fce0b23592d3895af44cb743
BL_GSPRM=fa43239bcee7b97ca62f007cc68487560a39e19f74f3dde7486db3f98df8e471
BL_BLGSP=f21f1cfbb8fffa8067685314367fc4c50f3f84dd99eda7c19db4292d9269b9d9
# This card's (10de:1e07, Colorful 7377:1401, VBIOS 90.02.17.00.61) native
# FWSEC, extracted from TU102.rom by extract_fwsec.py AND structure-checked
# by KohakUnlock rom_analyze.py (mapper/command bounds OK). 39440 B = the
# ASUS-published TU102 FWSEC size family, NOT the Leadtek 1e04 39968 B one.
FWSEC_NATIVE=584b5fe0826c40aaa8731d70f4fe5fb505380075dca77f7a94d31cfa09d20f6e

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

mkdir -p blobs
DUMP=0
[ "${DUMP_ONLY:-0}" = "1" ] && DUMP=1

if [ "$DUMP" = "1" ]; then
    EFIOUT=TU102DUMP.EFI
    EXTRA_DEFS="-DDUMP_ONLY"
    echo "=== DUMP-ONLY build (no firmware inputs required) ==="
else
    need() { [ -f "blobs/$1" ] || { echo "missing blobs/$1" >&2
        echo "  copy from ../part/cmp50hx-unlock/efi-unlock/blobs/ (TU102 blobs)" >&2
        echo "  and extract_fwsec.py TU102.rom blobs/ (your FWSEC) — see README" >&2
        exit 1; }; }
    need v67_payload.bin; need booter_ucode_prod.bin
    need gsp_rm_boot_dbg.bin; need bl_gsp_tu102.bin; need fwsec_native.bin
    for pair in "v67_payload.bin:$BL_V67" "booter_ucode_prod.bin:$BL_BOOTER" \
                "gsp_rm_boot_dbg.bin:$BL_GSPRM" "bl_gsp_tu102.bin:$BL_BLGSP"; do
        f=${pair%%:*}; exp=${pair##*:}
        if [ "$(sha "blobs/$f")" != "$exp" ]; then
            echo "HASH MISMATCH: blobs/$f != cmp50hx-unlock@df2fe11 expected value" >&2
            exit 1
        fi
    done
    if [ "$(sha blobs/fwsec_native.bin)" != "$FWSEC_NATIVE" ] && [ "${TU102_ALLOW_FWSEC:-0}" != "1" ]; then
        echo "fwsec_native.bin does not match the 1e07 card profile (584b5fe0...)." >&2
        echo "Re-extract from TU102.rom with extract_fwsec.py; if the card changed," >&2
        echo "re-derive FW50_* constants and opt in with TU102_ALLOW_FWSEC=1." >&2
        exit 1
    fi
    echo "=== UNLOCK build (inputs hash-verified) ==="
    BASE_DEFS="$BASE_DEFS -DVBIOS_DUMP"
fi

# Placeholders for blobs referenced by unused code paths
for f in booter_ucode_dbg.bin fwsec_50hx_prod.bin fwsec_50hx_dbg.bin \
         sec2_ucode_vbios_49.bin sec2_ucode_vbios_89.bin; do
    [ -f "blobs/$f" ] || ( cd blobs && printf '\0' > "$f" )
done
if [ "$DUMP" = "1" ]; then
    for f in v67_payload.bin booter_ucode_prod.bin gsp_rm_boot_dbg.bin \
             bl_gsp_tu102.bin fwsec_native.bin; do
        [ -f "blobs/$f" ] || ( cd blobs && printf '\0' > "$f" )
    done
fi

echo "=== 1. compile $SRC ==="
gcc -c -O2 -fno-stack-protector -fpic -ffreestanding \
    -fno-asynchronous-unwind-tables -fno-unwind-tables \
    -fshort-wchar -mno-red-zone -maccumulate-outgoing-args \
    -fno-builtin -fno-strict-aliasing -Wno-unused-function \
    -I "$EFI_INC" -I "$EFI_INC/x86_64" \
    $BASE_DEFS $EXTRA_DEFS \
    -o "$OBJ" "$SRC"

echo "=== 2. embed blobs ==="
# Debian/Arch gnu-efi archives hold ELF objects, so the whole link is ELF
# (crt0 + elf_x86_64_efi.lds) and the blob objects must be ELF too.
# objcopy derives the symbol name from the FILENAME AS GIVEN — run it from
# blobs/ with a bare name (upstream lesson: prefixed symbols redefined to
# zero and every falcon ran zero-filled code).
embed() {
  local f="$1" tgt="$2"
  local base="${f//./_}"
  ( cd blobs && objcopy --input-target binary --output-target elf64-x86-64 \
      --binary-architecture i386:x86-64 \
      --redefine-sym "_binary_${base}_start=${tgt}" \
      --redefine-sym "_binary_${base}_end=${tgt}_end" \
      --redefine-sym "_binary_${base}_size=${tgt}_size" \
      "$f" "../${tgt}.o" )
  if ! nm "${tgt}.o" | grep -qE "^[0-9a-f]+ [A-Za-z] ${tgt}$"; then
    echo "  EMBED FAILED for $f (symbol ${tgt} not defined)" >&2
    exit 1
  fi
  echo "  embedded $f -> ${tgt}"
}
embed v67_payload.bin         v67_payload_bin
embed booter_ucode_dbg.bin    booter_ucode_dbg
embed booter_ucode_prod.bin   booter_ucode_prod
embed gsp_rm_boot_dbg.bin     gsp_rm_boot_dbg
embed fwsec_50hx_prod.bin     fwsec_50hx_prod_bin
embed fwsec_native.bin        fwsec_native_bin
embed fwsec_50hx_dbg.bin      fwsec_50hx_dbg_bin
embed sec2_ucode_vbios_49.bin sec2_ucode_vbios_49
embed sec2_ucode_vbios_89.bin sec2_ucode_vbios_89
embed bl_gsp_tu102.bin        gsp_bl_tu102
OBJS="$OBJ v67_payload_bin.o booter_ucode_dbg.o booter_ucode_prod.o \
gsp_rm_boot_dbg.o fwsec_50hx_prod_bin.o fwsec_native_bin.o fwsec_50hx_dbg_bin.o \
sec2_ucode_vbios_49.o sec2_ucode_vbios_89.o gsp_bl_tu102.o"

echo "=== 3. link ==="
ld -nostdlib -znocombreloc -T "$EFI_LIB/elf_x86_64_efi.lds" -shared -Bsymbolic \
    "$EFI_LIB/crt0-efi-x86_64.o" $OBJS \
    -L"$EFI_LIB" -lgnuefi -lefi -o "$OUT" 2>&1 | tail -12

if [ ! -f "$OUT" ]; then
    echo "LINK FAILED" >&2
    exit 1
fi

echo "=== 4. convert ==="
objcopy -I elf64-x86-64 -O pei-x86-64 \
    -j .text -j .sdata -j .data -j .rodata -j .dynamic -j .dynsym \
    -j .reloc -j .rel -j .rela -j .rel.* -j .rela.* \
    "$OUT" "$EFIOUT" 2>&1 | tail -4
# Arch binutils' pei-x86-64 leaves Subsystem=0 (NATIVE), alignments 0 and
# SizeOfImage=0; EFI loaders reject that ("Unsupported" in BdsDxe). Fill
# them like Debian's efi-app-x86-64 target does.
python3 - "$EFIOUT" <<'PYEOF'
import struct, sys
p = sys.argv[1]
b = bytearray(open(p,'rb').read())
pe = struct.unpack_from('<I', b, 0x3c)[0]
coff = pe + 4
nsec = struct.unpack_from('<H', b, coff+2)[0]
ohsz = struct.unpack_from('<H', b, coff+16)[0]
oh = coff + 20
if struct.unpack_from('<H', b, oh)[0] != 0x20b:
    sys.exit("not PE32+")
secs = oh + ohsz
end_hdr = secs + nsec * 40
img_end = 0
for i in range(nsec):
    vsz, va, rsz, ro = struct.unpack_from('<IIII', b, secs + i*40 + 8)
    img_end = max(img_end, va + vsz)
struct.pack_into('<I', b, oh+60, end_hdr)    # SizeOfHeaders
struct.pack_into('<I', b, oh+32, 0x1000)     # SectionAlignment
struct.pack_into('<I', b, oh+36, 0x200)      # FileAlignment
struct.pack_into('<I', b, oh+56, img_end)    # SizeOfImage
struct.pack_into('<H', b, oh+68, 10)         # IMAGE_SUBSYSTEM_EFI_APPLICATION
open(p,'wb').write(b)
PYEOF
