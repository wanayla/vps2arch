#!/bin/bash
#
# vps2arch.sh - Convert any Linux VPS to Arch Linux online
#
# Based on vps2arch by Timothy Redaelli
# License: GPL-3.0
# Usage: ./vps2arch.sh [-m mirror] [-b bootloader] [-n network]
#
# WARNING: This script will completely replace the current system!
#

set -e

#=============================================================================
# Configuration
#=============================================================================

ARCH_MIRROR=""
BOOTLOADER="grub"
NETWORK="systemd-networkd"

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

# Download helper (supports wget and curl)
if command -v wget >/dev/null 2>&1; then
    _download() { wget -O- "$@" ; }
elif command -v curl >/dev/null 2>&1; then
    _download() { curl -fL "$@" ; }
else
    echo "This script needs curl or wget" >&2
    exit 2
fi

# Ensure zstd is available
if ! command -v zstd >/dev/null 2>&1; then
    echo "Installing zstd..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y zstd
    elif command -v yum >/dev/null 2>&1; then
        yum install -y zstd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y zstd
    fi
fi

if ! command -v zstd >/dev/null 2>&1; then
    echo "Could not install zstd, trying static binary..." >&2
    _download "https://people.redhat.com/~tredaell/zstd" > /usr/bin/zstd
    chmod +x /usr/bin/zstd
fi

#=============================================================================
# Mirror Functions
#=============================================================================

get_worldwide_mirrors() {
    # Use reliable static mirrors instead of dynamically fetching the Worldwide list,
    # which includes unstable servers like fastly.mirror.pkgbuild.com
    echo "https://geo.mirror.pkgbuild.com"
    echo "https://mirrors.kernel.org/archlinux"
    echo "https://mirror.rackspace.com/archlinux"
    echo "https://mirrors.xtom.com/archlinux"
}

download() {
    local path="$1"
    shift
    for m in $mirrors; do
        _download "$m/$path" && return 0
    done
    return 1
}

#=============================================================================
# Environment Detection
#=============================================================================

cpu_type=$(uname -m)

is_openvz() { [ -d /proc/vz ] && [ ! -d /proc/bc ]; }
is_lxc() { grep -aqw container=lxc /proc/1/environ 2>/dev/null; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
    fi
}

#=============================================================================
# Low Memory Support
#=============================================================================

ensure_enough_memory() {
    local mem_total_kb swap_total_kb total_kb
    mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    swap_total_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    total_kb=$((mem_total_kb + swap_total_kb))

    # Need at least 256MB total (RAM + swap) for safe operation
    if [ "$total_kb" -lt 262144 ]; then
        log_warn "Low memory detected ($(( mem_total_kb / 1024 ))MB RAM + $(( swap_total_kb / 1024 ))MB swap)"
        log_info "Creating temporary swap file..."

        local swap_size=$(( 512 - mem_total_kb / 1024 ))  # Add enough to reach ~512MB total
        [ "$swap_size" -lt 256 ] && swap_size=256

        if dd if=/dev/zero of=/vps2arch_swap bs=1M count="$swap_size" 2>/dev/null && \
           chmod 600 /vps2arch_swap && \
           mkswap /vps2arch_swap >/dev/null 2>&1 && \
           swapon /vps2arch_swap 2>/dev/null; then
            log_info "Created ${swap_size}MB temporary swap"
        else
            log_warn "Could not create swap (VPS may not support it). Proceeding anyway..."
        fi
    fi
}

#=============================================================================
# Download and Extract Bootstrap
#=============================================================================

