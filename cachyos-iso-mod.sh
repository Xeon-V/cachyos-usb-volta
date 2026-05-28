#!/bin/bash
# ============================================================================
# CachyOS ISO Modifier - Volta/Titan V Edition (GCC + CUDA + Driver Lock)
# ============================================================================
# Auto-installs missing dependencies, indexes system, modifies CachyOS Live ISO.
# Forces NVIDIA 580xx, pins CUDA 12.9, pins GCC, guides PyTorch cu126.
#
# USAGE:
#   sudo bash cachyos-iso-mod.sh              # auto-finds cachyos*.iso
#   sudo bash cachyos-iso-mod.sh --out ~/Desktop/
#   sudo bash cachyos-iso-mod.sh --iso custom.iso --out ~/Desktop/
# ============================================================================
set -euo pipefail

DRIVER_VERSION="${DRIVER_VERSION:-580xx}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}▶${NC}  $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
error() { echo -e "${RED}✖${NC}  $*"; exit 1; }
ok()    { echo -e "${GREEN}✔${NC}  $*"; }
step()  { echo -e "\n${CYAN}${BOLD}═══ $* ═══${NC}"; }

box() {
    local title="$1" line="$2"
    local len=${#line}
    local pad=$((58 - len))
    echo -e "${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} ${BOLD}${title}${NC}"
    echo -e "${CYAN}├────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC}  $line$(printf '%*s' $pad '') ${CYAN}│${NC}"
    echo -e "${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
}

spinner() {
    local pid=$1 msg="$2"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r ${CYAN}%s${NC} %s" "${spin:$i:1}" "$msg"
        i=$(( (i+1) % 10 ))
        sleep 0.1
    done
    printf "\r  ${GREEN}✔${NC} %s\n" "$msg"
}

[[ $EUID -eq 0 ]] || error "Run as root: sudo bash $0"

# =============================================================================
# PARSE ARGS + AUTO-DETECT ISO
# =============================================================================
ISO_IN=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)
            ISO_IN="$2"
            shift 2
            ;;
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        *)
            error "Unknown arg: $1\nUsage: $0 [--iso file.iso] [--out dir/]"
            ;;
    esac
done

