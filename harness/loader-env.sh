#!/bin/sh
# loader-env.sh — hand the loader contract to the loader WITHOUT typing it.
#
#   loader-env.sh <disk.img> <loader.env>
#
# Writes <loader.env> to /efi/freebsd/loader.env on the image's EFI system
# partition. The UEFI loader reads that file (its LoaderEnv default) right
# after devinit and before it chooses a console, so every variable in it is in
# the environment before the first line of loader.conf and before autoboot:
# the guest boots with the contract applied and the harness never stops at
# the OK prompt.
#
# Why not type it: the emulated UART corrupts input. Once the loader is on
# comconsole, typed bytes go missing or arrive as NUL, and each one is a red
# run that only a rerun clears:
#   - `boot -v` arrived as `boot v`: the loader tried to load a kernel named
#     'v' ("Failed to load kernel 'v'", "can't load 'kernel'") and sat at the
#     prompt until the 480 s banner budget ran out (nextbsd-kernel run
#     42411198586, job 128521056625);
#   - the Enter after `set boot_mutemsgs=NO` arrived as NUL and the loader
#     never answered (nextbsd-userland run 42519963008, job 128853943415);
#   - `boot_multicons` echoed as `boo_multicons` (run 26070245676).
# Pacing, retries and echo checks only make that rarer. Not typing removes it.
#
# Only the ESP is touched, and only on the harness's copy of the image: the
# shipped image stays quiet (verbose is still a CI-time choice, never baked
# into an image). Exit 0 = written and read back; anything else = the caller
# falls back to the typed contract.

set -eu

IMG=${1:?usage: loader-env.sh <disk.img> <loader.env>}
ENVF=${2:?usage: loader-env.sh <disk.img> <loader.env>}

# The ESP's byte offset, from the GPT (type C12A7328-F81F-11D2-BA4B-00A0C93EC93B).
# Python (on every runner image) rather than sfdisk/gdisk, whose packaging
# differs between the x86 and arm runners. 512-byte sectors: these are raw
# images made by mkimg, not 4Kn disks.
OFF=$(python3 -I - "$IMG" <<'EOF'
import struct, sys, uuid
ESP = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
with open(sys.argv[1], "rb") as f:
    f.seek(512)
    hdr = f.read(92)
    if hdr[:8] != b"EFI PART":
        sys.exit(1)
    lba, count, size = struct.unpack_from("<QII", hdr, 72)
    f.seek(lba * 512)
    for _ in range(count):
        ent = f.read(size)
        if uuid.UUID(bytes_le=ent[:16]) == ESP:
            print(struct.unpack_from("<Q", ent, 32)[0] * 512)
            sys.exit(0)
sys.exit(1)
EOF
) || { echo "loader-env: no GPT EFI system partition in $IMG" >&2; exit 1; }

if ! command -v mcopy >/dev/null 2>&1; then
    echo "loader-env: installing mtools"
    sudo apt-get install -y --no-install-recommends mtools >/dev/null 2>&1 || true
fi
command -v mcopy >/dev/null 2>&1 || { echo "loader-env: mtools unavailable" >&2; exit 1; }

# mtools refuses a FAT whose geometry doesn't match a floppy table without this.
export MTOOLS_SKIP_CHECK=1
FAT="$IMG@@$OFF"
# FAT is case-insensitive: ::/efi is the EFI/ directory mkimg's ESP already
# carries (EFI/BOOT). mmd fails on a directory that exists, which is fine.
mmd -i "$FAT" ::/efi 2>/dev/null || true
mmd -i "$FAT" ::/efi/freebsd 2>/dev/null || true
mcopy -o -i "$FAT" "$ENVF" ::/efi/freebsd/loader.env
# Read it back: a silent short write would otherwise look like a loader that
# ignored the file.
mtype -i "$FAT" ::/efi/freebsd/loader.env | cmp -s - "$ENVF" || {
    echo "loader-env: read-back of ::/efi/freebsd/loader.env does not match" >&2
    exit 1
}
echo "==> loader.env written to the ESP (offset $OFF):"
sed 's/^/      /' "$ENVF"
