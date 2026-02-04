#!/data/data/com.termux/files/usr/bin/bash
################################################################################
# Termux Arch Linux Chroot Environment Manager
# Version: 2.1.0 - BusyBox Compatible
# Architecture: ARM64 (AArch64)
# Features: Native GUI (KDE Plasma), Backup/Restore, Automation, Fixes
################################################################################

set -euo pipefail

# Configuration
readonly PROG_NAME="arch-termux"
readonly VERSION="2.1.0"
readonly ARCH_ROOT="${ARCH_ROOT:-/data/data/com.termux/files/arch}"
readonly ARCH_IMAGE_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
readonly TERMUX_HOME="/data/data/com.termux/files/home"
readonly TERMUX_PREFIX="/data/data/com.termux/files/usr"

# Colors
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m'

# Logging
log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# BusyBox compatible download function
download_file() {
    local url="$1"
    local output="$2"
    
    # Try different downloaders in order of preference
    if command -v curl >/dev/null 2>&1; then
        # curl is available (best option)
        curl -L -o "$output" --progress-bar "$url"
    elif wget --help 2>&1 | grep -q "\-\-show-progress"; then
        # GNU wget with progress
        wget --show-progress -O "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        # BusyBox wget (no progress bar, silent)
        log "Downloading (BusyBox wget - no progress bar)..."
        wget -q -O "$output" "$url" || return 1
    else
        error "No download tool found (install curl or wget)"
        return 1
    fi
}

# Check root
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        error "Root access required. Run: su -c '$0 $*'"
        exit 1
    fi
}

# Check architecture
check_arch() {
    local arch
    arch=$(uname -m)
    if [[ "$arch" != "aarch64" ]]; then
        error "Unsupported architecture: $arch. Requires ARM64 (aarch64)."
        exit 1
    fi
    log "Architecture verified: ARM64 ✓"
}

# Create necessary directories
setup_directories() {
    log "Setting up directory structure..."
    mkdir -p "$ARCH_ROOT"/{proc,sys,dev,run,tmp,root,boot,home,etc,usr,var}
    mkdir -p "$ARCH_ROOT/dev/pts" "$ARCH_ROOT/dev/shm"
    chmod 755 "$ARCH_ROOT"
    chmod 1777 "$ARCH_ROOT/tmp"
    chmod 755 "$ARCH_ROOT/dev/pts"
}

# Mount essential filesystems
mount_system() {
    log "Mounting system directories..."
    
    # Check if already mounted
    if mountpoint -q "$ARCH_ROOT/proc" 2>/dev/null; then
        warn "Filesystems already mounted"
        return 0
    fi

    # Bind mounts
    mount -o bind /dev "$ARCH_ROOT/dev"
    mount -o bind /dev/pts "$ARCH_ROOT/dev/pts"
    mount -o bind /proc "$ARCH_ROOT/proc"
    mount -o bind /sys "$ARCH_ROOT/sys"
    mount -o bind /sdcard "$ARCH_ROOT/sdcard" 2>/dev/null || true
    
    # Tempfs mounts
    mount -t tmpfs -o mode=1777,strictatime,nodev,nosuid,tmpfs-size=50% tmpfs "$ARCH_ROOT/tmp"
    mount -t tmpfs -o mode=755,nodev,nosuid,tmpfs-size=32m tmpfs "$ARCH_ROOT/run"
    
    # Create necessary device nodes if missing
    [[ -e "$ARCH_ROOT/dev/null" ]] || mknod -m 666 "$ARCH_ROOT/dev/null" c 1 3 2>/dev/null || true
    
    log "Filesystems mounted successfully"
}

# Unmount everything cleanly
unmount_system() {
    log "Unmounting system directories..."
    
    local mounts
    mounts=$(mount | grep "$ARCH_ROOT" | awk '{print $3}' | sort -r || true)
    
    if [[ -z "$mounts" ]]; then
        info "Nothing to unmount"
        return 0
    fi
    
    # Kill any remaining processes in chroot first
    fuser -k "$ARCH_ROOT" 2>/dev/null || true
    sleep 1
    
    # Unmount in reverse order
    echo "$mounts" | while read -r mount_point; do
        if [[ -n "$mount_point" ]]; then
            umount -l "$mount_point" 2>/dev/null || umount -f "$mount_point" 2>/dev/null || true
        fi
    done
    
    # Final cleanup
    umount -l "$ARCH_ROOT" 2>/dev/null || true
    
    log "Unmount completed"
}

