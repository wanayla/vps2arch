#!/bin/bash
#
# vps2arch.sh - Convert any Linux VPS to Arch Linux online
#
# License: GPL-3.0
# Usage: ./vps2arch.sh [mirror_url]
#
# WARNING: This script will completely replace the current system!
#

set -e

#=============================================================================
# Configuration
#=============================================================================

# Arch Linux mirror (can be overridden by argument)
ARCH_MIRROR="${1:-https://mirrors.kernel.org/archlinux}"

# Working directory
WORK_DIR="/tmp/vps2arch"

# Architecture-related variables (set in check_arch)
ARCH=""
BOOTSTRAP_URL=""
NEW_ROOT=""

#=============================================================================
# Utility Functions
#=============================================================================

log_info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

log_warn() {
    echo -e "\033[33m[WARN]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
    fi
}

# Check system architecture
check_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            ARCH="x86_64"
            BOOTSTRAP_URL="${ARCH_MIRROR}/iso/latest/archlinux-bootstrap-x86_64.tar.zst"
            NEW_ROOT="${WORK_DIR}/root.x86_64"
            ;;
        aarch64|arm64)
            ARCH="aarch64"
            # ARM64 uses Arch Linux ARM
            BOOTSTRAP_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
            NEW_ROOT="${WORK_DIR}/root"
            ;;
        *)
            log_error "Unsupported architecture: $arch (only x86_64 and aarch64 are supported)"
            ;;
    esac
    log_info "System architecture: $ARCH"
}

# Check if running in virtualized environment
check_virt() {
    if command -v systemd-detect-virt &>/dev/null; then
        local virt=$(systemd-detect-virt)
        log_info "Virtualization type: $virt"
    fi
}

# Detect current OS type
detect_os() {
    OS_TYPE="unknown"
    PKG_MANAGER=""

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            arch|manjaro|endeavouros)
                OS_TYPE="arch"
                PKG_MANAGER="pacman"
                ;;
            debian|ubuntu|linuxmint|pop)
                OS_TYPE="debian"
                PKG_MANAGER="apt"
                ;;
            centos|rhel|rocky|almalinux|oracle)
                OS_TYPE="rhel"
                if command -v dnf &>/dev/null; then
                    PKG_MANAGER="dnf"
                else
                    PKG_MANAGER="yum"
                fi
                ;;
            fedora)
                OS_TYPE="fedora"
                PKG_MANAGER="dnf"
                ;;
            opensuse*|sles)
                OS_TYPE="suse"
                PKG_MANAGER="zypper"
                ;;
            *)
                # Try to detect by package manager
                if command -v pacman &>/dev/null; then
                    OS_TYPE="arch"
                    PKG_MANAGER="pacman"
                elif command -v apt-get &>/dev/null; then
                    OS_TYPE="debian"
                    PKG_MANAGER="apt"
                elif command -v dnf &>/dev/null; then
                    OS_TYPE="rhel"
                    PKG_MANAGER="dnf"
                elif command -v yum &>/dev/null; then
                    OS_TYPE="rhel"
                    PKG_MANAGER="yum"
                fi
                ;;
        esac
    fi

    log_info "Detected OS type: $OS_TYPE (package manager: $PKG_MANAGER)"

    if [[ "$PKG_MANAGER" == "" ]]; then
        log_error "Cannot detect OS type, current system is not supported"
    fi
}

# Install dependency packages
install_deps() {
    local packages="$@"
    log_info "Installing dependencies: $packages"

    case "$PKG_MANAGER" in
        pacman)
            pacman -Sy --noconfirm $packages
            ;;
        apt)
            apt-get update && apt-get install -y $packages
            ;;
        yum)
            yum install -y $packages
            ;;
        dnf)
            dnf install -y $packages
            ;;
        zypper)
            zypper install -y $packages
            ;;
        *)
            log_error "Unsupported package manager: $PKG_MANAGER"
            ;;
    esac
}