download_and_extract_bootstrap() {
    ensure_enough_memory
    log_info "Downloading Arch Linux bootstrap..."
    cd /

    download iso/latest/sha256sums.txt | grep -F "$cpu_type.tar.zst" > "sha256sums.txt"
    read -r _ bootstrap_filename < "sha256sums.txt"

    # Download with retry and mandatory checksum verification
    local max_retries=3 retry=0 download_ok=0
    while [ $retry -lt $max_retries ]; do
        retry=$((retry + 1))
        log_info "Downloading $bootstrap_filename (attempt $retry/$max_retries)..."

        if download "iso/latest/$bootstrap_filename" > "$bootstrap_filename" && [ -s "$bootstrap_filename" ]; then
            if grep -F "$bootstrap_filename" sha256sums.txt | sha256sum -c; then
                log_info "Checksum verified successfully"
                download_ok=1
                break
            else
                log_warn "Checksum verification failed (attempt $retry/$max_retries)"
                rm -f "$bootstrap_filename"
            fi
        else
            log_warn "Download failed or file is empty (attempt $retry/$max_retries)"
            rm -f "$bootstrap_filename"
        fi
    done

    if [ $download_ok -ne 1 ]; then
        log_error "Failed to download bootstrap after $max_retries attempts. Check your network and mirrors."
    fi

    log_info "Extracting bootstrap..."
    # Decompress first to catch zstd errors (piping can hide failures)
    # Use --long=27 to limit memory usage for low-RAM systems (128MB)
    local tar_file="${bootstrap_filename%.zst}"
    if ! zstd -d --memory=100MB "$bootstrap_filename" -o "$tar_file" 2>/dev/null; then
        # Fallback without memory limit for older zstd versions
        if ! zstd -d "$bootstrap_filename" -o "$tar_file"; then
            log_error "Failed to decompress bootstrap (check available memory and zstd version)"
        fi
    fi
    rm -f "$bootstrap_filename"

    if ! tar --warning=no-unknown-keyword -xpf "$tar_file"; then
        log_error "Failed to extract bootstrap tarball"
    fi
    rm -f "$tar_file" sha256sums.txt

    # Copy DNS config, replacing local stub resolvers (e.g. systemd-resolved's
    # 127.0.0.53) with public DNS servers since they won't work inside chroot
    if grep -qE '^\s*nameserver\s+127\.' /etc/resolv.conf 2>/dev/null; then
        log_warn "Detected local stub resolver in resolv.conf, using public DNS instead"
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\n' \
            > "/root.$cpu_type/etc/resolv.conf"
    else
        cp -L /etc/resolv.conf "/root.$cpu_type/etc"
    fi

    # Mount filesystems (same options as arch-chroot)
    log_info "Mounting filesystems for chroot..."
    mount -t proc proc -o nosuid,noexec,nodev "/root.$cpu_type/proc"
    mount -t sysfs sys -o nosuid,noexec,nodev,ro "/root.$cpu_type/sys"
    mount -t devtmpfs -o mode=0755,nosuid udev "/root.$cpu_type/dev"
    mkdir -p "/root.$cpu_type/dev/pts" "/root.$cpu_type/dev/shm"
    mount -t devpts -o mode=0620,gid=5,nosuid,noexec devpts "/root.$cpu_type/dev/pts"
    mount -t tmpfs -o mode=1777,nosuid,nodev shm "/root.$cpu_type/dev/shm"
    mount -t tmpfs -o nosuid,nodev,mode=0755 run "/root.$cpu_type/run"
    mount -t tmpfs -o mode=1777,strictatime,nodev,nosuid tmp "/root.$cpu_type/tmp"

    # Bind mount root filesystem to /mnt inside chroot
    mount --bind / "/root.$cpu_type/mnt"
    findmnt /boot >/dev/null && mount --bind /boot "/root.$cpu_type/mnt/boot"
    findmnt /boot/efi >/dev/null && mount --bind /boot/efi "/root.$cpu_type/mnt/boot/efi"

    # Workarounds
    mkdir -p "/root.$cpu_type/run/shm"
    rm -f "/root.$cpu_type/etc/mtab"
    cp -L /etc/mtab "/root.$cpu_type/etc/mtab"
}

chroot_exec() {
    chroot "/root.$cpu_type" /bin/bash -c "$*"
}

#=============================================================================
# Configure Chroot Environment
#=============================================================================