# Download and extract Arch Linux ARM
install_base() {
    check_root
    check_arch
    
    if [[ -f "$ARCH_ROOT/bin/bash" ]]; then
        warn "Arch Linux appears to be already installed at $ARCH_ROOT"
        read -rp "Reinstall? This will DELETE existing data! [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 0
        unmount_system
        rm -rf "${ARCH_ROOT:?}"/*
    fi
    
    setup_directories
    
    local temp_dir
    temp_dir=$(mktemp -d)
    local tarball="$temp_dir/arch.tar.gz"
    
    log "Downloading Arch Linux ARM..."
    log "URL: $ARCH_IMAGE_URL"
    
    if ! download_file "$ARCH_IMAGE_URL" "$tarball"; then
        error "Download failed"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    log "Download complete: $(ls -lh "$tarball" | awk '{print $5}')"
    log "Extracting to $ARCH_ROOT..."
    
    # BusyBox compatible extraction (no --exclude support in some versions)
    if tar --help 2>&1 | grep -q "\-\-exclude"; then
        # GNU tar
        tar -xzf "$tarball" -C "$ARCH_ROOT" --exclude='./dev/*' --exclude='./proc/*' --exclude='./sys/*'
    else
        # BusyBox tar - extract then clean
        tar -xzf "$tarball" -C "$ARCH_ROOT"
        # Clean up virtual filesystems
        rm -rf "$ARCH_ROOT/dev"/* "$ARCH_ROOT/proc"/* "$ARCH_ROOT/sys"/* 2>/dev/null || true
    fi
    
    rm -rf "$temp_dir"
    
    # Create essential files
    touch "$ARCH_ROOT/etc/resolv.conf"
    
    mount_system
    configure_system
    create_scripts
    
    log "Installation complete! Use: $TERMUX_PREFIX/bin/arch-chroot"
}

# Configure the chroot environment
configure_system() {
    log "Configuring system..."
    
    # DNS configuration
    cat > "$ARCH_ROOT/etc/resolv.conf" << 'EOF'
# Generated by Termux Arch Manager
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
nameserver 2606:4700:4700::1111
EOF
    
    # Locale configuration
    cat > "$ARCH_ROOT/etc/locale.gen" << 'EOF'
en_US.UTF-8 UTF-8
C.UTF-8 UTF-8
EOF
    
    # Sudo configuration - passwordless for wheel group
    cat > "$ARCH_ROOT/etc/sudoers.d/termux" << 'EOF'
# Allow wheel group to execute any command without password
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
# Keep environment variables
Defaults env_keep += "TERM DISPLAY XAUTHORITY"
Defaults env_keep += "PULSE_SERVER PULSE_COOKIE"
Defaults env_keep += "XDG_RUNTIME_DIR WAYLAND_DISPLAY"
EOF
    chmod 440 "$ARCH_ROOT/etc/sudoers.d/termux"
    
    # Fix DNS and networking in chroot
    cat > "$ARCH_ROOT/etc/profile.d/termux-fixes.sh" << 'EOF'
#!/bin/bash
# Termux-specific fixes

# DNS fix - ensure resolv.conf is writable
if [[ ! -w /etc/resolv.conf ]]; then
    mount --bind /etc/resolv.conf /etc/resolv.conf 2>/dev/null || true
fi

# Fix for Android kernel limitations
ulimit -n 4096 2>/dev/null || true

# Set proper TERM
export TERM="${TERM:-xterm-256color}"

# X11/Wayland environment
export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"
[[ -d "$XDG_RUNTIME_DIR" ]] || mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
EOF
    chmod +x "$ARCH_ROOT/etc/profile.d/termux-fixes.sh"
    
    # Pacman configuration optimizations
    if [[ -f "$ARCH_ROOT/etc/pacman.conf" ]]; then
        sed -i 's/#Color/Color/' "$ARCH_ROOT/etc/pacman.conf" 2>/dev/null || true
        sed -i 's/#ParallelDownloads = 5/ParallelDownloads = 5/' "$ARCH_ROOT/etc/pacman.conf" 2>/dev/null || true
    fi
    
    if [[ -f "$ARCH_ROOT/etc/makepkg.conf" ]]; then
        sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j$(nproc)"/' "$ARCH_ROOT/etc/makepkg.conf" 2>/dev/null || true
    fi
    
    # Initialize pacman keyring in chroot
    log "Initializing pacman keyring..."
    chroot "$ARCH_ROOT" /bin/bash -c '
        pacman-key --init 2>/dev/null || true
        pacman-key --populate archlinuxarm 2>/dev/null || true
        pacman -Sy archlinux-keyring --noconfirm 2>/dev/null || true
    ' || warn "Keyring initialization may need manual completion"
    
    # Create termux user
    log "Creating user environment..."
    chroot "$ARCH_ROOT" /bin/bash -c '
        useradd -m -G wheel,audio,video,storage,power -s /bin/bash termux 2>/dev/null || true
        echo "termux:termux" | chpasswd 2>/dev/null || true
    '
    
    # Hostname
    echo "termux-arch" > "$ARCH_ROOT/etc/hostname"
    
    # Hosts file
    cat > "$ARCH_ROOT/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   termux-arch
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF
    
    log "System configuration complete"
}

# Install KDE Plasma and GUI components
install_gui() {
    check_root
    mount_system
    
    log "Installing KDE Plasma Desktop Environment..."
    log "This may take 30-60 minutes depending on connection speed..."
    
    # Update system first
    chroot "$ARCH_ROOT" /bin/bash -c 'pacman -Syu --noconfirm' || true
    
    # Install KDE Plasma and essential apps
    local packages="plasma-meta plasma-workspace plasma-desktop sddm xorg-server xorg-xinit dolphin konsole kate systemsettings5 network-manager-applet pulseaudio pulseaudio-alsa pavucontrol noto-fonts noto-fonts-cjk ttf-dejavu breeze-gtk kde-gtk-config wget curl git vim nano htop base-devel cmake xorg-xauth xorg-xhost"
    
    chroot "$ARCH_ROOT" /bin/bash -c "
        pacman -S --needed --noconfirm $packages 2>&1 || {
            echo 'Some packages failed, retrying individually...'
            for pkg in $packages; do
                pacman -S --needed --noconfirm \$pkg 2>/dev/null || echo \"Failed: \$pkg\"
            done
        }
    "
    
    # Enable services
    chroot "$ARCH_ROOT" /bin/bash -c '
        systemctl enable sddm 2>/dev/null || true
        systemctl enable NetworkManager 2>/dev/null || true
    ' || true
    
    # Configure SDDM for mobile/touch
    mkdir -p "$ARCH_ROOT/etc/sddm.conf.d"
    cat > "$ARCH_ROOT/etc/sddm.conf.d/termux.conf" << 'EOF'
[General]
DisplayServer=x11
GreeterEnvironment=QT_QPA_PLATFORM=xcb

[X11]
ServerPath=/usr/bin/X
ServerArguments=-nolisten tcp -dpi 320
EOF
    
    # Create GUI startup script inside chroot
    cat > "$ARCH_ROOT/usr/local/bin/start-gui" << 'EOF'
#!/bin/bash
# KDE Plasma startup for Termux-X11

export DISPLAY="${DISPLAY:-:0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-$(id -u)}"
export QT_QPA_PLATFORM=xcb
export QT_QPA_PLATFORMTHEME=gtk2
export GDK_BACKEND=x11

# Ensure runtime directory exists
[[ -d "$XDG_RUNTIME_DIR" ]] || mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

# Start dbus if not running
if [[ -z "$DBUS_SESSION_BUS_ADDRESS" ]]; then
    eval $(dbus-launch --sh-syntax)
fi

# Start Plasma
exec startplasma-x11
EOF
    chmod +x "$ARCH_ROOT/usr/local/bin/start-gui"
    
    # Create termux-x11 integration
    cat > "$ARCH_ROOT/usr/local/bin/termux-x11-bridge" << 'EOF'
#!/bin/bash
# Bridge between Termux-X11 and Arch chroot

# Wait for X11 socket
for i in $(seq 1 30); do
    if [[ -S "/tmp/.X11-unix/X${DISPLAY#*:}" ]] || [[ -S "/data/data/com.termux/files/usr/tmp/.X11-unix/X${DISPLAY#*:}" ]]; then
        break
    fi
    sleep 1
done

# Link Termux X11 socket if needed
if [[ -S "/data/data/com.termux/files/usr/tmp/.X11-unix/X${DISPLAY#*:}" ]]; then
    mkdir -p /tmp/.X11-unix
    ln -sf "/data/data/com.termux/files/usr/tmp/.X11-unix/X${DISPLAY#*:}" "/tmp/.X11-unix/X${DISPLAY#*:}" 2>/dev/null || true
fi

# Set up pulseaudio if available
if [[ -S "/data/data/com.termux/files/usr/tmp/pulse-$(id -u)/native" ]]; then
    export PULSE_SERVER="unix:/data/data/com.termux/files/usr/tmp/pulse-$(id -u)/native"
fi

exec "$@"
EOF
    chmod +x "$ARCH_ROOT/usr/local/bin/termux-x11-bridge"
    
    log "GUI installation complete"
    info "Start X11 server in Termux first: termux-x11 :0"
}

# Create wrapper scripts
create_scripts() {
    log "Creating wrapper scripts..."
    
    # Main chroot entry script
    cat > "$TERMUX_PREFIX/bin/arch-chroot" << EOF
#!/data/data/com.termux/files/usr/bin/bash
# Arch Linux Chroot Wrapper

ARCH_ROOT="$ARCH_ROOT"

# Auto-mount if needed
if ! mountpoint -q "\$ARCH_ROOT/proc" 2>/dev/null; then
    su -c "mount -o bind /dev '\$ARCH_ROOT/dev'"
    su -c "mount -o bind /dev/pts '\$ARCH_ROOT/dev/pts'"
    su -c "mount -o bind /proc '\$ARCH_ROOT/proc'"
    su -c "mount -o bind /sys '\$ARCH_ROOT/sys'"
    su -c "mount -t tmpfs tmpfs '\$ARCH_ROOT/tmp'"
fi

# Fix DNS
cat /etc/resolv.conf > "\$ARCH_ROOT/etc/resolv.conf" 2>/dev/null || true

# Enter chroot
exec su -c "chroot '\$ARCH_ROOT' /bin/bash --login"
EOF
    chmod +x "$TERMUX_PREFIX/bin/arch-chroot"
    
    # GUI startup script
    cat > "$TERMUX_PREFIX/bin/arch-gui" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Start KDE Plasma in Termux-X11

ARCH_ROOT="/data/data/com.termux/files/arch"
TERMUX_X11_PID=""

cleanup() {
    echo "Shutting down GUI..."
    [[ -n "$TERMUX_X11_PID" ]] && kill "$TERMUX_X11_PID" 2>/dev/null || true
    su -c "umount -l '$ARCH_ROOT/proc' '$ARCH_ROOT/sys' '$ARCH_ROOT/dev/pts' '$ARCH_ROOT/dev' '$ARCH_ROOT/tmp' 2>/dev/null || true"
    exit 0
}

trap cleanup EXIT INT TERM

# Check for termux-x11
if ! command -v termux-x11 >/dev/null 2>&1; then
    echo "Error: termux-x11 not found. Install it first:"
    echo "pkg install termux-x11-nightly"
    exit 1
fi

# Start X11 server
termux-x11 :0 -dpi 320 &
TERMUX_X11_PID=$!
sleep 2

# Ensure mounts
su -c "
    mountpoint -q '$ARCH_ROOT/proc' || {
        mount -o bind /dev '$ARCH_ROOT/dev'
        mount -o bind /dev/pts '$ARCH_ROOT/dev/pts'
        mount -o bind /proc '$ARCH_ROOT/proc'
        mount -o bind /sys '$ARCH_ROOT/sys'
        mount -t tmpfs tmpfs '$ARCH_ROOT/tmp'
    }
"

# Fix permissions for X11
su -c "chmod 777 /data/data/com.termux/files/usr/tmp/.X11-unix 2>/dev/null || true"

# Start KDE as termux user
exec su -c "chroot '$ARCH_ROOT' su - termux -c 'export DISPLAY=:0; export PULSE_SERVER=unix:/data/data/com.termux/files/usr/tmp/pulse-\$(id - u)/native; /usr/local/bin/termux-x11-bridge /usr/local/bin/start-gui'"
EOF
    chmod +x "$TERMUX_PREFIX/bin/arch-gui"
    
    # CLI startup with auto-cleanup
    cat > "$TERMUX_PREFIX/bin/arch-cli" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Start Arch CLI with automatic cleanup

ARCH_ROOT="/data/data/com.termux/files/arch"

cleanup() {
    echo "Cleaning up mounts..."
    su -c "
        cd /
        fuser -k '$ARCH_ROOT' 2>/dev/null || true
        sleep 1
        umount -l '$ARCH_ROOT/tmp' 2>/dev/null || true
        umount -l '$ARCH_ROOT/run' 2>/dev/null || true
        umount -l '$ARCH_ROOT/proc' 2>/dev/null || true
        umount -l '$ARCH_ROOT/sys' 2>/dev/null || true
        umount -l '$ARCH_ROOT/dev/pts' 2>/dev/null || true
        umount -l '$ARCH_ROOT/dev' 2>/dev/null || true
        umount -l '$ARCH_ROOT/sdcard' 2>/dev/null || true
    "
}

trap cleanup EXIT INT TERM

# Mount and enter
su -c "
    mountpoint -q '$ARCH_ROOT/proc' || {
        mount -o bind /dev '$ARCH_ROOT/dev'
        mount -o bind /dev/pts '$ARCH_ROOT/dev/pts'
        mount -o bind /proc '$ARCH_ROOT/proc'
        mount -o bind /sys '$ARCH_ROOT/sys'
        mount -t tmpfs -o mode=1777 tmpfs '$ARCH_ROOT/tmp'
        mount -t tmpfs -o mode=755 tmpfs '$ARCH_ROOT/run'
        mount -o bind /sdcard '$ARCH_ROOT/sdcard' 2>/dev/null || true
    }
    cat /etc/resolv.conf > '$ARCH_ROOT/etc/resolv.conf'
"

# Execute command or interactive shell
if [[ $# -eq 0 ]]; then
    exec su -c "chroot '$ARCH_ROOT' /bin/bash --login"
else
    exec su -c "chroot '$ARCH_ROOT' /bin/bash -c '$*'"
fi
EOF
    chmod +x "$TERMUX_PREFIX/bin/arch-cli"
    
    # Snapshot management
    cat > "$TERMUX_PREFIX/bin/arch-snapshot" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Arch Linux Snapshot Manager

ARCH_ROOT="/data/data/com.termux/files/arch"
SNAPSHOT_DIR="${TERMUX_HOME}/arch-snapshots"
ARCHIVE_FORMAT="zst"

mkdir -p "$SNAPSHOT_DIR"

usage() {
    echo "Usage: arch-snapshot [create|restore|list|delete] [name]"
    echo ""
    echo "Commands:"
    echo "  create [name]  - Create new snapshot"
    echo "  restore <name> - Restore from snapshot"
    echo "  list          - List available snapshots"
    echo "  delete <name> - Delete snapshot"
}

create_snapshot() {
    local name="${1:-$(date +%Y%m%d-%H%M%S)}"
    local file="$SNAPSHOT_DIR/arch-${name}.tar.$ARCHIVE_FORMAT"
    
    if [[ -f "$file" ]]; then
        echo "Error: Snapshot already exists: $file"
        return 1
    fi
    
    echo "Creating snapshot: $name"
    echo "This may take several minutes..."
    
    # Ensure unmounted for clean backup
    su -c "
        cd /
        fuser -k '$ARCH_ROOT' 2>/dev/null || true
        sleep 2
        umount -l '$ARCH_ROOT/tmp' 2>/dev/null || true
        umount -l '$ARCH_ROOT/run' 2>/dev/null || true
        umount -l '$ARCH_ROOT/proc' 2>/dev/null || true
        umount -l '$ARCH_ROOT/sys' 2>/dev/null || true
        umount -l '$ARCH_ROOT/dev/pts' 2>/dev/null || true
        umount -l '$ARCH_ROOT/dev' 2>/dev/null || true
        umount -l '$ARCH_ROOT/sdcard' 2>/dev/null || true
    "
    
    cd "$ARCH_ROOT"
    
    # Check for zstd
    if command -v zstd >/dev/null 2>&1; then
        tar --exclude='./proc' \
            --exclude='./sys' \
            --exclude='./dev' \
            --exclude='./run' \
            --exclude='./tmp' \
            --exclude='./mnt' \
            --exclude='./media' \
            -cf - . | zstd -T0 -19 > "$file"
    else
        # Fallback to gzip
        file="${file%.zst}.gz"
        tar -czf "$file" \
            --exclude='./proc' \
            --exclude='./sys' \
            --exclude='./dev' \
            --exclude='./run' \
            --exclude='./tmp' \
            --exclude='./mnt' \
            --exclude='./media' \
            .
    fi
    
    echo "Snapshot created: $file"
    ls -lh "$file"
}

restore_snapshot() {
    local name="$1"
    local file=""
    
    # Find file with any extension
    for ext in zst gz xz bz2; do
        if [[ -f "$SNAPSHOT_DIR/arch-${name}.tar.$ext" ]]; then
            file="$SNAPSHOT_DIR/arch-${name}.tar.$ext"
            break
        fi
    done
    
    if [[ -z "$file" ]]; then
        echo "Error: Snapshot not found: $name"
        list_snapshots
        return 1
    fi
    
    echo "WARNING: This will REPLACE your current Arch installation!"
    read -rp "Are you sure? Type 'yes' to continue: " confirm
    [[ "$confirm" == "yes" ]] || return 0
    
    echo "Restoring from: $file"
    
    su -c "
        cd /
        fuser -k '$ARCH_ROOT' 2>/dev/null || true
        sleep 2
        umount -l '$ARCH_ROOT' 2>/dev/null || true
        rm -rf '${ARCH_ROOT:?}'/*
    "
    
    mkdir -p "$ARCH_ROOT"
    cd "$ARCH_ROOT"
    
    case "$file" in
        *.zst) 
            if command -v zstd >/dev/null 2>&1; then
                zstd -dc "$file" | tar xf -
            else
                echo "Error: zstd not installed"
                return 1
            fi
            ;;
        *.gz)  tar xzf "$file" ;;
        *.xz)  tar xJf "$file" ;;
        *.bz2) tar xjf "$file" ;;
        *)     tar xf "$file" ;;
    esac
    
    echo "Restore complete!"
}

list_snapshots() {
    echo "Available snapshots:"
    ls -lh "$SNAPSHOT_DIR"/arch-*.tar.* 2>/dev/null | while read -r line; do
        echo "$line" | awk '{print $9, "("$5")", $6, $7, $8}' | sed 's|.*/arch-||; s|\.tar\..*||'
    done || echo "No snapshots found"
}

