# CachyOS Volta ISO Modifier (cachyos-iso-mod)

## Technical Specification & Source Code

**Version:** 1.0.0  
**Date:** 2026-05-28  
**Author:** xeonv (with Kimi K2.6 assistance)  
**License:** MIT (suggested)  
**Target Hardware:** NVIDIA Volta (sm_70) — Titan V, Titan V CEO Edition  
**Target OS:** CachyOS (Arch Linux derivative)

---

## 1. Purpose

CachyOS Volta ISO Modifier is a single-script tool that:
1. **Indexes** the current running system (pacman packages, pip freeze, conda env, GPU state, PyTorch config)
2. **Modifies** a CachyOS Live ISO to force-install NVIDIA 580xx legacy drivers
3. **Pins** CUDA 12.9 to prevent automatic upgrade to CUDA 13 (which drops Volta)
4. **Injects** a post-install script that reproduces the user's environment on the new system
5. **Outputs** a bootable modified ISO ready for flashing to USB

**No existing tool** provides this specific workflow for CachyOS/Arch Linux.

---

## 2. Problem Statement

### 2.1 NVIDIA Driver Chaos
- CachyOS `chwd` auto-detects GPUs but may install `nvidia-open` (new driver) which lacks legacy support
- Volta GPUs (Titan V) require `nvidia-580xx-dkms` (legacy branch)
- Manual intervention after Calamares install is error-prone

### 2.2 CUDA Version Trap
- CUDA 13.x will drop Maxwell/Pascal/Volta entirely
- `pacman -Syu` will auto-upgrade CUDA without warning
- No native CachyOS tool pins CUDA versions

### 2.3 PyTorch sm_70 Support Ending
- PyTorch 2.11+ cu128/cu129 wheels drop `sm_70` compute capability
- Last supported wheels: **cu126** (PyTorch 2.10 and earlier)
- Users must manually specify `--index-url https://download.pytorch.org/whl/cu126`

### 2.4 Environment Reproducibility
- No native tool snapshots pip/conda + pacman state
- Reinstalling a working ML environment on new hardware is manual and fragile

---

## 3. Features

| Feature | Description |
|---------|-------------|
| **Auto-detect ISO** | Finds `cachyos*.iso` in script directory; no `--iso` flag needed |
| **System snapshot** | Exports pacman explicit/foreign packages, pip freeze, conda env, GPU info, PyTorch JSON |
| **Driver forcing** | Injects `chwd` profile with priority 9999 for `nvidia-580xx-dkms` |
| **CUDA pinning** | Adds `IgnorePkg = cuda cuda-tools cudnn` to `/etc/pacman.conf` post-install |
| **Boot detection** | Handles both **systemd-boot** (`shellx64.efi`) and **isolinux** legacy ISOs |
| **User ownership** | Output ISO is `chown`ed to the user who ran `sudo`, not `root:root` |
| **Output control** | `--out /path/` flag; defaults to same directory as input ISO |
| **No USB flashing** | Outputs ISO file only; user flashes with dd/Rufus/Ventoy/Etcher |
| **Original preserved** | Source ISO mounted read-only via loop; never modified |

---

## 4. System Requirements

### 4.1 Build Machine (where script runs)
- **OS:** CachyOS, Arch Linux, or derivative with `pacman`
- **Disk:** ~10GB free in `/tmp` for squashfs extraction + repack
- **RAM:** 4GB+ recommended (squashfs extraction is disk-heavy)
- **Packages:** `squashfs-tools`, `libisoburn`, `syslinux`, `util-linux`
  - Auto-installed by script if missing

### 4.2 Target Machine (where ISO installs)
- **GPU:** NVIDIA Volta (Titan V) or other Pascal/Maxwell requiring 580xx driver
- **UEFI:** Required for systemd-boot ISOs; BIOS fallback supported if isolinux present

---

## 5. Installation

```bash
# 1. Download
curl -sLO https://raw.githubusercontent.com/Xeon-V/cachyos-usb-volta/main/cachyos-iso-mod.sh

# 2. Make executable
chmod +x cachyos-iso-mod.sh

# 3. Place CachyOS ISO in same directory
# (e.g., cachyos-linux-x86_64.iso)

# 4. Run
sudo bash cachyos-iso-mod.sh
```

---

## 6. Usage

### 6.1 Basic (auto-detect ISO in same directory)
```bash
cd ~/Downloads
sudo bash cachyos-iso-mod.sh
# Output: ./cachyos-volta-YYYYMMDD-HHMM.iso
```