configure_chroot() {
    log_info "Configuring chroot environment..."

    # Configure mirrors
    for m in $mirrors; do
        echo "Server = $m/\$repo/os/\$arch"
    done >> "/root.$cpu_type/etc/pacman.d/mirrorlist"

    # Ensure pacman directories exist
    mkdir -p "/root.$cpu_type/var/lib/pacman/sync"
    mkdir -p "/root.$cpu_type/var/cache/pacman/pkg"
    mkdir -p "/root.$cpu_type/var/log"

    # Install and initialize haveged if needed
    if ! is_openvz && ! pidof haveged >/dev/null 2>&1; then
        sed -i.bak "s/^[[:space:]]*SigLevel[[:space:]]*=.*$/SigLevel = Never/" "/root.$cpu_type/etc/pacman.conf"
        chroot_exec 'pacman --needed --noconfirm -Sy haveged && haveged' || true
        mv "/root.$cpu_type/etc/pacman.conf.bak" "/root.$cpu_type/etc/pacman.conf"
    fi

    chroot_exec 'pacman-key --init && pacman-key --populate archlinux'
    chroot_exec 'pacman --needed --noconfirm -Sy archlinux-keyring'

    # Generate fstab from current mounts
    chroot_exec 'genfstab /mnt >> /etc/fstab'
}

#=============================================================================
# Save Current System State
#=============================================================================

save_root_pass() {
    log_info "Saving root password..."
    grep '^root:' /etc/shadow > "/root.$cpu_type/root.passwd"
    chmod 0600 "/root.$cpu_type/root.passwd"
}