delete_snapshot() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "Error: Specify snapshot name"
        return 1
    fi
    
    for file in "$SNAPSHOT_DIR/arch-${name}".tar.*; do
        if [[ -f "$file" ]]; then
            rm -i "$file"
            return 0
        fi
    done
    
    echo "Snapshot not found: $name"
}

case "${1:-}" in
    create)  create_snapshot "${2:-}" ;;
    restore) restore_snapshot "$2" ;;
    list)    list_snapshots ;;
    delete)  delete_snapshot "$2" ;;
    *)       usage ;;
esac
EOF
    chmod +x "$TERMUX_PREFIX/bin/arch-snapshot"
    
    # Update script
    cat > "$TERMUX_PREFIX/bin/arch-update" << 'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# Update Arch Linux system

ARCH_ROOT="/data/data/com.termux/files/arch"

echo "Updating Arch Linux system..."

su -c "
    mountpoint -q '$ARCH_ROOT/proc' || {
        mount -o bind /dev '$ARCH_ROOT/dev'
        mount -o bind /dev/pts '$ARCH_ROOT/dev/pts'
        mount -o bind /proc '$ARCH_ROOT/proc'
        mount -o bind /sys '$ARCH_ROOT/sys'
        mount -t tmpfs tmpfs '$ARCH_ROOT/tmp'
    }