# Install busybox (prefer statically compiled version)
install_busybox() {
    BUSYBOX_OK=false
    BUSYBOX_STATIC=false

    # Debian/Ubuntu has statically compiled version
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        log_info "Installing busybox-static (Debian/Ubuntu)..."
        if apt-get install -y busybox-static; then
            if [[ -f /bin/busybox ]]; then
                cp /bin/busybox "${WORK_DIR}/busybox"
                BUSYBOX_OK=true
                BUSYBOX_STATIC=true
                log_info "busybox-static installed"
            fi
        fi
    fi

    # OpenSUSE has statically compiled version
    if [[ "$BUSYBOX_OK" != "true" && "$PKG_MANAGER" == "zypper" ]]; then
        log_info "Installing busybox-static (OpenSUSE)..."
        if zypper install -y busybox-static; then
            local bb=$(command -v busybox 2>/dev/null)
            if [[ -n "$bb" ]]; then
                cp "$bb" "${WORK_DIR}/busybox"
                BUSYBOX_OK=true
                BUSYBOX_STATIC=true
                log_info "busybox-static installed"
            fi
        fi
    fi

    # Try to download statically compiled version
    if [[ "$BUSYBOX_OK" != "true" ]]; then
        log_info "Downloading statically compiled busybox..."

        # Select download URL based on architecture
        if [[ "$ARCH" == "x86_64" ]]; then
            BUSYBOX_URLS=(
                "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
                "https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-x86_64"
            )
        elif [[ "$ARCH" == "aarch64" ]]; then
            BUSYBOX_URLS=(
                "https://busybox.net/downloads/binaries/1.35.0-aarch64-linux-musl/busybox"
                "https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-armv8l"
            )
        fi

        for url in "${BUSYBOX_URLS[@]}"; do
            log_info "Trying: $url"
            if wget -q --timeout=30 "$url" -O "${WORK_DIR}/busybox" 2>/dev/null; then
                if [[ -s "${WORK_DIR}/busybox" ]]; then
                    BUSYBOX_OK=true
                    BUSYBOX_STATIC=true
                    log_info "Download successful"
                    break
                fi
            fi
        done
    fi

    # Last resort: install dynamic version from package manager
    if [[ "$BUSYBOX_OK" != "true" ]]; then
        log_warn "Cannot get static version, trying dynamic version..."

        case "$PKG_MANAGER" in
            pacman)
                pacman -Sy --noconfirm busybox
                ;;
            yum)
                yum install -y busybox
                ;;
            dnf)
                dnf install -y busybox
                ;;
        esac

        local bb=$(command -v busybox 2>/dev/null)
        if [[ -n "$bb" && -f "$bb" ]]; then
            cp "$bb" "${WORK_DIR}/busybox"
            BUSYBOX_OK=true
            BUSYBOX_STATIC=false
            log_info "Dynamic busybox installed: $bb"
        fi
    fi

    # Final check
    if [[ "$BUSYBOX_OK" != "true" ]]; then
        log_error "Cannot get busybox. Please download manually to ${WORK_DIR}/busybox"
    fi

    chmod +x "${WORK_DIR}/busybox"

    # Verify if statically compiled
    if file "${WORK_DIR}/busybox" | grep -q "statically linked"; then
        log_info "busybox is statically compiled"
        BUSYBOX_STATIC=true
    elif ldd "${WORK_DIR}/busybox" 2>&1 | grep -q "not a dynamic"; then
        log_info "busybox is statically compiled"
        BUSYBOX_STATIC=true
    else
        log_warn "busybox is dynamically compiled, need to copy dependencies"
        BUSYBOX_STATIC=false
    fi

    # Export variable for later use
    export BUSYBOX_STATIC
}

#=============================================================================
# Save Network Configuration
#=============================================================================