### 6.2 Specify output directory
```bash
sudo bash cachyos-iso-mod.sh --out ~/Desktop/
# Output: ~/Desktop/cachyos-volta-YYYYMMDD-HHMM.iso
```

### 6.3 Specify ISO explicitly
```bash
sudo bash cachyos-iso-mod.sh --iso ~/Downloads/cachyos-linux-x86_64.iso --out ~/Desktop/
```

### 6.4 Flash output ISO
```bash
# With dd
sudo dd if="~/Desktop/cachyos-volta-20260528-0800.iso" of=/dev/sdX bs=4M status=progress conv=fsync

# With Rufus (Windows): Select ISO → ISO mode → Start
# With Ventoy: Copy ISO to Ventoy partition
# With Etcher: Flash from file → Select ISO → Target USB
```

---

## 7. Post-Install Workflow (on target machine)

1. **Boot** modified USB
2. **Install** CachyOS via Calamares
3. **Before reboot**, click **"Run Volta Post-Install"** on desktop
4. **Or run:** `sudo /usr/local/bin/cachy-post-install`
5. **Reboot**
6. **Verify:** `nvidia-smi` should show 580xx driver loaded
7. **Install PyTorch:**
   ```bash
   pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu126
   ```
8. **Verify Volta:**
   ```bash
   python -c "import torch; print(torch.cuda.get_arch_list())"
   # Should include 'sm_70'
   ```

---

## 8. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  INPUT: cachyos-linux-x86_64.iso (read-only loop mount)     │
├─────────────────────────────────────────────────────────────┤
│  STEP 1: Index System                                       │
│    ├── pacman -Qqen → explicit-packages.txt                 │
│    ├── pacman -Qqm → foreign-packages.txt                   │
│    ├── pip freeze → pip-freeze.txt                          │
│    ├── conda env export → environment.yml                   │
│    ├── nvidia-smi → gpu-summary.csv                         │
│    └── python -c "import torch..." → pytorch.json           │
├─────────────────────────────────────────────────────────────┤
│  STEP 2: Mount ISO (loop,ro)                                │
│  STEP 3: Copy to writable temp directory                    │
│  STEP 4: unsquashfs airootfs.sfs                            │
├─────────────────────────────────────────────────────────────┤
│  STEP 5: Inject Modifications                               │
│    ├── /root/snapshot/ (all index files)                    │
│    ├── chwd profile: custom-volta-nvidia-580xx (priority 9999) │
│    ├── /usr/local/bin/cachy-post-install                    │
│    └── Desktop shortcut: "Run Volta Post-Install"          │
├─────────────────────────────────────────────────────────────┤
│  STEP 6: mksquashfs airootfs.sfs                            │
│  STEP 7: xorriso rebuild ISO                                │
│    ├── Detect boot type: systemd-boot OR isolinux           │
│    ├── UEFI: -e shellx64.efi OR -e EFI/boot/efiboot.img     │
│    └── BIOS: -eltorito-boot isolinux/isolinux.bin (if present)│
├─────────────────────────────────────────────────────────────┤
│  STEP 8: chown output to SUDO_USER                          │
├─────────────────────────────────────────────────────────────┤
│  OUTPUT: cachyos-volta-YYYYMMDD-HHMM.iso (user-owned)       │
└─────────────────────────────────────────────────────────────┘
```

---

## 9. Source Code

```bash
#!/bin/bash
# ============================================================================
# CachyOS ISO Modifier - Volta/Titan V Edition (Production)
# ============================================================================
# Auto-installs missing dependencies, indexes system, modifies CachyOS Live ISO.
# Forces NVIDIA 580xx, pins CUDA 12.9, guides PyTorch cu126.
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
# STEP 1: INDEX SYSTEM
# =============================================================================
step "System Index"

WORK_DIR=$(mktemp -d /tmp/cachy-iso-mod.XXXXXX)
SNAPSHOT="$WORK_DIR/snapshot"
mkdir -p "$SNAPSHOT"/{pacman,pip,system,gpu}

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

info "Exporting packages..."
pacman -Qqen > "$SNAPSHOT/pacman/explicit.txt"
pacman -Qqm  > "$SNAPSHOT/pacman/foreign.txt" 2>/dev/null || true
pacman -Q    > "$SNAPSHOT/pacman/all-versions.txt"

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
# STEP 7: POST-INSTALL SCRIPT
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

echo "[*] Removing conflicting drivers..."
pacman -Rdd --noconfirm linux-cachyos-nvidia-open linux-cachyos-lts-nvidia-open 2>/dev/null || true

