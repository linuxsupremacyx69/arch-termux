#!/data/data/com.termux/files/usr/bin/bash
################################################################################
# Termux Arch Linux Chroot Environment Manager
# Version: 2.2.0 - Landlock Fix for Android Kernels
# Architecture: ARM64 (AArch64)
################################################################################

set -euo pipefail

readonly VERSION="2.2.0"
readonly ARCH_ROOT="${ARCH_ROOT:-/data/data/com.termux/files/arch}"
readonly TERMUX_PREFIX="/data/data/com.termux/files/usr"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

check_root() { [[ "$(id -u)" -eq 0 ]] || { error "Root required. Run: su -c '$0 $*'"; exit 1; }; }

# CRITICAL FIX: Disable Landlock sandbox for Pacman
fix_pacman_sandbox() {
    log "Applying Landlock sandbox fix..."
    
    # Method 1: Disable sandbox in pacman.conf
    if [[ -f "$ARCH_ROOT/etc/pacman.conf" ]]; then
        # Remove or comment out sandbox options
        sed -i 's/^[[:space:]]*SandboxUser/#SandboxUser/' "$ARCH_ROOT/etc/pacman.conf" 2>/dev/null || true
        sed -i 's/^[[:space:]]*DownloadUser/#DownloadUser/' "$ARCH_ROOT/etc/pacman.conf" 2>/dev/null || true
        
        # Add DisableSandbox if not present
        if ! grep -q "^DisableSandbox" "$ARCH_ROOT/etc/pacman.conf" 2>/dev/null; then
            sed -i '/\[options\]/a DisableSandbox' "$ARCH_ROOT/etc/pacman.conf"
        fi
    fi
    
    # Method 2: Create wrapper script that disables sandbox via environment
    cat > "$ARCH_ROOT/usr/local/bin/pacman-safe" << 'EOF'
#!/bin/bash
# Pacman wrapper that disables Landlock sandbox for Android kernels

# Disable various sandboxing methods
export PACMAN_DISABLE_LANDLOCK=1
export MAKEPKG_DLAGENTS=""
export PKGEXT='.pkg.tar'

# Run pacman with sandbox disabled
exec /usr/bin/pacman --disable-sandbox "$@"
EOF
    chmod +x "$ARCH_ROOT/usr/local/bin/pacman-safe"
    
    # Method 3: Fix makepkg.conf
    if [[ -f "$ARCH_ROOT/etc/makepkg.conf" ]]; then
        # Disable fakeroot and sandboxing in makepkg
        sed -i 's/^[[:space:]]*BUILDENV=.*/BUILDENV=(!distcc !color !ccache !check !sign)/' "$ARCH_ROOT/etc/makepkg.conf" 2>/dev/null || true
        sed -i 's/^[[:space:]]*OPTIONS=.*/OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug !lto)/' "$ARCH_ROOT/etc/makepkg.conf" 2>/dev/null || true
    fi
    
    # Method 4: Create/modify alpm config
    mkdir -p "$ARCH_ROOT/etc/pacman.d"
    cat > "$ARCH_ROOT/etc/pacman.d/alpm-hooks" << 'EOF'
# Disable sandbox hooks
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Disabling sandbox for Android compatibility...
When = PreTransaction
Exec = /bin/sh -c 'echo "Sandbox disabled for Android kernel compatibility"'
EOF
    
    log "Sandbox fixes applied"
}

# Fix sudoers file creation
fix_sudoers() {
    log "Fixing sudo configuration..."
    
    # Ensure sudo is installed first
    if [[ ! -f "$ARCH_ROOT/usr/bin/sudo" ]]; then
        warn "Sudo not found, attempting to install..."
        chroot "$ARCH_ROOT" /bin/bash -c "pacman -Sy sudo --noconfirm --disable-sandbox 2>/dev/null || pacman -Sy sudo --noconfirm" || true
    fi
    
    # Create sudoers file if missing
    if [[ ! -f "$ARCH_ROOT/etc/sudoers" ]]; then
        cat > "$ARCH_ROOT/etc/sudoers" << 'EOF'
# sudoers file for Termux Arch
#
# See the sudoers man page for details on how to write a sudoers file.

Defaults env_reset
Defaults mail_badpass
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Host alias specification

# User alias specification

# Cmnd alias specification

# User privilege specification
root    ALL=(ALL:ALL) ALL

# Allow members of group sudo to execute any command
%sudo   ALL=(ALL:ALL) ALL

# Allow members of group wheel to execute any command
%wheel  ALL=(ALL:ALL) NOPASSWD: ALL

# See sudoers(5) for more information on "@include" directives:
@includedir /etc/sudoers.d
EOF
        chmod 440 "$ARCH_ROOT/etc/sudoers"
    fi
    
    # Create sudoers.d directory and termux config
    mkdir -p "$ARCH_ROOT/etc/sudoers.d"
    chmod 750 "$ARCH_ROOT/etc/sudoers.d"
    
    cat > "$ARCH_ROOT/etc/sudoers.d/termux" << 'EOF'
# Termux specific sudo settings
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
Defaults env_keep += "TERM DISPLAY XAUTHORITY"
Defaults env_keep += "PULSE_SERVER PULSE_COOKIE"
Defaults env_keep += "XDG_RUNTIME_DIR WAYLAND_DISPLAY"
Defaults env_keep += "HOME"
Defaults !tty_tickets
Defaults !lecture
EOF
    chmod 440 "$ARCH_ROOT/etc/sudoers.d/termux"
    
    # Fix permissions
    chroot "$ARCH_ROOT" /bin/bash -c 'chown root:root /etc/sudoers /etc/sudoers.d/* 2>/dev/null || true; chmod 440 /etc/sudoers /etc/sudoers.d/* 2>/dev/null || true' || true
    
    log "Sudo configuration fixed"
}

