# VPS2Arch - Convert Any Linux VPS to Arch Linux Online

Convert any Linux VPS to Arch Linux online, supporting x86_64 and ARM64 architectures.

[中文文档](README-cn.md)

## Features

- **Multi-source OS support**: Debian, Ubuntu, CentOS, RHEL, Fedora, OpenSUSE, Arch Linux
- **Multi-architecture support**: x86_64 (AMD64) and aarch64 (ARM64)
- **Automatic network configuration**: Uses dhcpcd for automatic network setup
- **SSH preserved**: Automatically retains authorized_keys, supports password login
- **UEFI/BIOS dual mode**: Auto-detects and configures GRUB bootloader
- **Static busybox**: Uses statically compiled busybox for stable system replacement

## System Requirements

- Root privileges
- At least 1GB RAM
- At least 5GB disk space
- Network connection

## Supported Source Systems

| Distribution | Package Manager | Status |
|--------------|-----------------|--------|
| Debian / Ubuntu | apt | ✅ |
| CentOS / RHEL / Rocky / AlmaLinux | yum / dnf | ✅ |
| Fedora | dnf | ✅ |
| OpenSUSE / SLES | zypper | ✅ |
| Arch Linux / Manjaro | pacman | ✅ |

## Supported Target Architectures

| Architecture | Bootstrap Source | Boot Method |
|--------------|------------------|-------------|
| x86_64 | Arch Linux | GRUB (BIOS/UEFI) |
| aarch64 | Arch Linux ARM | GRUB (UEFI) |

## Usage

### Basic Usage

```bash
# Download script
wget https://raw.githubusercontent.com/wanayla/vps2arch/main/vps2arch.sh
chmod +x vps2arch.sh

# Run (using default mirror)
./vps2arch.sh

# Or specify a mirror
./vps2arch.sh https://mirrors.kernel.org/archlinux
```

### Execution Flow

1. Detect system architecture and distribution
2. Save current network configuration and SSH keys
3. Download Arch Linux Bootstrap
4. Configure new system (mirrors, keys, base packages)
5. Setup network (dhcpcd)
6. Configure SSH and root password
7. Install GRUB bootloader
8. Replace system and reboot

## Installed Packages

### Base Packages
- base
- linux / linux-aarch64 (depending on architecture)
- linux-firmware
- openssh
- grub (x86_64) / grub + efibootmgr (ARM64 UEFI)
- dhcpcd

### Tools
- nano
- wget
- curl
- fastfetch
- btop

## Configuration Details

### Network Configuration

The script uses `dhcpcd` for automatic network configuration, suitable for most VPS environments. Original network configuration is backed up to `/root/network_backup/`.

For IPv6 /128 addresses (common with OVH and similar providers), static IPv6 configuration is automatically applied using systemd-networkd.

### SSH Configuration

- Automatically preserves original `authorized_keys`
- Allows root password login
- sshd service auto-starts on boot

### Root Password

When running the script, you'll be prompted to set a root password:
- Enter password: Uses the entered password
- Press Enter: Generates a 16-character random password (displayed on screen)

### Timezone and Language

- Timezone: UTC (can be changed after installation)
- Language: en_US.UTF-8

### Shell Aliases

Automatically added to `/etc/profile`:

```bash
alias ls='ls --color=auto'
alias ll='ls -ls --color=auto'
alias dir='dir --color=auto'
alias halt='halt -p'
```

### Login Welcome

Automatically runs `fastfetch` on login to display system information.

## Troubleshooting

### Network Not Working

1. Check dhcpcd service status:
   ```bash
   systemctl status dhcpcd
   ```

2. View backed up network configuration:
   ```bash
   cat /root/network_backup/summary.txt
   cat /root/network_backup/ip_route.txt
   ```

3. Manually configure network if DHCP is unavailable

### Cannot Connect via SSH

1. Check sshd service:
   ```bash
   systemctl status sshd
   ```

2. Check firewall (Arch has no firewall by default)

3. Use VNC/console to troubleshoot

### Boot Failure

1. Use rescue mode to mount disk
2. Check `/boot/grub/grub.cfg` configuration
3. Re-run `grub-install`

## Important Notes

⚠️ **WARNING**: This script will completely replace the current system. This operation is irreversible!

- Make sure to backup important data before running
- Ensure you have VNC/IPMI/console access (in case SSH doesn't work)
- Recommend testing in a test environment first
- ARM64 non-UEFI environments may require manual bootloader configuration

## Technical Details

### System Replacement Principle

1. Download Arch Linux Bootstrap to `/tmp/vps2arch/`
2. Configure new system in chroot environment
3. Use statically compiled busybox for replacement operations
4. Delete old system files (preserve /proc /sys /dev /run /tmp /srv)
5. Copy new system to root directory
6. Trigger reboot via sysrq

### Why Use busybox

During system replacement, directories like `/lib` are deleted, causing dynamically linked commands (cp, rm, etc.) to fail. Using statically compiled busybox avoids this problem.

## Scripts

- `vps2arch.sh` - English version
- `vps2arch-cn.sh` - Chinese version

## Support

- Telegram Group: https://t.me/OpineWorkOfficial
- Telegram Channel: https://t.me/OpineWorkPublish

## License

GPL-3.0 License

## Contributing

Issues and Pull Requests are welcome.