save_network_config() {
    log_info "Saving current network configuration..."

    mkdir -p "${WORK_DIR}/network_backup"

    # Get default interface
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

    # Get MAC address
    if [[ -n "$DEFAULT_IFACE" ]]; then
        MAC_ADDR=$(ip link show "$DEFAULT_IFACE" | grep link/ether | awk '{print $2}')
    fi

    # Get IP address and mask
    IP_ADDR=$(ip -4 addr show "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)

    # Get IPv6 address
    IP6_ADDR=$(ip -6 addr show "$DEFAULT_IFACE" scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+/\d+' | head -n1)

    # Get gateway
    GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)

    # Get IPv6 gateway
    GATEWAY6=$(ip -6 route | grep default | awk '{print $3}' | head -n1)

    # Get DNS
    if [[ -f /etc/resolv.conf ]]; then
        DNS_SERVERS=$(grep "^nameserver" /etc/resolv.conf | awk '{print $2}' | head -n2)
    fi

    # Get hostname
    if [[ -f /etc/hostname ]]; then
        HOSTNAME=$(cat /etc/hostname)
    elif command -v hostname &>/dev/null; then
        HOSTNAME=$(hostname)
    else
        HOSTNAME="archlinux"
    fi

    log_info "Interface: $DEFAULT_IFACE"
    log_info "MAC address: $MAC_ADDR"
    log_info "IPv4 address: $IP_ADDR"
    log_info "IPv4 gateway: $GATEWAY"
    log_info "IPv6 address: $IP6_ADDR"
    log_info "IPv6 gateway: $GATEWAY6"
    log_info "DNS: $DNS_SERVERS"
    log_info "Hostname: $HOSTNAME"

    # Save complete network state
    ip addr show > "${WORK_DIR}/network_backup/ip_addr.txt"
    ip route show > "${WORK_DIR}/network_backup/ip_route.txt"
    ip -6 route show > "${WORK_DIR}/network_backup/ip6_route.txt" 2>/dev/null || true

    # Copy original system network config files
    cp -a /etc/resolv.conf "${WORK_DIR}/network_backup/" 2>/dev/null || true
    cp -a /etc/network "${WORK_DIR}/network_backup/" 2>/dev/null || true
    cp -a /etc/netplan "${WORK_DIR}/network_backup/" 2>/dev/null || true
    cp -a /etc/systemd/network "${WORK_DIR}/network_backup/" 2>/dev/null || true
    cp -a /etc/sysconfig/network-scripts "${WORK_DIR}/network_backup/" 2>/dev/null || true

    # Save config summary
    cat > "${WORK_DIR}/network_backup/summary.txt" << EOF
IFACE=$DEFAULT_IFACE
MAC=$MAC_ADDR
IP=$IP_ADDR
IP6=$IP6_ADDR
GW=$GATEWAY
GW6=$GATEWAY6
DNS=$DNS_SERVERS
HOSTNAME=$HOSTNAME
EOF

    log_info "Network configuration backed up to ${WORK_DIR}/network_backup/"
}

#=============================================================================
# Save SSH Configuration
#=============================================================================

save_ssh_config() {
    log_info "Saving SSH configuration..."

    mkdir -p "${WORK_DIR}/ssh_backup"

    # Only save authorized_keys (don't save old host keys)
    if [[ -f /root/.ssh/authorized_keys ]]; then
        cp -a /root/.ssh/authorized_keys "${WORK_DIR}/ssh_backup/" 2>/dev/null || true
        log_info "authorized_keys saved"
    fi

    # Save root password hash
    ROOT_PASSWORD_HASH=$(grep "^root:" /etc/shadow | cut -d: -f2)
}

#=============================================================================
# Download and Extract Arch Bootstrap
#=============================================================================

download_bootstrap() {
    log_info "Creating working directory..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    log_info "Downloading Arch Linux Bootstrap..."
    log_info "URL: $BOOTSTRAP_URL"

    # Install necessary dependencies
    local deps_to_install=""

    # zstd only needed for x86_64 (ARM uses tar.gz)
    if [[ "$ARCH" == "x86_64" ]] && ! command -v zstd &>/dev/null; then
        deps_to_install+=" zstd"
    fi

    if ! command -v wget &>/dev/null; then
        deps_to_install+=" wget"
    fi

    if [[ -n "$deps_to_install" ]]; then
        install_deps $deps_to_install
    fi

    # Install busybox (for system replacement phase)
    install_busybox

    # Download bootstrap
    log_info "Downloading Bootstrap: $BOOTSTRAP_URL"
    if [[ "$ARCH" == "x86_64" ]]; then
        if ! wget -q --show-progress "$BOOTSTRAP_URL" -O archlinux-bootstrap.tar.zst; then
            log_error "Download failed, please check network or mirror address"
        fi
        log_info "Extracting Bootstrap..."
        tar -I zstd -xf archlinux-bootstrap.tar.zst
    elif [[ "$ARCH" == "aarch64" ]]; then
        if ! wget -q --show-progress "$BOOTSTRAP_URL" -O archlinux-bootstrap.tar.gz; then
            log_error "Download failed, please check network or mirror address"
        fi
        log_info "Extracting Bootstrap..."
        mkdir -p "$NEW_ROOT"
        tar -xzf archlinux-bootstrap.tar.gz -C "$NEW_ROOT"
    fi

    if [[ ! -d "$NEW_ROOT" ]]; then
        log_error "Extraction failed, $NEW_ROOT directory not found"
    fi

    log_info "Bootstrap ready"
}

#=============================================================================
# Configure New System
#=============================================================================

configure_new_system() {
    log_info "Configuring new system..."

    # Configure pacman mirrors
    log_info "Configuring pacman mirrors..."
    if [[ "$ARCH" == "x86_64" ]]; then
        cat > "${NEW_ROOT}/etc/pacman.d/mirrorlist" << EOF
# Mirror list
Server = ${ARCH_MIRROR}/\$repo/os/\$arch
Server = https://mirrors.kernel.org/archlinux/\$repo/os/\$arch
Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch
EOF
    elif [[ "$ARCH" == "aarch64" ]]; then
        cat > "${NEW_ROOT}/etc/pacman.d/mirrorlist" << EOF
# Arch Linux ARM mirror list
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
EOF
    fi

    # Configure DNS (temporary, for chroot networking)
    cat > "${NEW_ROOT}/etc/resolv.conf" << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

    # Mount necessary filesystems
    log_info "Mounting filesystems..."
    mount --bind "$NEW_ROOT" "$NEW_ROOT"
    mount -t proc /proc "${NEW_ROOT}/proc"
    mount -t sysfs /sys "${NEW_ROOT}/sys"
    mount --rbind /dev "${NEW_ROOT}/dev"
    mount --rbind /run "${NEW_ROOT}/run"

    # Initialize pacman keys
    log_info "Initializing pacman keys..."
    if [[ "$ARCH" == "x86_64" ]]; then
        chroot "$NEW_ROOT" /bin/bash -c "
            pacman-key --init
            pacman-key --populate archlinux
        "
    elif [[ "$ARCH" == "aarch64" ]]; then
        chroot "$NEW_ROOT" /bin/bash -c "
            pacman-key --init
            pacman-key --populate archlinuxarm
        "
    fi

    # Install base system
    log_info "Installing base system packages..."
    if [[ "$ARCH" == "x86_64" ]]; then
        chroot "$NEW_ROOT" /bin/bash -c "
            pacman -Sy --noconfirm base linux linux-firmware openssh grub dhcpcd nano wget curl fastfetch btop
        "
    elif [[ "$ARCH" == "aarch64" ]]; then
        # ARM64 uses linux-aarch64 kernel, doesn't use grub
        chroot "$NEW_ROOT" /bin/bash -c "
            pacman -Sy --noconfirm base linux-aarch64 linux-firmware openssh dhcpcd nano wget curl fastfetch btop
        "
    fi
}

#=============================================================================
# Configure Network
#=============================================================================

setup_network() {
    log_info "Configuring network..."

    # Use dhcpcd for IPv4 management (simpler and more reliable than systemd-networkd)
    # Disable systemd-networkd to avoid conflicts
    chroot "$NEW_ROOT" /bin/bash -c "
        systemctl disable systemd-networkd 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl enable dhcpcd
    "

    log_info "dhcpcd enabled for IPv4 management"

    # Check if static IPv6 configuration is needed (/128 addresses usually need static config)
    if [[ -n "$IP6_ADDR" && "$IP6_ADDR" == *"/128" ]]; then
        log_info "Detected /128 IPv6 address, configuring static IPv6..."

        # Create systemd-networkd config for IPv6 only
        mkdir -p "${NEW_ROOT}/etc/systemd/network"

        # Create MAC address based network config (ensures matching correct interface)
        cat > "${NEW_ROOT}/etc/systemd/network/10-ipv6-static.network" << EOF
[Match]
MACAddress=${MAC_ADDR}

[Network]
# IPv4 managed by dhcpcd
DHCP=no

# Static IPv6 configuration
Address=${IP6_ADDR}
Gateway=${GATEWAY6}
IPv6AcceptRA=no

[Route]
# Cloud providers like OVH need host route to gateway first
Destination=${GATEWAY6}/128
Scope=link
EOF

        # Configure dhcpcd to not manage IPv6 (avoid conflicts)
        mkdir -p "${NEW_ROOT}/etc/dhcpcd.conf.d"
        cat > "${NEW_ROOT}/etc/dhcpcd.conf.d/10-ipv4-only.conf" << EOF
# Only use dhcpcd for IPv4, IPv6 managed by systemd-networkd
noipv6
noipv6rs
EOF

        # Enable systemd-networkd for IPv6
        chroot "$NEW_ROOT" /bin/bash -c "
            systemctl enable systemd-networkd
        "

        log_info "Static IPv6 configured: ${IP6_ADDR} -> ${GATEWAY6}"
    fi

    # Configure resolv.conf
    cat > "${NEW_ROOT}/etc/resolv.conf" << EOF
nameserver 8.8.8.8
nameserver 2001:4860:4860::8888
nameserver 1.1.1.1
EOF
    log_info "DNS configured"

    # Set hostname
    echo "$HOSTNAME" > "${NEW_ROOT}/etc/hostname"

    # Configure hosts
    cat > "${NEW_ROOT}/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}
EOF

    # Copy network config backup to new system (for troubleshooting)
    cp -a "${WORK_DIR}/network_backup" "${NEW_ROOT}/root/" 2>/dev/null || true

    log_info "Network configuration complete"
}

#=============================================================================
# Configure SSH
#=============================================================================

setup_ssh() {
    log_info "Configuring SSH..."

    # Restore authorized_keys (use new system's generated host keys)
    mkdir -p "${NEW_ROOT}/root/.ssh"
    chmod 700 "${NEW_ROOT}/root/.ssh"
    if [[ -f "${WORK_DIR}/ssh_backup/authorized_keys" ]]; then
        cp -a "${WORK_DIR}/ssh_backup/authorized_keys" "${NEW_ROOT}/root/.ssh/"
        chmod 600 "${NEW_ROOT}/root/.ssh/authorized_keys"
        log_info "authorized_keys restored"
    fi

    # Set root password (required)
    echo ""
    log_info "========== Set root password =========="
    echo -n "Enter new root password (press Enter for random password): "
    read -s NEW_ROOT_PASSWORD
    echo ""

    if [[ -z "$NEW_ROOT_PASSWORD" ]]; then
        # Generate random password
        NEW_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        echo ""
        echo "############################################"
        echo "#                                          #"
        echo "#   Random ROOT password (SAVE THIS!):    #"
        echo "#                                          #"
        echo "#   $NEW_ROOT_PASSWORD               #"
        echo "#                                          #"
        echo "############################################"
        echo ""
        log_warn "Please save the password above! Continuing in 5 seconds..."
        sleep 5
    fi

    echo "root:${NEW_ROOT_PASSWORD}" | chroot "$NEW_ROOT" chpasswd
    log_info "root password set"

    # Use new system's default sshd_config, add custom config to allow root password login
    mkdir -p "${NEW_ROOT}/etc/ssh/sshd_config.d"
    cat > "${NEW_ROOT}/etc/ssh/sshd_config.d/99-custom.conf" << 'EOF'
# Allow root login
PermitRootLogin yes

# Allow password authentication
PasswordAuthentication yes
EOF

    log_info "Configured to allow root password login"

    # Enable SSH service (auto-start on boot)
    log_info "Enabling SSH service..."
    chroot "$NEW_ROOT" /bin/bash -c "
        systemctl enable sshd.service
    "
    log_info "SSH service enabled for auto-start"
}

#=============================================================================
# Configure Timezone and Locale
#=============================================================================

setup_locale_timezone_alias() {
    log_info "Configuring timezone and locale..."

    # Set timezone to UTC (can be changed after installation)
    chroot "$NEW_ROOT" /bin/bash -c "
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime
        hwclock --systohc
    "
    log_info "Timezone set to UTC"

    # Configure locale
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "${NEW_ROOT}/etc/locale.gen"

    chroot "$NEW_ROOT" /bin/bash -c "
        locale-gen
    "

    echo "LANG=en_US.UTF-8" > "${NEW_ROOT}/etc/locale.conf"
    log_info "Locale set to en_US.UTF-8"

    # Add common aliases to /etc/profile
    log_info "Adding common aliases..."
    cat >> "${NEW_ROOT}/etc/profile" << 'EOF'

# Custom aliases
alias ls='ls --color=auto'
alias ll='ls -ls --color=auto'
alias dir='dir --color=auto'
alias halt='halt -p'
EOF
    log_info "Aliases added to /etc/profile"

    # Create /root/.bash_profile to show system info on login
    cat > "${NEW_ROOT}/root/.bash_profile" << 'EOF'
# ~/.bash_profile

# Load .bashrc
[[ -f ~/.bashrc ]] && . ~/.bashrc

# Show system info
fastfetch
EOF
    log_info "Configured /root/.bash_profile (runs fastfetch on login)"
}

#=============================================================================
# Configure fstab
#=============================================================================

setup_fstab() {
    log_info "Configuring fstab..."

    # Get root partition info
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)

    log_info "Root partition: $ROOT_DEV (UUID=$ROOT_UUID, type=$ROOT_FSTYPE)"

    cat > "${NEW_ROOT}/etc/fstab" << EOF
# /etc/fstab - Static filesystem information
# <device>                                <dir>   <type>  <options>       <dump> <pass>
UUID=${ROOT_UUID}   /       ${ROOT_FSTYPE}   defaults        0      1
EOF

    # Check for swap partition
    local swap_dev=$(swapon --show=NAME --noheadings 2>/dev/null | head -n1)
    if [[ -n "$swap_dev" ]]; then
        local swap_uuid=$(blkid -s UUID -o value "$swap_dev")
        echo "UUID=${swap_uuid}   none    swap    defaults        0      0" >> "${NEW_ROOT}/etc/fstab"
    fi
}