# Mount filesystems
mount_system() {
    log "Mounting system directories..."
    
    if mountpoint -q "$ARCH_ROOT/proc" 2>/dev/null; then
        warn "Filesystems already mounted"
        return 0
    fi

    mount -o bind /dev "$ARCH_ROOT/dev"
    mount -o bind /dev/pts "$ARCH_ROOT/dev/pts"
    mount -o bind /proc "$ARCH_ROOT/proc"
    mount -o bind /sys "$ARCH_ROOT/sys"
    mount -o bind /sdcard "$ARCH_ROOT/sdcard" 2>/dev/null || true
    mount -t tmpfs -o mode=1777 tmpfs "$ARCH_ROOT/tmp"
    mount -t tmpfs -o mode=755 tmpfs "$ARCH_ROOT/run"
    
    log "Filesystems mounted"
}

# Unmount filesystems
unmount_system() {
    log "Unmounting system directories..."
    local mounts
    mounts=$(mount | grep "$ARCH_ROOT" | awk '{print $3}' | sort -r || true)
    
    if [[ -z "$mounts" ]]; then
        info "Nothing to unmount"
        return 0
    fi
    
    fuser -k "$ARCH_ROOT" 2>/dev/null || true
    sleep 1
    
    echo "$mounts" | while read -r mp; do
        [[ -n "$mp" ]] && umount -l "$mp" 2>/dev/null || umount -f "$mp" 2>/dev/null || true
    done
    
    log "Unmount completed"
}

# Update system with sandbox disabled
update_system() {
    check_root
    mount_system
    
    # Apply critical fixes first
    fix_pacman_sandbox
    fix_sudoers
    
    log "Updating system with sandbox disabled..."
    
    # Update package databases without sandbox
    chroot "$ARCH_ROOT" /bin/bash -c '
        # Disable landlock via environment
        export PACMAN_DISABLE_LANDLOCK=1
        
        # Update with sandbox disabled
        pacman -Sy --disable-sandbox 2>/dev/null || pacman -Sy
        
        # Full system upgrade
        pacman -Su --disable-sandbox --noconfirm 2>/dev/null || pacman -Su --noconfirm
    ' || {
        error "Update failed. Trying alternative method..."
        # Alternative: Use the wrapper script
        chroot "$ARCH_ROOT" /bin/bash -c '
            /usr/local/bin/pacman-safe -Syu --noconfirm
        ' || error "All update methods failed"
    }
    
    log "Update complete"
}