save_network_config() {
    log_info "Saving network configuration..."

    mkdir -p "/root.$cpu_type/network_backup"

    # Get default interface and network info
    DEFAULT_IFACE=$(ip route | awk '/default/ {print $5; exit}')
    MAC_ADDR=""
    if [[ -n "$DEFAULT_IFACE" ]]; then
        MAC_ADDR=$(ip link show "$DEFAULT_IFACE" | awk '/link\/ether/ {print $2}')
    fi

    IP_ADDR=$(ip -4 addr show "$DEFAULT_IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)
    IP6_ADDR=$(ip -6 addr show "$DEFAULT_IFACE" scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+/\d+' | head -n1)
    GATEWAY=$(ip route | awk '/default/ {print $3; exit}')
    GATEWAY6=$(ip -6 route 2>/dev/null | awk '/default/ {print $3; exit}')

    if [[ -f /etc/hostname ]]; then
        ORIG_HOSTNAME=$(cat /etc/hostname)
    elif command -v hostname &>/dev/null; then
        ORIG_HOSTNAME=$(hostname)
    else
        ORIG_HOSTNAME="archlinux"
    fi

    log_info "Interface: $DEFAULT_IFACE | IPv4: $IP_ADDR | GW: $GATEWAY"
    log_info "IPv6: $IP6_ADDR | GW6: $GATEWAY6"

    # Save network state
    ip addr show > "/root.$cpu_type/network_backup/ip_addr.txt" 2>/dev/null || true
    ip route show > "/root.$cpu_type/network_backup/ip_route.txt" 2>/dev/null || true
    ip -6 route show > "/root.$cpu_type/network_backup/ip6_route.txt" 2>/dev/null || true

    cat > "/root.$cpu_type/network_backup/summary.txt" << EOF
IFACE=$DEFAULT_IFACE
MAC=$MAC_ADDR
IP=$IP_ADDR
IP6=$IP6_ADDR
GW=$GATEWAY
GW6=$GATEWAY6
HOSTNAME=$ORIG_HOSTNAME
EOF
}

save_ssh_keys() {
    log_info "Saving SSH authorized_keys..."
    mkdir -p "/root.$cpu_type/ssh_backup"
    if [[ -f /root/.ssh/authorized_keys ]]; then
        cp -a /root/.ssh/authorized_keys "/root.$cpu_type/ssh_backup/"
        log_info "Saved authorized_keys"
    fi
}

backup_old_files() {
    cp -fL /etc/hostname /etc/localtime "/root.$cpu_type/etc/" 2>/dev/null || true
}

#=============================================================================
# Delete Old System
#=============================================================================

delete_all() {
    log_info "Deleting old system files..."
    # Remove immutable flags
    if command -v chattr >/dev/null 2>&1; then
        find / -type f \( ! -path '/dev/*' -and ! -path '/proc/*' -and ! -path '/sys/*' -and ! -path '/selinux/*' -and ! -path "/root.$cpu_type/*" \) \
            -exec chattr -i {} + 2>/dev/null || true
    fi
    # Delete everything except bootstrap and virtual filesystems
    find / \( ! -path '/dev/*' -and ! -path '/proc/*' -and ! -path '/sys/*' -and ! -path '/selinux/*' -and ! -path "/root.$cpu_type/*" \) -delete 2>/dev/null || true
}

#=============================================================================
# Install Packages
#=============================================================================

install_packages() {
    log_info "Installing packages with pacstrap..."

    local ld_so
    set -- "/root.$cpu_type/usr/lib"/ld-*.so.2
    ld_so=$1

    # Base packages
    set -- base openssh reflector

    # Kernel and LVM (not for containers)
    is_openvz || set -- "$@" linux linux-firmware lvm2

    # Bootloader
    [ "$BOOTLOADER" != "none" ] && set -- "$@" "$BOOTLOADER"
    [ "$BOOTLOADER" = "syslinux" ] && set -- "$@" gptfdisk
    [ -f /sys/firmware/efi/fw_platform_size ] && set -- "$@" efibootmgr

    # Network
    [ "$NETWORK" = "netctl" ] && set -- "$@" netctl

    # Extra packages
    set -- "$@" dhcpcd nano wget curl btop fastfetch

    # XFS support if needed
    while read -r _ mountpoint filesystem _; do
        [ "$mountpoint" = "/" ] && [ "$filesystem" = "xfs" ] && set -- "$@" xfsprogs
    done < /proc/mounts

    # Ensure /mnt/etc/resolv.conf exists for pacstrap -M (which skips bind-mounting it)
    # Must use ld.so trick since host binaries were deleted by delete_all
    "$ld_so" --library-path "/root.$cpu_type/usr/lib" \
        "/root.$cpu_type/usr/bin/chroot" "/root.$cpu_type" \
        /bin/bash -c 'mkdir -p /mnt/etc && cp -L /etc/resolv.conf /mnt/etc/resolv.conf'

    # Use ld.so trick to run pacstrap from bootstrap
    "$ld_so" --library-path "/root.$cpu_type/usr/lib" \
        "/root.$cpu_type/usr/bin/chroot" "/root.$cpu_type" /usr/bin/pacstrap -M /mnt "$@"
}

#=============================================================================
# Restore Root Password
#=============================================================================

restore_root_pass() {
    log_info "Restoring root password..."
    if grep -qE '^root:[^$]' "/root.$cpu_type/root.passwd"; then
        echo "root:vps2arch" | chpasswd
        log_info "Root password set to: vps2arch"
    else
        sed -i '/^root:/d' /etc/shadow
        cat "/root.$cpu_type/root.passwd" >> /etc/shadow
        log_info "Original root password restored"
    fi
}

#=============================================================================
# Cleanup
#=============================================================================

cleanup() {
    log_info "Cleaning up bootstrap environment..."
    mv "/root.$cpu_type/etc/fstab" "/etc/fstab"

    # Copy saved files to new system
    cp -a "/root.$cpu_type/network_backup" /root/ 2>/dev/null || true

    # Restore SSH authorized_keys
    if [[ -f "/root.$cpu_type/ssh_backup/authorized_keys" ]]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        cp -a "/root.$cpu_type/ssh_backup/authorized_keys" /root/.ssh/
        chmod 600 /root/.ssh/authorized_keys
        log_info "Restored SSH authorized_keys"
    fi

    # Unmount chroot
    awk "/\/root\.$cpu_type/ {print \$2}" /proc/mounts | sort -r | xargs umount -nl 2>/dev/null || true
    rm -rf "/root.$cpu_type/"
}

#=============================================================================
# Configure Bootloader
#=============================================================================

configure_bootloader() {
    log_info "Configuring bootloader ($BOOTLOADER)..."

    local root_dev root_devs="" tmp needs_lvm2=0 uefi=0
    root_dev=$(findmnt -no SOURCE /)

    case $root_dev in
    /dev/mapper/*) needs_lvm2=1 ;;
    esac

    if [ -f /sys/firmware/efi/fw_platform_size ]; then
        uefi=$(cat /sys/firmware/efi/fw_platform_size)
    fi

    if [ $needs_lvm2 -eq 1 ]; then
        sed -i.bak 's/use_lvmetad = 1/use_lvmetad = 0/g' /etc/lvm/lvm.conf 2>/dev/null || true
    fi

    if [ "$BOOTLOADER" = "grub" ]; then
        # Disable fancy interface names if using eth*
        grep -q '^[[:space:]]*eth' /proc/net/dev 2>/dev/null && \
            sed -i.bak 's/GRUB_CMDLINE_LINUX_DEFAULT="/&net.ifnames=0 /' /etc/default/grub

        # Use console terminal output
        sed -i.bak 's/^#GRUB_TERMINAL_OUTPUT=console/GRUB_TERMINAL_OUTPUT=console/' /etc/default/grub

        if [ $needs_lvm2 -eq 1 ]; then
            local vg=$(lvs --noheadings "$root_dev" 2>/dev/null | awk '{print $2}')
            root_dev=$(pvs --noheadings 2>/dev/null | awk -v vg="$vg" '($2 == vg) { print $1 }')
        fi

        # Find physical disk(s)
        for dev in $root_dev; do
            tmp=$(lsblk -npsro TYPE,NAME "$dev" 2>/dev/null | awk '($1 == "disk") { print $2}')
            case " $root_devs " in
            *" $tmp "*) ;;
            *) root_devs="${root_devs:+$root_devs }$tmp" ;;
            esac
        done

        case $uefi in
        0)
            # BIOS mode
            for dev in $root_devs; do
                log_info "Installing GRUB to $dev (BIOS)..."
                grub-install --target=i386-pc --recheck --force "$dev"
            done
            ;;
        32|64)
            # UEFI mode
            log_info "Installing GRUB (UEFI)..."
            mkdir -p /boot/efi
            findmnt /boot/efi >/dev/null 2>&1 || {
                # Try to find and mount EFI partition
                local efi_dev=""
                for dev in $(lsblk -ln -o NAME,PARTTYPE 2>/dev/null | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print $1}'); do
                    efi_dev="/dev/$dev"
                    break
                done
                if [[ -z "$efi_dev" ]]; then
                    for dev in /dev/sda1 /dev/sda15 /dev/vda1 /dev/vda15 /dev/nvme0n1p1 /dev/nvme0n1p15; do
                        if [[ -b "$dev" ]] && [[ "$(blkid -s TYPE -o value "$dev" 2>/dev/null)" == "vfat" ]]; then
                            efi_dev="$dev"
                            break
                        fi
                    done
                fi
                if [[ -n "$efi_dev" ]]; then
                    mount "$efi_dev" /boot/efi
                    log_info "Mounted EFI partition: $efi_dev"
                fi
            }
            if [ "$uefi" = "64" ]; then
                grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable 2>&1 || true
                grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB 2>&1 || true
            elif [ "$uefi" = "32" ]; then
                grub-install --target=i386-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable 2>&1 || true
                grub-install --target=i386-efi --efi-directory=/boot/efi --bootloader-id=GRUB 2>&1 || true
            fi
            ;;
        esac

        mkdir -p /boot/grub
        grub-mkconfig -o /boot/grub/grub.cfg

    elif [ "$BOOTLOADER" = "syslinux" ]; then
        grep -q '^[[:space:]]*eth' /proc/net/dev 2>/dev/null && tmp="net.ifnames=0"
        syslinux-install_update -ami
        sed -i "s;\(^[[:space:]]*APPEND.*\)root=[^[:space:]]*;\1root=$root_dev${tmp:+ $tmp};" /boot/syslinux/syslinux.cfg
    fi

    if [ $needs_lvm2 -eq 1 ]; then
        mv /etc/lvm/lvm.conf.bak /etc/lvm/lvm.conf 2>/dev/null || true
        sed -i '/HOOKS/s/block/& lvm2/' /etc/mkinitcpio.conf
        mkinitcpio -p linux
    fi
}

#=============================================================================
# Configure Network
#=============================================================================

configure_network() {
    log_info "Configuring network ($NETWORK)..."

    local dev gateway
    read -r dev gateway <<-EOF
		$(awk '$2 == "00000000" { ip = strtonum(sprintf("0x%s", $3));
			printf ("%s\t%d.%d.%d.%d", $1,
			rshift(and(ip,0x000000ff),00), rshift(and(ip,0x0000ff00),08),
			rshift(and(ip,0x00ff0000),16), rshift(and(ip,0xff000000),24)) ; exit }' < /proc/net/route)
	EOF

    set -- "$(ip addr show dev "$dev" | awk '($1 == "inet") { print $2 }')"
    local ips=$*

    if [ "$NETWORK" = "systemd-networkd" ]; then
        cat > /etc/systemd/network/default.network <<-EOF
			[Match]
			Name=$dev

			[Network]
			Gateway=$gateway
		EOF
        for ip in $ips; do
            echo "Address=$ip"
        done >> /etc/systemd/network/default.network

        # Check for static IPv6
        local ip6=$(ip -6 addr show "$dev" scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+/\d+' | head -n1)
        local gw6=$(ip -6 route 2>/dev/null | awk '/default/ {print $3; exit}')
        if [[ -n "$ip6" && "$ip6" == *"/128" && -n "$gw6" ]]; then
            cat >> /etc/systemd/network/default.network <<-EOF

				[Network]
				Address=$ip6
				Gateway=$gw6
				IPv6AcceptRA=no

				[Route]
				Destination=$gw6/128
				Scope=link
			EOF
            log_info "Configured static IPv6: $ip6"
        fi

        systemctl enable systemd-networkd

    elif [ "$NETWORK" = "netctl" ]; then
        cat > /etc/netctl/default <<-EOF
			Interface=$dev
			Connection=ethernet
			IP=static
			Address=($ips)
		EOF
        if [ "$gateway" = "0.0.0.0" ]; then
            echo 'Routes=(0.0.0.0/0)'
        else
            echo "Gateway=$gateway"
        fi >> /etc/netctl/default
        netctl enable default
    fi

    systemctl enable sshd

    # Ensure DNS works in the new system (resolv.conf may have been overwritten
    # by systemd to a symlink pointing to a non-running systemd-resolved)
    if [[ ! -s /etc/resolv.conf ]] || readlink /etc/resolv.conf | grep -q systemd; then
        rm -f /etc/resolv.conf
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\n' \
            > /etc/resolv.conf
    fi
}

#=============================================================================
# Configure SSH
#=============================================================================

configure_ssh() {
    log_info "Configuring SSH..."

    # Enable root login
    sed -i '/^#PermitRootLogin\s/s/.*/&\nPermitRootLogin yes/' /etc/ssh/sshd_config

    # Also add drop-in config for reliability
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-vps2arch.conf << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF

    log_info "SSH configured (root login enabled)"
}

#=============================================================================
# Configure Locale, Timezone, and Customizations
#=============================================================================

configure_system() {
    log_info "Configuring locale and timezone..."

    # Timezone (preserve from old system if possible)
    if [[ ! -f /etc/localtime ]]; then
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime
    fi

    # Locale
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

    # Hostname
    if [[ -n "$ORIG_HOSTNAME" ]] && [[ ! -f /etc/hostname ]]; then
        echo "$ORIG_HOSTNAME" > /etc/hostname
        cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $ORIG_HOSTNAME
EOF
    fi

    # Console
    cat > /etc/vconsole.conf << 'EOF'
KEYMAP=us
EOF

    # Aliases
    cat >> /etc/profile << 'EOF'

# Custom aliases
alias ls='ls --color=auto'
alias ll='ls -la --color=auto'
alias halt='halt -p'
EOF
}

#=============================================================================
# Finalize
#=============================================================================

finalize() {
    # OpenVZ workaround
    if is_openvz; then
        mkdir -p /etc/resolvconf/resolv.conf.d
    fi

    # Run reflector for optimized mirrors
    if command -v reflector >/dev/null 2>&1; then
        log_info "Running reflector to optimize mirrors..."
        reflector -l 35 -p https --sort rate --save /etc/pacman.d/mirrorlist || true
    fi

    cat <<-EOF

	========================================
	  Arch Linux installation complete!
	========================================

	Bootloader: $BOOTLOADER
	Network:    $NETWORK

	Root password: your old password (or "vps2arch" if none was set)

	Network backup saved to: /root/network_backup/

	To finish, reboot the VM:
	  sync ; reboot -f

	Then connect via SSH with your root password.
	========================================
	EOF
}

#=============================================================================
# Parse Arguments
#=============================================================================

while getopts ":b:m:n:h" opt; do
    case $opt in
    b)
        if [ "$OPTARG" != "grub" ] && [ "$OPTARG" != "syslinux" ] && [ "$OPTARG" != "none" ]; then
            echo "Invalid bootloader: $OPTARG" >&2
            exit 1
        fi
        BOOTLOADER="$OPTARG"
        ;;
    m)
        mirrors="${mirrors:+$mirrors }$OPTARG"
        ;;
    n)
        if [ "$OPTARG" != "systemd-networkd" ] && [ "$OPTARG" != "netctl" ] && [ "$OPTARG" != "none" ]; then
            echo "Invalid network config: $OPTARG" >&2
            exit 1
        fi
        NETWORK="$OPTARG"
        ;;
    h)
        cat <<-EOF
			usage: ${0##*/} [options]

			  Options:
			    -b (grub|syslinux|none)         Bootloader (default: grub)
			    -n (systemd-networkd|netctl|none) Network config (default: systemd-networkd)
			    -m mirror_url                   Mirror URL (can specify multiple)
			    -h                              Show this help

			  Warning: On OpenVZ containers, bootloader is skipped and netctl is enforced.
		EOF
        exit 0
        ;;
    :)
        printf "%s: option requires an argument -- '%s'\n" "${0##*/}" "$OPTARG" >&2
        exit 1
        ;;
    ?)
        printf "%s: invalid option -- '%s'\n" "${0##*/}" "$OPTARG" >&2
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

# Support legacy positional argument for mirror
if [[ -z "$mirrors" && -n "$1" ]]; then
    mirrors="$1"
fi

[ -z "$mirrors" ] && mirrors=$(get_worldwide_mirrors)

# Container overrides
if is_openvz; then
    BOOTLOADER=none
    NETWORK=netctl
elif is_lxc; then
    BOOTLOADER=none
fi

#=============================================================================
# Main Execution
#=============================================================================

echo "=============================================="
echo "    VPS to Arch Linux Conversion Script"
echo "=============================================="
echo ""
log_warn "This will completely replace the current system with Arch Linux!"
echo ""

check_root

cd /
save_network_config
save_ssh_keys
download_and_extract_bootstrap
configure_chroot
save_root_pass
backup_old_files
delete_all
install_packages
restore_root_pass
cleanup
configure_bootloader
configure_network
configure_ssh
configure_system
finalize
