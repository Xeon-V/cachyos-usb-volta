#!/bin/bash
# ============================================================================
# CachyOS Live USB - Volta/Titan V Setup
# ============================================================================
# Index system → inject into live USB → force 580xx → pin CUDA 12.9
# Works on ANY USB: Ventoy, Rufus DD mode, Rufus ISO mode, manual copy
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -eq 0 ]] || error "Run as root: sudo bash $0"

# Check deps
missing=""
for cmd in unsquashfs mksquashfs lsblk mount umount findmnt cp dd xorriso; do
    command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
[ -z "$missing" ] || error "Missing:$missing"

# =============================================================================
# STEP 1: INDEX SYSTEM
# =============================================================================
info "Indexing system..."
WORK_DIR=$(mktemp -d /tmp/cachy-mod.XXXXXX)
SNAPSHOT="$WORK_DIR/snapshot"
mkdir -p "$SNAPSHOT"/{pacman,pip,system,gpu}

# GPU info
nvidia-smi -L > "$SNAPSHOT/gpu/gpus.txt" 2>/dev/null || true
nvidia-smi --query-gpu=gpu_name,compute_cap,driver_version,memory.total --format=csv > "$SNAPSHOT/gpu/gpu-summary.csv" 2>/dev/null || true

# PyTorch info
python3 -c "
import sys, json
data = {'python': sys.version}
try:
    import torch
    data['torch'] = {
        'version': torch.__version__,
        'cuda': torch.version.cuda,
        'gpu_available': torch.cuda.is_available(),
        'gpu_name': torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
        'arch_list': torch.cuda.get_arch_list() if hasattr(torch.cuda, 'get_arch_list') else None
    }
except Exception as e:
    data['torch_error'] = str(e)
print(json.dumps(data, indent=2))
" > "$SNAPSHOT/gpu/pytorch.json" 2>/dev/null || true

# Pacman packages
pacman -Qqen > "$SNAPSHOT/pacman/explicit.txt"
pacman -Qqm  > "$SNAPSHOT/pacman/foreign.txt" 2>/dev/null || true

# Pip packages
for pybin in python3 python pip pip3; do
    if command -v "$pybin" &>/dev/null; then
        "$pybin" -m pip list --format=freeze > "$SNAPSHOT/pip/pip-freeze.txt" 2>/dev/null && break
    fi
done

# Configs
cp /etc/pacman.conf "$SNAPSHOT/system/pacman.conf" 2>/dev/null || true
cp -r /etc/pacman.d "$SNAPSHOT/system/pacman.d" 2>/dev/null || true

info "Indexed: $(wc -l < "$SNAPSHOT/pacman/explicit.txt") explicit packages"

# =============================================================================
# STEP 2: FIND USB
# =============================================================================
info "Finding CachyOS USB..."
USB_MOUNT="$WORK_DIR/usb"
mkdir -p "$USB_MOUNT"

USB_DEV=""
mapfile -t parts < <(lsblk -ndo PATH,TYPE | awk '$2=="part" {print $1}')
for dev in "${parts[@]}"; do
    [[ -b "$dev" ]] || continue
    findmnt -n -o SOURCE / 2>/dev/null | grep -q "$dev" && continue
    mount "$dev" "$USB_MOUNT" &>/dev/null || continue
    if [[ -f "$USB_MOUNT/arch/x86_64/airootfs.sfs" ]]; then
        USB_DEV="$dev"
        info "Found airootfs.sfs on $dev"
        break
    fi
    umount "$USB_MOUNT" &>/dev/null || true
done

if [[ -z "$USB_DEV" ]]; then
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL,TRAN
    read -rp "Enter USB device path (e.g., /dev/sdb1): " USB_DEV
    mount "$USB_DEV" "$USB_MOUNT" || error "Failed to mount $USB_DEV"
    [[ -f "$USB_MOUNT/arch/x86_64/airootfs.sfs" ]] || error "No airootfs.sfs found"
fi

FS_TYPE=$(findmnt -n -o FSTYPE "$USB_MOUNT")
info "Filesystem: $FS_TYPE"

AIROOTFS="$USB_MOUNT/arch/x86_64/airootfs.sfs"

# Check writability
REBUILD_ISO=0
if [[ "$FS_TYPE" == "iso9660" || "$FS_TYPE" == "udf" ]]; then
    warn "USB is read-only ($FS_TYPE). Will rebuild ISO."
    REBUILD_ISO=1