#=============================================================================
# Install Bootloader
#=============================================================================

setup_bootloader() {
    log_info "Configuring bootloader..."

    # Get root partition info
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    BOOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)
    BOOT_DISK="/dev/${BOOT_DISK}"
    log_info "Boot disk: $BOOT_DISK"

    if [[ "$ARCH" == "x86_64" ]]; then
        # x86_64: Install GRUB
        # Always try to install BIOS mode GRUB (for compatibility)
        log_info "Installing BIOS mode GRUB..."
        chroot "$NEW_ROOT" /bin/bash -c "
            grub-install --target=i386-pc ${BOOT_DISK} 2>/dev/null || echo 'BIOS GRUB installation skipped (may not be supported)'
        "

        # Check for EFI support
        if [[ -d /sys/firmware/efi ]]; then
            log_info "UEFI boot mode detected, also installing UEFI GRUB..."

            # Find EFI partition
            EFI_DEV=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || findmnt -n -o SOURCE /boot 2>/dev/null)
            if [[ -z "$EFI_DEV" ]]; then
                EFI_DEV=$(blkid | grep -i "EFI" | cut -d: -f1 | head -n1)
            fi

            if [[ -z "$EFI_DEV" ]]; then
                # Common EFI partition locations
                for dev in /dev/sda15 /dev/sda1 /dev/vda15 /dev/vda1; do
                    if [[ -b "$dev" ]] && blkid "$dev" | grep -qi "vfat"; then
                        EFI_DEV="$dev"
                        break
                    fi
                done
            fi

            if [[ -n "$EFI_DEV" ]]; then
                log_info "EFI partition: $EFI_DEV"

                # Create and mount EFI directory in new system
                mkdir -p "${NEW_ROOT}/boot/efi"
                mount "$EFI_DEV" "${NEW_ROOT}/boot/efi"

                # Add EFI to fstab
                EFI_UUID=$(blkid -s UUID -o value "$EFI_DEV")
                if ! grep -q "$EFI_UUID" "${NEW_ROOT}/etc/fstab"; then
                    echo "UUID=${EFI_UUID}   /boot/efi   vfat    defaults        0      2" >> "${NEW_ROOT}/etc/fstab"
                fi

                chroot "$NEW_ROOT" /bin/bash -c "
                    pacman -S --noconfirm efibootmgr
                    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable
                "

                # Unmount EFI partition
                umount "${NEW_ROOT}/boot/efi" 2>/dev/null || true
            else
                log_warn "EFI partition not found, skipping UEFI GRUB installation"
            fi
        else
            log_info "UEFI not detected, using BIOS mode only"
        fi

        # Manually create GRUB config file
        log_info "Generating GRUB configuration..."
        mkdir -p "${NEW_ROOT}/boot/grub"
        cat > "${NEW_ROOT}/boot/grub/grub.cfg" << EOF