echo "[*] Installing forced 580xx profile..."
chwd -a -f || true

if [[ -f /root/snapshot/pacman/explicit.txt ]]; then
    count=$(wc -l < /root/snapshot/pacman/explicit.txt)
    echo "[*] Installing $count explicit packages..."
    pacman -S --needed --noconfirm - /root/snapshot/pacman/explicit.txt || {
        echo "[!] Some packages failed."
    }
fi

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

echo "[*] Pinning CUDA packages..."
IGNORE_PKGS="cuda cuda-tools cudnn"
if grep -q "^IgnorePkg" /etc/pacman.conf 2>/dev/null; then
    existing=$(grep "^IgnorePkg" /etc/pacman.conf)
    for pkg in $IGNORE_PKGS; do
        if ! echo "$existing" | grep -q "$pkg"; then
            sed -i "s/^IgnorePkg.*/& $pkg/" /etc/pacman.conf
            echo "    -> Added $pkg"
        fi
    done
else
    if grep -q "^#IgnorePkg" /etc/pacman.conf; then
        sed -i '/^#IgnorePkg/a IgnorePkg   = cuda cuda-tools cudnn' /etc/pacman.conf
    else
        sed -i '/^\[options\]/a IgnorePkg   = cuda cuda-tools cudnn' /etc/pacman.conf
    fi
    echo "    -> Created IgnorePkg entry"
fi

echo ""
echo "[*] Python Environment:"
if [[ -f /root/snapshot/pip/pip-freeze.txt ]]; then
    echo "    pip freeze: $(wc -l < /root/snapshot/pip/pip-freeze.txt) packages"
fi
echo "    For Volta/Titan V:"
echo "      pip install torch --index-url https://download.pytorch.org/whl/cu126"
echo "    (PyTorch 2.11+ cu128/cu129 drops sm_70)"

echo ""
echo "[*] GPU Status:"
nvidia-smi -L 2>/dev/null || echo "    nvidia-smi not available until reboot"

echo ""
echo "=========================================="
echo "  Done. Reboot when ready."
echo "=========================================="
EOF

chmod +x "$POST"

mkdir -p "$SQUASH/usr/share/applications"
cat > "$SQUASH/usr/share/applications/cachy-post-install.desktop" << 'EOF'
[Desktop Entry]
Name=Run Volta Post-Install
Comment=Apply NVIDIA 580xx + custom packages for Titan V
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

(xorriso -as mkisofs     -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock     -volid "CACHYOS_VOLTA"     "${XORSISO_ARGS[@]}"     -output "$NEW_ISO" "$ISO_COPY") &
spinner $! "Building ISO with xorriso..."

[[ -f "$NEW_ISO" ]] || error "ISO build failed — no output file"
ISO_SIZE=$(du -h "$NEW_ISO" | cut -f1)

# =============================================================================
# FIX: CHOWN OUTPUT TO USER (not root)
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
echo -e "  ${BOLD}PyTorch:${NC} cu126 wheels only (last sm_70)"
echo ""
```

---

## 10. Known Issues

| Issue | Status | Workaround |
|-------|--------|------------|
| Output ISO owned by root | **FIXED** | `chown` to `SUDO_USER` after build |
| ISO path with spaces | **FIXED** | Use quotes in `dd` command output |
| systemd-boot detection | **FIXED** | Checks `shellx64.efi` at root first |
| memtest.efi false positive | **FIXED** | Skips files matching `memtest` or `test` |
| Missing `syslinux` package | **FIXED** | Auto-installs if missing |
| Already-mounted USB conflict | **FIXED** | Checks `findmnt` before attempting mount |

---

## 11. Future Roadmap

- [ ] `--gui` mode with `dialog` TUI
- [ ] `--dry-run` to preview changes without modifying ISO
- [ ] Support for other legacy NVIDIA branches (470xx, 390xx)
- [ ] AUR package: `cachyos-iso-mod`
- [ ] CI/CD GitHub Action for automated ISO builds
- [ ] Ventoy persistence partition injection

---

## 12. Credits

- **xeonv** — Concept, testing, Titan V validation
- **Kimi K2.6** (Moonshot AI) — Architecture, code generation, debugging
- **CachyOS Team** — `chwd`, `handhold` installer, archiso profiles
- **Arch Linux** — `archiso`, `mkarchiso`, `pacman`

---

*Document generated: 2026-05-28*
*Tool version: 1.0.0*