if [[ -z "$ISO_IN" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    mapfile -t iso_candidates < <(find "$SCRIPT_DIR" -maxdepth 1 -type f -iname "cachyos*.iso" 2>/dev/null)

    if [[ ${#iso_candidates[@]} -eq 1 ]]; then
        ISO_IN="${iso_candidates[0]}"
        info "Auto-detected ISO: $(basename "$ISO_IN")"
    elif [[ ${#iso_candidates[@]} -gt 1 ]]; then
        warn "Multiple ISOs found:"
        for i in "${!iso_candidates[@]}"; do
            echo "  [$i] $(basename "${iso_candidates[$i]}")"
        done
        read -rp "Select ISO [0-$(( ${#iso_candidates[@]} - 1 ))]: " choice
        ISO_IN="${iso_candidates[$choice]}"
    else
        error "No ISO specified and no cachyos*.iso found in script directory.\nUsage: $0 [--iso file.iso] [--out dir/]"
    fi
fi

[[ -f "$ISO_IN" ]] || error "ISO not found: $ISO_IN"

# =============================================================================
# AUTO-DEPENDENCY INSTALL
# =============================================================================
step "Dependency Check"

declare -A dep_packages=(
    [unsquashfs]="squashfs-tools"
    [mksquashfs]="squashfs-tools"
    [pacman]="pacman"
    [mount]="util-linux"
    [umount]="util-linux"
    [findmnt]="util-linux"
    [xorriso]="libisoburn"
)

missing_pkgs=()
for cmd in "${!dep_packages[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        pkg="${dep_packages[$cmd]}"
        [[ " ${missing_pkgs[*]} " =~ " $pkg " ]] || missing_pkgs+=("$pkg")
    fi
done

if [[ ! -f /usr/lib/syslinux/bios/isohdpfx.bin && ! -f /usr/share/syslinux/isohdpfx.bin ]]; then
    [[ " ${missing_pkgs[*]} " =~ " syslinux " ]] || missing_pkgs+=("syslinux")
fi

if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    warn "Missing packages: ${missing_pkgs[*]}"
    read -rp "Install automatically with pacman? [Y/n]: " confirm
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        info "Installing ${missing_pkgs[*]}..."
        pacman -S --needed --noconfirm "${missing_pkgs[@]}" || error "Failed to install dependencies"
        ok "Dependencies installed"
    else
        error "Cannot continue without: ${missing_pkgs[*]}"
    fi
else
    ok "All dependencies present"
fi

# =============================================================================
# STEP 1: INDEX SYSTEM (INCLUDING GCC STATE)
# =============================================================================
step "System Index"

WORK_DIR=$(mktemp -d /tmp/cachy-iso-mod.XXXXXX)
SNAPSHOT="$WORK_DIR/snapshot"
mkdir -p "$SNAPSHOT"/{pacman,pip,system,gpu,cuda}

info "Scanning hardware..."
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi -L > "$SNAPSHOT/gpu/gpus.txt" 2>/dev/null || true
    nvidia-smi --query-gpu=gpu_name,compute_cap,pci.bus_id,driver_version,memory.total --format=csv > "$SNAPSHOT/gpu/gpu-summary.csv" 2>/dev/null || true
fi

info "Detecting PyTorch..."
python3 -c "
import sys, json
data = {'python': sys.version}
try:
    import torch
    data['torch'] = {
        'version': torch.__version__,
        'cuda': torch.version.cuda,
        'cudnn': torch.backends.cudnn.version() if torch.backends.cudnn.is_available() else None,
        'gpu_available': torch.cuda.is_available(),
        'gpu_name': torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
        'arch_list': torch.cuda.get_arch_list() if hasattr(torch.cuda, 'get_arch_list') else None
    }
except Exception as e:
    data['torch_error'] = str(e)
print(json.dumps(data, indent=2))
" > "$SNAPSHOT/gpu/pytorch.json" 2>/dev/null || true

info "Capturing GCC state..."
gcc --version > "$SNAPSHOT/system/gcc-version.txt" 2>/dev/null || true
g++ --version > "$SNAPSHOT/system/g++-version.txt" 2>/dev/null || true

# Capture kernel build GCC
if [[ -f /proc/version ]]; then
    cat /proc/version > "$SNAPSHOT/system/kernel-build-info.txt"
fi

info "Exporting packages..."
pacman -Qqen > "$SNAPSHOT/pacman/explicit.txt"
pacman -Qqm  > "$SNAPSHOT/pacman/foreign.txt" 2>/dev/null || true
pacman -Q    > "$SNAPSHOT/pacman/all-versions.txt"

# Capture GCC-related packages specifically
grep -E "^gcc|^gcc-libs|^gcc-" "$SNAPSHOT/pacman/all-versions.txt" > "$SNAPSHOT/cuda/gcc-packages.txt" 2>/dev/null || true

for pybin in python3 python pip pip3; do
    if command -v "$pybin" &>/dev/null; then
        "$pybin" -m pip list --format=freeze > "$SNAPSHOT/pip/pip-freeze.txt" 2>/dev/null && break
    fi
done

cp /etc/pacman.conf "$SNAPSHOT/system/pacman.conf" 2>/dev/null || true
cp -r /etc/pacman.d "$SNAPSHOT/system/pacman.d" 2>/dev/null || true

box "Index Complete" "Explicit: $(wc -l < "$SNAPSHOT/pacman/explicit.txt") | Foreign: $(wc -l < "$SNAPSHOT/pacman/foreign.txt" 2>/dev/null || echo 0) | Pip: $(wc -l < "$SNAPSHOT/pip/pip-freeze.txt" 2>/dev/null || echo 0)"

# =============================================================================
# STEP 2: MOUNT ISO (READ-ONLY LOOP)
# =============================================================================
step "Mounting ISO"

ISO_MOUNT="$WORK_DIR/iso-mount"
mkdir -p "$ISO_MOUNT"

mount -o loop,ro "$ISO_IN" "$ISO_MOUNT" || error "Failed to mount ISO (loop)"
info "Mounted: $(basename "$ISO_IN") → $ISO_MOUNT"

[[ -f "$ISO_MOUNT/arch/x86_64/airootfs.sfs" ]] || {
    umount "$ISO_MOUNT" || true
    error "No airootfs.sfs found. Is this a CachyOS/archiso ISO?"
}

AIROOTFS="$ISO_MOUNT/arch/x86_64/airootfs.sfs"

# =============================================================================
# STEP 3: COPY ISO TO WORKING DIR
# =============================================================================
step "Copying ISO Contents"

ISO_COPY="$WORK_DIR/iso-copy"
mkdir -p "$ISO_COPY"

(cp -a "$ISO_MOUNT"/* "$ISO_COPY"/ 2>/dev/null; true) &
spinner $! "Copying ISO data..."

for h in "$ISO_MOUNT"/.[!.]* "$ISO_MOUNT"/..?*; do
    [[ -e "$h" ]] && cp -a "$h" "$ISO_COPY"/ 2>/dev/null || true
done

umount "$ISO_MOUNT" || true
info "Original ISO unmounted. Working copy at $ISO_COPY"

AIROOTFS="$ISO_COPY/arch/x86_64/airootfs.sfs"

# =============================================================================
# STEP 4: EXTRACT AIROOTFS
# =============================================================================
step "Extracting airootfs.sfs"
SQUASH="$WORK_DIR/squashfs-root"
(unsquashfs -d "$SQUASH" "$AIROOTFS") &
spinner $! "Extracting squashfs..."

# =============================================================================
# STEP 5: INJECT SNAPSHOT
# =============================================================================
step "Injecting Snapshot"
mkdir -p "$SQUASH/root/snapshot"
cp -a "$SNAPSHOT"/* "$SQUASH/root/snapshot/"
ok "Snapshot injected"

# =============================================================================
# STEP 6: PATCH CHWD
# =============================================================================
step "Patching chwd"

CHWD_DIR="$SQUASH/usr/share/chwd/profiles/pci/graphic_drivers"
mkdir -p "$CHWD_DIR"
CHWD_PROFILE="$CHWD_DIR/profiles.toml"

[[ -f "$CHWD_PROFILE" ]] && cp "$CHWD_PROFILE" "$CHWD_PROFILE.backup"

cat >> "$CHWD_PROFILE" << 'CHWDEOF'

# >>> CACHYOS-USB-MOD VOLTA INJECTION <<<
[custom-volta-nvidia-580xx]
name = "Volta NVIDIA 580xx (Titan V)"
desc = "Forced legacy driver for Volta sm_70 GPUs"
priority = 9999
packages = "nvidia-580xx-dkms nvidia-580xx-utils lib32-nvidia-580xx-utils"
CHWDEOF

ok "Injected custom-volta-nvidia-580xx (priority 9999)"

# =============================================================================
# STEP 7: POST-INSTALL SCRIPT (WITH GCC PINNING)
# =============================================================================
step "Creating Post-Install Script"

mkdir -p "$SQUASH/usr/local/bin"
POST="$SQUASH/usr/local/bin/cachy-post-install"

cat > "$POST" << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "  CachyOS Volta/Titan V Post-Install"
echo "=========================================="

# --- NVIDIA Driver ----------------------------------------------------------
echo "[*] Removing conflicting drivers..."
pacman -Rdd --noconfirm linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open 2>/dev/null || true

echo "[*] Installing forced 580xx profile..."
chwd -a -f || true

# --- Pacman Packages --------------------------------------------------------
if [[ -f /root/snapshot/pacman/explicit.txt ]]; then
    count=$(wc -l < /root/snapshot/pacman/explicit.txt)
    echo "[*] Installing $count explicit packages..."
    pacman -S --needed --noconfirm - /root/snapshot/pacman/explicit.txt || {
        echo "[!] Some packages failed."
    }
fi

# --- Restore Configs (merge-only) ------------------------------------------
if [[ -f /root/snapshot/system/pacman.conf ]]; then
    echo "[*] Merging custom repositories..."
    grep -E '^\[.*\]' /root/snapshot/system/pacman.conf | while read -r repo_line; do
        repo_name=$(echo "$repo_line" | tr -d '[]')
        if ! grep -q "^\[$repo_name\]" /etc/pacman.conf 2>/dev/null; then
            echo "" >> /etc/pacman.conf
            echo "# Merged from snapshot" >> /etc/pacman.conf
            sed -n "/^\[$repo_name\]/,/^\[/p" /root/snapshot/system/pacman.conf | sed '$d' >> /etc/pacman.conf
            echo "    -> Added repo: $repo_name"
        fi
    done
fi

# --- GCC PINNING (Critical for DKMS + CUDA) --------------------------------
echo "[*] Pinning GCC for DKMS/CUDA compatibility..."
# DKMS builds kernel modules using the CURRENT system's GCC.
# If GCC upgrades but kernel was built with older GCC, DKMS fails.
# CUDA nvcc also has max GCC version limits.
# We pin gcc, gcc-libs, and kernel headers to prevent breakage.

GCC_IGNORE="gcc gcc-libs gcc-fortran gcc-ada gcc-objc gcc-go gcc-d"
CUDA_IGNORE="cuda cuda-tools cudnn"
KERNEL_IGNORE="linux-cachyos-headers linux-cachyos-lts-headers"

ALL_IGNORE="$GCC_IGNORE $CUDA_IGNORE $KERNEL_IGNORE"

if grep -q "^IgnorePkg" /etc/pacman.conf 2>/dev/null; then
    existing=$(grep "^IgnorePkg" /etc/pacman.conf)
    for pkg in $ALL_IGNORE; do
        if ! echo "$existing" | grep -q "$pkg"; then
            sed -i "s/^IgnorePkg.*/& $pkg/" /etc/pacman.conf
            echo "    -> Added $pkg"
        fi
    done
else
    if grep -q "^#IgnorePkg" /etc/pacman.conf; then
        sed -i "/^#IgnorePkg/a IgnorePkg   = $ALL_IGNORE" /etc/pacman.conf
    else
        sed -i "/^\[options\]/a IgnorePkg   = $ALL_IGNORE" /etc/pacman.conf
    fi
    echo "    -> Created IgnorePkg entry"
fi

# --- Hold specific GCC version if detected in snapshot -----------------------
if [[ -f /root/snapshot/system/gcc-version.txt ]]; then
    echo ""
    echo "[*] Snapshot GCC version:"
    head -1 /root/snapshot/system/gcc-version.txt
    echo "    To install this exact GCC version if needed:"
    echo "    sudo pacman -U /var/cache/pacman/pkg/gcc-<version>-x86_64.pkg.tar.zst"
fi

# --- Python/PyTorch Environment ---------------------------------------------
echo ""
echo "[*] Python Environment:"
if [[ -f /root/snapshot/pip/pip-freeze.txt ]]; then
    echo "    pip freeze: $(wc -l < /root/snapshot/pip/pip-freeze.txt) packages"
fi
echo "    For Volta/Titan V:"
echo "      pip install torch --index-url https://download.pytorch.org/whl/cu126"
echo "    (PyTorch 2.11+ cu128/cu129 drops sm_70)"

if [[ -f /root/snapshot/conda/environment.yml ]]; then
    echo "    conda env: /root/snapshot/conda/environment.yml"
fi

# --- GPU Verification -------------------------------------------------------
echo ""
echo "[*] GPU Status:"
nvidia-smi -L 2>/dev/null || echo "    nvidia-smi not available until reboot"

# --- Volta Warning ----------------------------------------------------------
echo ""
echo "=========================================="
echo "  VOLTA/TITAN V COMPATIBILITY LOCK"
echo "=========================================="
echo "  Driver:     nvidia-580xx (legacy branch)"
echo "  CUDA:       12.9 pinned (blocks 13.x)"
echo "  GCC:        PINNED (prevents DKMS breakage)"
echo "  Kernel:     PINNED (headers locked)"
echo "  PyTorch:    ONLY cu126 wheels"
echo ""
echo "  WARNING: Do NOT run 'pacman -S gcc' or kernel upgrades"
echo "           without checking DKMS compatibility first!"
echo ""
echo "  To check before upgrading:"
echo "    gcc --version"
echo "    cat /proc/version"
echo "    dkms status"
echo ""
echo "  Post-install complete. Reboot when ready."
echo "=========================================="
EOF

chmod +x "$POST"

mkdir -p "$SQUASH/usr/share/applications"
cat > "$SQUASH/usr/share/applications/cachy-post-install.desktop" << 'EOF'
[Desktop Entry]
Name=Run Volta Post-Install
Comment=Apply NVIDIA 580xx + GCC/CUDA lock for Titan V
Exec=konsole -e /usr/local/bin/cachy-post-install
Type=Application
Terminal=true
Icon=system-software-install
Categories=System;
EOF

mkdir -p "$SQUASH/home/cachy/Desktop"
cp "$SQUASH/usr/share/applications/cachy-post-install.desktop" "$SQUASH/home/cachy/Desktop/" 2>/dev/null || true
chown -R 1000:1000 "$SQUASH/home/cachy/Desktop" 2>/dev/null || true

ok "Post-install script created"

# =============================================================================
# STEP 8: RESQUASH
# =============================================================================
step "Repacking airootfs.sfs"
rm -f "$AIROOTFS"
(mksquashfs "$SQUASH" "$AIROOTFS" -comp xz -Xbcj x86 -noappend) &
spinner $! "Repacking squashfs..."

# =============================================================================
# STEP 9: REBUILD ISO (DYNAMIC BOOT DETECTION)
# =============================================================================
step "Rebuilding Bootable ISO"

NEW_ISO_NAME="cachyos-volta-$(date +%Y%m%d-%H%M).iso"
if [[ -n "$OUT_DIR" ]]; then
    mkdir -p "$OUT_DIR"
    NEW_ISO="$OUT_DIR/$NEW_ISO_NAME"
else
    NEW_ISO="$(dirname "$ISO_IN")/$NEW_ISO_NAME"
fi

XORSISO_ARGS=()

info "Analyzing boot structure..."

if [[ -f "$ISO_COPY/shellx64.efi" ]]; then
    info "Detected systemd-boot ISO (shellx64.efi)"
    XORSISO_ARGS+=(-eltorito-alt-boot -e shellx64.efi -no-emul-boot -isohybrid-gpt-basdat)
elif [[ -f "$ISO_COPY/EFI/boot/efiboot.img" || -f "$ISO_COPY/efi/boot/efiboot.img" ]]; then
    EFI_IMG=""
    for path in "$ISO_COPY/EFI/boot/efiboot.img" "$ISO_COPY/efi/boot/efiboot.img"; do
        [[ -f "$path" ]] && EFI_IMG="${path#$ISO_COPY/}" && break
    done
    info "Detected traditional EFI ISO (efiboot.img)"
    XORSISO_ARGS+=(-eltorito-alt-boot -e "$EFI_IMG" -no-emul-boot -isohybrid-gpt-basdat)
else
    warn "Searching for boot files..."
    EFI_CANDIDATES=()
    while IFS= read -r -d '' path; do
        rel="${path#$ISO_COPY/}"
        [[ "$rel" =~ memtest ]] && continue
        [[ "$rel" =~ test ]] && continue
        EFI_CANDIDATES+=("$rel")
    done < <(find "$ISO_COPY" -maxdepth 2 -type f -iname "*.efi" -print0 2>/dev/null)

    if [[ ${#EFI_CANDIDATES[@]} -gt 0 ]]; then
        EFI_IMG="${EFI_CANDIDATES[0]}"
        warn "Using EFI file: $EFI_IMG"
        XORSISO_ARGS+=(-eltorito-alt-boot -e "$EFI_IMG" -no-emul-boot -isohybrid-gpt-basdat)
    else
        error "No bootable EFI file found in ISO"
    fi
fi

if [[ -f "$ISO_COPY/isolinux/isolinux.bin" ]]; then
    XORSISO_ARGS+=(-eltorito-boot isolinux/isolinux.bin -eltorito-catalog isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table)

    ISOHDPFX=""
    for path in /usr/lib/syslinux/bios/isohdpfx.bin /usr/share/syslinux/isohdpfx.bin; do
        [[ -f "$path" ]] && ISOHDPFX="$path" && break
    done
    [[ -n "$ISOHDPFX" ]] || error "syslinux isohdpfx.bin not found"
    XORSISO_ARGS+=(-isohybrid-mbr "$ISOHDPFX")
    info "BIOS boot: isolinux"
fi

(xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock \
    -volid "CACHYOS_VOLTA" \
    "${XORSISO_ARGS[@]}" \
    -output "$NEW_ISO" "$ISO_COPY") &
spinner $! "Building ISO with xorriso..."

[[ -f "$NEW_ISO" ]] || error "ISO build failed — no output file"
ISO_SIZE=$(du -h "$NEW_ISO" | cut -f1)

# =============================================================================
# FIX: CHOWN OUTPUT TO USER
# =============================================================================
if [[ -f "$NEW_ISO" ]]; then
    USER_NAME="${SUDO_USER:-$USER}"
    USER_GROUP="$(id -gn "$USER_NAME" 2>/dev/null || echo "$USER_NAME")"
    chown "$USER_NAME:$USER_GROUP" "$NEW_ISO"
    ok "ISO ownership set to $USER_NAME:$USER_GROUP"
fi

# =============================================================================
# CLEANUP + SUMMARY
# =============================================================================
rm -rf "$WORK_DIR"

echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║              ISO MODIFICATION COMPLETE                     ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
box "Output ISO" "$NEW_ISO ($ISO_SIZE)"
echo ""
echo -e "  ${CYAN}Flash with your preferred tool:${NC}"
echo -e "    ${YELLOW}dd:${NC}      sudo dd if=\"$NEW_ISO\" of=/dev/sdX bs=4M status=progress"
echo -e "    ${YELLOW}Rufus:${NC}   Select ISO → ISO mode (not DD) → Start"
echo -e "    ${YELLOW}Ventoy:${NC}  Copy ISO to Ventoy USB partition"
echo -e "    ${YELLOW}Etcher:${NC}  Flash from file → Select ISO → Target USB"
echo ""
echo -e "  ${BOLD}After install (before reboot):${NC}"
echo -e "    Click ${YELLOW}'Run Volta Post-Install'${NC} on desktop"
echo -e "    Or: ${YELLOW}sudo /usr/local/bin/cachy-post-install${NC}"
echo ""
echo -e "  ${BOLD}Driver:${NC}  nvidia-580xx (chwd priority 9999)"
echo -e "  ${BOLD}CUDA:${NC}    12.9 pinned via IgnorePkg"
echo -e "  ${BOLD}GCC:${NC}     PINNED (prevents DKMS breakage)"
echo -e "  ${BOLD}Kernel:${NC}   PINNED (headers locked)"
echo -e "  ${BOLD}PyTorch:${NC} cu126 wheels only (last sm_70)"
echo ""