# GRUB configuration file
set default=0
set timeout=5

menuentry 'Arch Linux' {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/vmlinuz-linux root=UUID=${ROOT_UUID} rw quiet
    initrd /boot/initramfs-linux.img
}

menuentry 'Arch Linux (fallback)' {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/vmlinuz-linux root=UUID=${ROOT_UUID} rw quiet
    initrd /boot/initramfs-linux-fallback.img
}
EOF
        log_info "GRUB configuration generated"

    elif [[ "$ARCH" == "aarch64" ]]; then
        # ARM64: Most cloud VPS use UEFI + GRUB
        if [[ -d /sys/firmware/efi ]]; then
            log_info "ARM64 UEFI mode, installing GRUB..."

            # Find EFI partition
            EFI_DEV=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || findmnt -n -o SOURCE /boot 2>/dev/null)
            if [[ -z "$EFI_DEV" ]]; then
                EFI_DEV=$(blkid | grep -i "EFI" | cut -d: -f1 | head -n1)
            fi

            if [[ -n "$EFI_DEV" ]]; then
                log_info "EFI partition: $EFI_DEV"

                mkdir -p "${NEW_ROOT}/boot/efi"
                mount "$EFI_DEV" "${NEW_ROOT}/boot/efi"

                EFI_UUID=$(blkid -s UUID -o value "$EFI_DEV")
                if ! grep -q "$EFI_UUID" "${NEW_ROOT}/etc/fstab"; then
                    echo "UUID=${EFI_UUID}   /boot/efi   vfat    defaults        0      2" >> "${NEW_ROOT}/etc/fstab"
                fi

                chroot "$NEW_ROOT" /bin/bash -c "
                    pacman -S --noconfirm grub efibootmgr
                    grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable
                "

                umount "${NEW_ROOT}/boot/efi" 2>/dev/null || true
            fi

            # Manually create GRUB config
            log_info "Generating ARM64 GRUB configuration..."
            mkdir -p "${NEW_ROOT}/boot/grub"
            cat > "${NEW_ROOT}/boot/grub/grub.cfg" << EOF