elif ! touch "$USB_MOUNT/.write_test" 2>/dev/null; then
    warn "USB not writable. Will rebuild ISO."
    REBUILD_ISO=1
    umount "$USB_MOUNT" 2>/dev/null || true
else
    rm -f "$USB_MOUNT/.write_test"
fi

# =============================================================================
# STEP 3: EXTRACT & MODIFY
# =============================================================================
if [[ "$REBUILD_ISO" -eq 1 ]]; then
    info "Copying ISO contents to temp..."
    ISO_COPY="$WORK_DIR/iso-copy"
    mkdir -p "$ISO_COPY"
    cp -a "$USB_MOUNT"/* "$ISO_COPY/" 2>/dev/null || true
    # Copy hidden files too
    for f in "$USB_MOUNT"/.*; do [[ -e "$f" ]] && cp -a "$f" "$ISO_COPY/"; done 2>/dev/null || true
    umount "$USB_MOUNT" 2>/dev/null || true
    USB_MOUNT="$ISO_COPY"
    AIROOTFS="$USB_MOUNT/arch/x86_64/airootfs.sfs"
    info "Copied $(du -sh "$ISO_COPY" | cut -f1) to temp"
fi

# Backup original
if [[ ! -f "$AIROOTFS.original" ]]; then
    cp "$AIROOTFS" "$AIROOTFS.original"
    info "Backup: airootfs.sfs.original"
fi

info "Extracting squashfs..."
SQUASH="$WORK_DIR/squashfs-root"
unsquashfs -d "$SQUASH" "$AIROOTFS"

info "Injecting snapshot..."
mkdir -p "$SQUASH/root/snapshot"
cp -a "$SNAPSHOT"/* "$SQUASH/root/snapshot/"

# =============================================================================
# STEP 4: CHWD PROFILE - NVIDIA 580xx
# =============================================================================
info "Adding chwd profile for 580xx..."
CHWD_DIR="$SQUASH/usr/share/chwd/profiles/pci/graphic_drivers"
mkdir -p "$CHWD_DIR"

cat >> "$CHWD_DIR/profiles.toml" << 'CHWDEOF'

[custom-volta-nvidia-580xx]
name = "Volta NVIDIA 580xx (Titan V)"
desc = "Forced legacy driver for Volta sm_70 GPUs"
priority = 9999
packages = "nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils"
CHWDEOF

info "chwd profile added (priority 9999)"

# =============================================================================
# STEP 5: POST-INSTALL SCRIPT
# =============================================================================
info "Creating post-install script..."
mkdir -p "$SQUASH/usr/local/bin"

cat > "$SQUASH/usr/local/bin/cachy-post-install" << 'POSTEOF'
#!/bin/bash
set -e

echo "=========================================="
echo "  CachyOS Volta Post-Install"
echo "=========================================="

# Remove conflicting drivers
echo "[*] Removing conflicting drivers..."
pacman -Rdd --noconfirm linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open 2>/dev/null || true

# Force 580xx profile
echo "[*] Applying NVIDIA 580xx profile..."
chwd -a -f || true

# CUDA 12.9 pinning
echo "[*] Pinning CUDA to 12.9..."
if grep -q "^IgnorePkg" /etc/pacman.conf 2>/dev/null; then
    sed -i 's/^IgnorePkg.*/& cuda cuda-tools cudnn/' /etc/pacman.conf 2>/dev/null || true
else
    echo "IgnorePkg = cuda cuda-tools cudnn" >> /etc/pacman.conf
fi

# Restore custom repos from snapshot
if [[ -f /root/snapshot/system/pacman.conf ]]; then
    echo "[*] Merging custom repos..."
    grep -E '^\[cachy' /root/snapshot/system/pacman.conf >> /etc/pacman.conf 2>/dev/null || true
fi

# Install captured packages
if [[ -f /root/snapshot/pacman/explicit.txt ]]; then
    count=$(wc -l < /root/snapshot/pacman/explicit.txt)
    echo "[*] Installing $count explicit packages..."
    pacman -S --needed --noconfirm - < /root/snapshot/pacman/explicit.txt || true
fi

echo ""
echo "[*] PyTorch: For Titan V use cu126 wheels"
echo "    pip install torch --index-url https://download.pytorch.org/whl/cu126"
echo ""
echo "[*] GPU Status:"
nvidia-smi -L 2>/dev/null || echo "    Available after reboot"
echo ""
echo "Done. Reboot when ready."
echo "=========================================="
POSTEOF