"

su -c "chroot '$ARCH_ROOT' pacman -Syu"
EOF
    chmod +x "$TERMUX_PREFIX/bin/arch-update"
    
    log "Scripts created:"
    info "  arch-chroot  - Enter chroot environment"
    info "  arch-cli     - Enter CLI with auto-cleanup"
    info "  arch-gui     - Start KDE Plasma GUI"
    info "  arch-snapshot - Backup/restore system"
    info "  arch-update  - Update system packages"
}

# System fixes and optimizations
apply_fixes() {
    log "Applying system fixes..."
    
    mount_system
    
    chroot "$ARCH_ROOT" /bin/bash -c '
        chmod 755 /var /var/cache /var/lib 2>/dev/null || true
        grep -q "#includedir /etc/sudoers.d" /etc/sudoers || \
            echo "#includedir /etc/sudoers.d" >> /etc/sudoers 2>/dev/null || true
        
        if [[ ! -f /etc/machine-id ]]; then
            dbus-uuidgen > /etc/machine-id 2>/dev/null || cat /proc/sys/kernel/random/uuid > /etc/machine-id 2>/dev/null || true
        fi
        
        mkdir -p /var/log/journal
        locale-gen 2>/dev/null || true
        ldconfig 2>/dev/null || true
    '
    
    echo "kernel.unprivileged_userns_clone=1" >> "$ARCH_ROOT/etc/sysctl.d/99-termux.conf" 2>/dev/null || true
    
    log "Fixes applied"
}