# GRUB configuration file (ARM64)
set default=0
set timeout=5

menuentry 'Arch Linux ARM' {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/Image root=UUID=${ROOT_UUID} rw quiet
    initrd /boot/initramfs-linux.img
}

menuentry 'Arch Linux ARM (fallback)' {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/Image root=UUID=${ROOT_UUID} rw quiet
    initrd /boot/initramfs-linux-fallback.img
}
EOF
            log_info "ARM64 GRUB configuration generated"
        else
            log_warn "ARM64 non-UEFI mode, skipping bootloader configuration (may use U-Boot)"
        fi
    fi
}

#=============================================================================
# Replace System
#=============================================================================

replace_system() {
    log_info "Preparing to replace system..."
    log_warn "This is an irreversible operation! Starting in 5 seconds..."
    sleep 5

    # Sync filesystem
    sync

    # Create RAM temporary directory
    RAMDIR="/srv/vps2arch_exec"

    # Unmount any existing old mounts
    umount "$RAMDIR" 2>/dev/null || true
    rm -rf "$RAMDIR" 2>/dev/null || true

    mkdir -p "$RAMDIR"
    mount -t tmpfs -o size=200M tmpfs "$RAMDIR" || log_error "Failed to mount tmpfs"
    log_info "tmpfs mounted at $RAMDIR"

    # Copy busybox to RAM
    log_info "Copying busybox to RAM..."
    cp "${WORK_DIR}/busybox" "$RAMDIR/busybox" || log_error "Failed to copy busybox"
    chmod +x "$RAMDIR/busybox"

    # If dynamically compiled busybox, need to copy dependencies
    if [[ "$BUSYBOX_STATIC" != "true" ]]; then
        log_info "busybox is dynamically compiled, copying dependencies..."

        # Get dynamic linker path
        LD_LINUX=""
        for ld in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/ld-linux-aarch64.so.1 /lib64/ld-linux-aarch64.so.1; do
            if [[ -f "$ld" ]]; then
                LD_LINUX="$ld"
                break
            fi
        done

        if [[ -z "$LD_LINUX" ]]; then
            log_error "Cannot find dynamic linker"
        fi

        # Copy dynamic linker
        cp -L "$LD_LINUX" "$RAMDIR/ld-linux.so"
        chmod +x "$RAMDIR/ld-linux.so"
        log_info "Dynamic linker copied: $LD_LINUX"

        # Copy busybox dependencies
        mkdir -p "$RAMDIR/lib"
        ldd "${WORK_DIR}/busybox" 2>/dev/null | while read line; do
            # Extract library file path
            lib=$(echo "$line" | grep -oE '/[^ ]+' | head -1)
            if [[ -n "$lib" && -f "$lib" ]]; then
                cp -L "$lib" "$RAMDIR/lib/" 2>/dev/null || true
                log_info "  Copied library: $(basename $lib)"
            fi
        done

        # Set library path
        export LD_LIBRARY_PATH="$RAMDIR/lib"
        BUSYBOX_CMD="$RAMDIR/ld-linux.so --library-path $RAMDIR/lib $RAMDIR/busybox"
    else
        BUSYBOX_CMD="$RAMDIR/busybox"
    fi

    # Test busybox
    log_info "Testing busybox..."
    if ! $BUSYBOX_CMD echo "busybox test ok"; then
        log_error "busybox cannot execute"
    fi
    log_info "busybox test passed"

    # Create replacement script
    if [[ "$BUSYBOX_STATIC" == "true" ]]; then
        # Static version: use busybox directly
        cat > "$RAMDIR/do_replace.sh" << 'REPLACE_SCRIPT'
#!/srv/vps2arch_exec/busybox sh

RAMDIR="/srv/vps2arch_exec"
BB="$RAMDIR/busybox"
REPLACE_SCRIPT
    else
        # Dynamic version: use dynamic linker
        cat > "$RAMDIR/do_replace.sh" << 'REPLACE_SCRIPT'
#!/srv/vps2arch_exec/ld-linux.so --library-path /srv/vps2arch_exec/lib /srv/vps2arch_exec/busybox sh

RAMDIR="/srv/vps2arch_exec"
BB="$RAMDIR/ld-linux.so --library-path $RAMDIR/lib $RAMDIR/busybox"
REPLACE_SCRIPT
    fi

    # Append common script content
    cat >> "$RAMDIR/do_replace.sh" << REPLACE_SCRIPT

NEW_ROOT="$NEW_ROOT"

echo "========== Starting system replacement =========="

# Verify new system files exist
if [ ! -d "\${NEW_ROOT}/bin" ]; then
    echo "Error: New system files not found, aborting"
    exit 1
fi
echo "New system files verified"

# Change to root directory
cd /

echo "Deleting old system files..."
# Delete old system files (preserve necessary directories)
for item in /*; do
    case "\$item" in
        /proc|/sys|/dev|/run|/tmp|/mnt|/srv)
            continue
            ;;
        *)
            echo "Deleting: \$item"
            \$BB rm -rf "\$item" 2>/dev/null || true
            ;;
    esac
done

echo "Copying new system..."
# Copy new system
\$BB cp -a "\${NEW_ROOT}"/* /

echo "Syncing disk..."
\$BB sync

# Reboot
echo "========== System replacement complete =========="
echo "Rebooting in 3 seconds..."
\$BB sleep 3
echo b > /proc/sysrq-trigger
REPLACE_SCRIPT

    chmod +x "$RAMDIR/do_replace.sh"

    # Unmount chroot mount points
    umount -l "${NEW_ROOT}/dev" 2>/dev/null || true
    umount -l "${NEW_ROOT}/run" 2>/dev/null || true
    umount -l "${NEW_ROOT}/sys" 2>/dev/null || true
    umount -l "${NEW_ROOT}/proc" 2>/dev/null || true
    umount -l "$NEW_ROOT" 2>/dev/null || true

    # Execute replacement
    log_info "Starting system replacement..."

    if [[ "$BUSYBOX_STATIC" == "true" ]]; then
        log_info "Using static busybox to execute replacement script"
        exec "$RAMDIR/busybox" sh "$RAMDIR/do_replace.sh"
    else
        log_info "Using dynamic busybox + ld-linux to execute replacement script"
        exec "$RAMDIR/ld-linux.so" --library-path "$RAMDIR/lib" "$RAMDIR/busybox" sh "$RAMDIR/do_replace.sh"
    fi
}

#=============================================================================
# Main Function
#=============================================================================

main() {
    echo "=============================================="
    echo "    VPS to Arch Linux Conversion Script"
    echo "=============================================="
    echo ""

    log_warn "This script will completely replace the current system with Arch Linux"
    log_warn "Make sure you have backed up important data!"
    echo ""

    read -p "Are you sure you want to continue? (type YES to confirm): " confirm
    if [[ "$confirm" != "YES" ]]; then
        log_info "Operation cancelled"
        exit 0
    fi

    # Execute checks
    check_root
    check_arch
    check_virt
    detect_os

    # Save configurations
    save_network_config
    save_ssh_config

    # Download and configure
    download_bootstrap
    configure_new_system
    setup_locale_timezone_alias
    setup_network
    setup_ssh
    setup_fstab
    setup_bootloader

    # Replace system
    replace_system
}

# Run main function
main "$@"