chmod +x "$SQUASH/usr/local/bin/cachy-post-install"

# Desktop shortcut
mkdir -p "$SQUASH/home/cachy/Desktop"
cat > "$SQUASH/usr/share/applications/cachy-post-install.desktop" << 'DESKTOPEOF'
[Desktop Entry]
Name=Run Volta Post-Install
Comment=Apply NVIDIA 580xx for Titan V
Exec=konsole -e /usr/local/bin/cachy-post-install
Type=Application
Terminal=true
Icon=system-software-install
Categories=System;
DESKTOPEOF

cp "$SQUASH/usr/share/applications/cachy-post-install.desktop" "$SQUASH/home/cachy/Desktop/" 2>/dev/null || true
chown -R 1000:1000 "$SQUASH/home/cachy/Desktop" 2>/dev/null || true

# =============================================================================
# STEP 6: RESQUASH
# =============================================================================
info "Repacking squashfs..."
rm -f "$AIROOTFS"
mksquashfs "$SQUASH" "$AIROOTFS" -comp xz -Xbcj x86 -noappend

# =============================================================================
# STEP 7: REBUILD ISO OR DIRECT SYNC
# =============================================================================
if [[ "$REBUILD_ISO" -eq 1 ]]; then
    info "Rebuilding ISO..."
    NEW_ISO="$WORK_DIR/cachyos-volta-$(date +%Y%m%d-%H%M).iso"
    
    # Find isohdpfx.bin
    ISOHDPFX=""
    for p in /usr/lib/syslinux/bios/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin; do
        [[ -f "$p" ]] && ISOHDPFX="$p" && break
    done
    [[ -n "$ISOHDPFX" ]] || error "Install syslinux for isohdpfx.bin"
    
    # Find EFI image
    EFI_IMG=""
    for p in "$USB_MOUNT/EFI/boot/efiboot.img" "$USB_MOUNT/efi/boot/efiboot.img"; do
        [[ -f "$p" ]] && EFI_IMG="${p#$USB_MOUNT/}" && break
    done
    
    if [[ -n "$EFI_IMG" ]]; then
        xorriso -as mkisofs \
            -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock \
            -volid "CACHYOS_VOLTA" \
            -eltorito-boot isolinux/isolinux.bin -eltorito-catalog isolinux/boot.cat \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            -isohybrid-mbr "$ISOHDPFX" \
            -eltorito-alt-boot -e "$EFI_IMG" -no-emul-boot -isohybrid-gpt-basdat \
            -output "$NEW_ISO" "$USB_MOUNT"
    else
        # No EFI, simple ISO
        xorriso -as mkisofs \
            -iso-level 3 -full-iso9660-filenames -joliet -rational-rock \
            -volid "CACHYOS_VOLTA" \
            -boot-load-size 4 -boot-info-table \
            -isohybrid-mbr "$ISOHDPFX" \
            -output "$NEW_ISO" "$USB_MOUNT"
    fi
    
    info "ISO created: $NEW_ISO"
    
    # Re-flash USB
    BASE_DEV="$USB_DEV"
    [[ "$USB_DEV" =~ [0-9]$ ]] && BASE_DEV="${USB_DEV%[0-9]}"
    
    read -rp "Flash to $BASE_DEV now? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        dd if="$NEW_ISO" of="$BASE_DEV" bs=4M status=progress conv=fsync
        info "USB flashed successfully"
    else
        info "ISO ready: $NEW_ISO"
        info "Flash manually: dd if=$NEW_ISO of=$BASE_DEV bs=4M status=progress"
    fi
else
    info "Syncing..."
    sync
    umount "$USB_MOUNT" || true
fi

rm -rf "$WORK_DIR"

echo ""
echo "============================================================"
echo "  DONE"
echo ""
echo "  1. Boot from USB, install CachyOS"
echo "  2. After Calamares (before reboot):"
echo "     Click 'Run Volta Post-Install' on desktop"
echo "     OR: sudo /usr/local/bin/cachy-post-install"
echo ""
echo "  Driver: nvidia-580xx (chwd priority 9999)"
echo "  CUDA:   Pinned to 12.9 via IgnorePkg"
echo "  PyTorch: Use cu126 wheels (last sm_70 support)"
echo "============================================================"