# Update existing installation
update_system() {
    check_root
    mount_system
    apply_fixes
    
    log "Updating system..."
    chroot "$ARCH_ROOT" /bin/bash -c 'pacman -Syu --noconfirm'
    
    create_scripts
    
    log "Update complete"
}

# Main menu
main_menu() {
    clear
    echo "========================================"
    echo "  Termux Arch Linux Manager v$VERSION"
    echo "========================================"
    echo ""
    echo "  [1] Fresh Install (First Time)"
    echo "  [2] Install/Update GUI (KDE Plasma)"
    echo "  [3] Update Existing System"
    echo "  [4] Enter CLI (with auto-cleanup)"
    echo "  [5] Start GUI (KDE Plasma)"
    echo "  [6] Snapshot Manager"
    echo "  [7] Apply System Fixes"
    echo "  [8] Unmount/Cleanup"
    echo ""
    echo "  [0] Exit"
    echo ""
    read -rp "Select option: " choice
    
    case "$choice" in
        1) install_base ;;
        2) install_gui ;;
        3) update_system ;;
        4) exec arch-cli ;;
        5) exec arch-gui ;;
        6) arch-snapshot list; read -rp "Press enter..." ;;
        7) apply_fixes ;;
        8) unmount_system ;;
        0) exit 0 ;;
        *) warn "Invalid option" ;;
    esac
    
    echo ""
    read -rp "Press enter to continue..."
    main_menu
}

# Command line interface
case "${1:-menu}" in
    install|i) install_base ;;
    gui|g) install_gui ;;
    update|u) update_system ;;
    cli|c) shift; exec arch-cli "$@" ;;
    start|s) exec arch-gui ;;
    snapshot|snap) shift; arch-snapshot "$@" ;;
    fix|f) apply_fixes ;;
    umount|um) unmount_system ;;
    mount|m) mount_system ;;
    menu|*) main_menu ;;
esac