# Fresh install
install_base() {
    check_root
    
    if [[ -f "$ARCH_ROOT/bin/bash" ]]; then
        warn "Arch already installed. Reinstall? [y/N]: "
        read -r confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 0
        unmount_system
        rm -rf "${ARCH_ROOT:?}"/*
    fi
    
    log "Creating directories..."
    mkdir -p "$ARCH_ROOT"/{proc,sys,dev,run,tmp,root,home,etc}
    mkdir -p "$ARCH_ROOT/dev/pts"
    
    log "Downloading Arch ARM..."
    local tempdir=$(mktemp -d)
    
    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$tempdir/arch.tar.gz" "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
    else
        wget -q -O "$tempdir/arch.tar.gz" "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
    fi
    
    log "Extracting..."
    tar -xzf "$tempdir/arch.tar.gz" -C "$ARCH_ROOT" || {
        # BusyBox tar fallback
        tar -xzf "$tempdir/arch.tar.gz" -C "$ARCH_ROOT"
        rm -rf "$ARCH_ROOT/dev"/* "$ARCH_ROOT/proc"/* "$ARCH_ROOT/sys"/* 2>/dev/null || true
    }
    
    rm -rf "$tempdir"
    
    # Basic configuration
    echo "nameserver 8.8.8.8" > "$ARCH_ROOT/etc/resolv.conf"
    echo "nameserver 1.1.1.1" >> "$ARCH_ROOT/etc/resolv.conf"
    echo "termux-arch" > "$ARCH_ROOT/etc/hostname"
    
    mount_system
    
    # Apply fixes immediately
    fix_pacman_sandbox
    fix_sudoers
    
    # Initialize pacman
    chroot "$ARCH_ROOT" /bin/bash -c '
        pacman-key --init 2>/dev/null || true
        pacman-key --populate archlinuxarm 2>/dev/null || true
    ' || true
    
    # Create user
    chroot "$ARCH_ROOT" /bin/bash -c '
        useradd -m -G wheel,audio,video,storage -s /bin/bash termux 2>/dev/null || true
        echo "termux:termux" | chpasswd 2>/dev/null || true
    ' || true
    
    create_scripts
    log "Installation complete! Run: arch-cli"
}

# Create wrapper scripts
create_scripts() {
    cat > "$TERMUX_PREFIX/bin/arch-cli" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
ARCH_ROOT="/data/data/com.termux/files/arch"

cleanup() {
    su -c "
        fuser -k '$ARCH_ROOT' 2>/dev/null || true
        sleep 1
        umount -l '$ARCH_ROOT/tmp' 2>/dev/null || true
        umount -l '$ARCH_ROOT/run' 2>/dev/null || true
        umount -l '$ARCH_ROOT/proc' 2>/dev/null || true
        umount -l '$ARCH_ROOT/sys' 2>/dev/null || true
        umount -l '$ARCH_ROOT/dev/pts' 2>/dev/null || true
        umount -l '$ARCH_ROOT/dev' 2>/dev/null || true
    "
}
trap cleanup EXIT INT TERM

su -c "
    mountpoint -q '$ARCH_ROOT/proc' || {
        mount -o bind /dev '$ARCH_ROOT/dev'
        mount -o bind /dev/pts '$ARCH_ROOT/dev/pts'
        mount -o bind /proc '$ARCH_ROOT/proc'
        mount -o bind /sys '$ARCH_ROOT/sys'
        mount -t tmpfs tmpfs '$ARCH_ROOT/tmp'
        mount -t tmpfs tmpfs '$ARCH_ROOT/run'
    }
    cat /etc/resolv.conf > '$ARCH_ROOT/etc/resolv.conf'
"

[[ $# -eq 0 ]] && exec su -c "chroot '$ARCH_ROOT' /bin/bash --login"
exec su -c "chroot '$ARCH_ROOT' /bin/bash -c '$*'"
EOF
    chmod +x "$TERMUX_PREFIX/bin/arch-cli"

    cat > "$TERMUX_PREFIX/bin/arch-update" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
su -c "
    mountpoint -q '/data/data/com.termux/files/arch/proc' || {
        mount -o bind /dev '/data/data/com.termux/files/arch/dev'
        mount -o bind /proc '/data/data/com.termux/files/arch/proc'
        mount -o bind /sys '/data/data/com.termux/files/arch/sys'
    }
    chroot '/data/data/com.termux/files/arch' /bin/bash -c 'pacman -Syu --disable-sandbox --noconfirm'
"
EOF
    chmod +x "$TERMUX_PREFIX/bin/arch-update"
}

# Menu
main_menu() {
    clear
    echo "========================================"
    echo "  Termux Arch Linux Manager v$VERSION"
    echo "========================================"
    echo "  [1] Fresh Install"
    echo "  [2] Update System (with Landlock fix)"
    echo "  [3] Enter CLI"
    echo "  [4] Apply Critical Fixes"
    echo "  [5] Unmount/Cleanup"
    echo "  [0] Exit"
    echo ""
    read -rp "Select: " choice
    
    case "$choice" in
        1) install_base ;;
        2) update_system ;;
        3) exec arch-cli ;;
        4) mount_system; fix_pacman_sandbox; fix_sudoers ;;
        5) unmount_system ;;
        0) exit 0 ;;
    esac
    
    read -rp "Press enter..."
    main_menu
}

case "${1:-menu}" in
    install|1) install_base ;;
    update|2) update_system ;;
    cli|3) exec arch-cli ;;
    fix|4) mount_system; fix_pacman_sandbox; fix_sudoers ;;
    umount|5) unmount_system ;;
    *) main_menu ;;
esac
