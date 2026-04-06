#!/bin/bash
#
# vps2arch-cn.sh - 在线将任意 Linux VPS 转换为 Arch Linux
#
# 基于 vps2arch (Timothy Redaelli)
# 许可证: GPL-3.0
# 用法: ./vps2arch-cn.sh [-m 镜像地址] [-b 引导程序] [-n 网络配置]
#
# 警告: 此脚本将完全替换当前系统！
#

set -e

#=============================================================================
# 配置
#=============================================================================

ARCH_MIRROR=""
BOOTLOADER="grub"
NETWORK="systemd-networkd"

#=============================================================================
# 工具函数
#=============================================================================

log_info() {
    echo -e "\033[32m[信息]\033[0m $1"
}

log_warn() {
    echo -e "\033[33m[警告]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[错误]\033[0m $1"
    exit 1
}

# 下载工具（支持 wget 和 curl）
if command -v wget >/dev/null 2>&1; then
    _download() { wget -O- "$@" ; }
elif command -v curl >/dev/null 2>&1; then
    _download() { curl -fL "$@" ; }
else
    echo "此脚本需要 curl 或 wget" >&2
    exit 2
fi

# 确保 zstd 可用
if ! command -v zstd >/dev/null 2>&1; then
    echo "正在安装 zstd..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y zstd
    elif command -v yum >/dev/null 2>&1; then
        yum install -y zstd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y zstd
    fi
fi

if ! command -v zstd >/dev/null 2>&1; then
    echo "无法通过包管理器安装 zstd，尝试下载静态二进制文件..." >&2
    _download "https://people.redhat.com/~tredaell/zstd" > /usr/bin/zstd
    chmod +x /usr/bin/zstd
fi

#=============================================================================
# 镜像源函数
#=============================================================================

get_worldwide_mirrors() {
    # 使用稳定的静态镜像列表，避免动态获取的 Worldwide 列表中
    # 包含不稳定的服务器（如 fastly.mirror.pkgbuild.com）
    echo "https://mirrors.tuna.tsinghua.edu.cn/archlinux"
    echo "https://mirrors.ustc.edu.cn/archlinux"
    echo "https://mirrors.aliyun.com/archlinux"
    echo "https://geo.mirror.pkgbuild.com"
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
# 环境检测
#=============================================================================

cpu_type=$(uname -m)

is_openvz() { [ -d /proc/vz ] && [ ! -d /proc/bc ]; }
is_lxc() { grep -aqw container=lxc /proc/1/environ 2>/dev/null; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 身份运行"
    fi
}

#=============================================================================
# 低内存支持
#=============================================================================

ensure_enough_memory() {
    local mem_total_kb swap_total_kb total_kb
    mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    swap_total_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    total_kb=$((mem_total_kb + swap_total_kb))

    # 安全运行至少需要 256MB（内存 + swap）
    if [ "$total_kb" -lt 262144 ]; then
        log_warn "检测到低内存（$(( mem_total_kb / 1024 ))MB 内存 + $(( swap_total_kb / 1024 ))MB swap）"
        log_info "正在创建临时 swap 文件..."

        local swap_size=$(( 512 - mem_total_kb / 1024 ))  # 补足到约 512MB
        [ "$swap_size" -lt 256 ] && swap_size=256

        if dd if=/dev/zero of=/vps2arch_swap bs=1M count="$swap_size" 2>/dev/null && \
           chmod 600 /vps2arch_swap && \
           mkswap /vps2arch_swap >/dev/null 2>&1 && \
           swapon /vps2arch_swap 2>/dev/null; then
            log_info "已创建 ${swap_size}MB 临时 swap"
        else
            log_warn "无法创建 swap（VPS 可能不支持）。继续尝试..."
        fi
    fi
}

#=============================================================================
# 下载并解压 Bootstrap
#=============================================================================

download_and_extract_bootstrap() {
    ensure_enough_memory
    log_info "正在下载 Arch Linux Bootstrap..."
    cd /

    download iso/latest/sha256sums.txt | grep -F "$cpu_type.tar.zst" > "sha256sums.txt"
    read -r _ bootstrap_filename < "sha256sums.txt"

    # 下载并校验，失败自动重试
    local max_retries=3 retry=0 download_ok=0
    while [ $retry -lt $max_retries ]; do
        retry=$((retry + 1))
        log_info "正在下载 $bootstrap_filename（第 $retry/$max_retries 次尝试）..."

        if download "iso/latest/$bootstrap_filename" > "$bootstrap_filename" && [ -s "$bootstrap_filename" ]; then
            if grep -F "$bootstrap_filename" sha256sums.txt | sha256sum -c; then
                log_info "校验和验证通过"
                download_ok=1
                break
            else
                log_warn "校验和验证失败（第 $retry/$max_retries 次尝试）"
                rm -f "$bootstrap_filename"
            fi
        else
            log_warn "下载失败或文件为空（第 $retry/$max_retries 次尝试）"
            rm -f "$bootstrap_filename"
        fi
    done

    if [ $download_ok -ne 1 ]; then
        log_error "经过 $max_retries 次尝试仍无法下载 Bootstrap，请检查网络和镜像源。"
    fi

    log_info "正在解压 Bootstrap..."
    # 先解压以捕获 zstd 错误（管道可能隐藏失败）
    # 使用 --memory 限制内存使用，支持低内存系统（128MB）
    local tar_file="${bootstrap_filename%.zst}"
    if ! zstd -d --memory=100MB "$bootstrap_filename" -o "$tar_file" 2>/dev/null; then
        # 旧版 zstd 不支持 --memory，回退到默认模式
        if ! zstd -d "$bootstrap_filename" -o "$tar_file"; then
            log_error "解压 Bootstrap 失败（请检查可用内存和 zstd 版本）"
        fi
    fi
    rm -f "$bootstrap_filename"

    if ! tar --warning=no-unknown-keyword -xpf "$tar_file"; then
        log_error "解压 Bootstrap tarball 失败"
    fi
    rm -f "$tar_file" sha256sums.txt

    # 复制 DNS 配置，如果检测到本地 stub resolver（如 systemd-resolved 的
    # 127.0.0.53），则替换为公共 DNS，因为 chroot 内无法使用本地解析器
    if grep -qE '^\s*nameserver\s+127\.' /etc/resolv.conf 2>/dev/null; then
        log_warn "检测到本地 stub resolver，使用公共 DNS 替代"
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\n' \
            > "/root.$cpu_type/etc/resolv.conf"
    else
        cp -L /etc/resolv.conf "/root.$cpu_type/etc"
    fi

    # 挂载文件系统（与 arch-chroot 相同的挂载选项）
    log_info "正在为 chroot 挂载文件系统..."
    mount -t proc proc -o nosuid,noexec,nodev "/root.$cpu_type/proc"
    mount -t sysfs sys -o nosuid,noexec,nodev,ro "/root.$cpu_type/sys"
    mount -t devtmpfs -o mode=0755,nosuid udev "/root.$cpu_type/dev"
    mkdir -p "/root.$cpu_type/dev/pts" "/root.$cpu_type/dev/shm"
    mount -t devpts -o mode=0620,gid=5,nosuid,noexec devpts "/root.$cpu_type/dev/pts"
    mount -t tmpfs -o mode=1777,nosuid,nodev shm "/root.$cpu_type/dev/shm"
    mount -t tmpfs -o nosuid,nodev,mode=0755 run "/root.$cpu_type/run"
    mount -t tmpfs -o mode=1777,strictatime,nodev,nosuid tmp "/root.$cpu_type/tmp"

    # 将根文件系统绑定挂载到 chroot 内的 /mnt
    mount --bind / "/root.$cpu_type/mnt"
    findmnt /boot >/dev/null && mount --bind /boot "/root.$cpu_type/mnt/boot"
    findmnt /boot/efi >/dev/null && mount --bind /boot/efi "/root.$cpu_type/mnt/boot/efi"

    # 兼容性修复
    mkdir -p "/root.$cpu_type/run/shm"
    rm -f "/root.$cpu_type/etc/mtab"
    cp -L /etc/mtab "/root.$cpu_type/etc/mtab"
}

chroot_exec() {
    chroot "/root.$cpu_type" /bin/bash -c "$*"
}

#=============================================================================
# 配置 Chroot 环境
#=============================================================================

configure_chroot() {
    log_info "正在配置 chroot 环境..."

    # 配置镜像源
    for m in $mirrors; do
        echo "Server = $m/\$repo/os/\$arch"
    done >> "/root.$cpu_type/etc/pacman.d/mirrorlist"

    # 确保 pacman 所需目录存在
    mkdir -p "/root.$cpu_type/var/lib/pacman/sync"
    mkdir -p "/root.$cpu_type/var/cache/pacman/pkg"
    mkdir -p "/root.$cpu_type/var/log"

    # 如有需要，安装并初始化 haveged
    if ! is_openvz && ! pidof haveged >/dev/null 2>&1; then
        sed -i.bak "s/^[[:space:]]*SigLevel[[:space:]]*=.*$/SigLevel = Never/" "/root.$cpu_type/etc/pacman.conf"
        chroot_exec 'pacman --needed --noconfirm -Sy haveged && haveged' || true
        mv "/root.$cpu_type/etc/pacman.conf.bak" "/root.$cpu_type/etc/pacman.conf"
    fi

    chroot_exec 'pacman-key --init && pacman-key --populate archlinux'
    chroot_exec 'pacman --needed --noconfirm -Sy archlinux-keyring'

    # 从当前挂载生成 fstab
    chroot_exec 'genfstab /mnt >> /etc/fstab'
}

#=============================================================================
# 保存当前系统状态
#=============================================================================

save_root_pass() {
    log_info "正在保存 root 密码..."
    grep '^root:' /etc/shadow > "/root.$cpu_type/root.passwd"
    chmod 0600 "/root.$cpu_type/root.passwd"
}

save_network_config() {
    log_info "正在保存网络配置..."

    mkdir -p "/root.$cpu_type/network_backup"

    # 获取默认网卡和网络信息
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

    log_info "网卡: $DEFAULT_IFACE | IPv4: $IP_ADDR | 网关: $GATEWAY"
    log_info "IPv6: $IP6_ADDR | IPv6 网关: $GATEWAY6"

    # 保存网络状态
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
    log_info "正在保存 SSH 公钥..."
    mkdir -p "/root.$cpu_type/ssh_backup"
    if [[ -f /root/.ssh/authorized_keys ]]; then
        cp -a /root/.ssh/authorized_keys "/root.$cpu_type/ssh_backup/"
        log_info "已保存 authorized_keys"
    fi
}

backup_old_files() {
    cp -fL /etc/hostname /etc/localtime "/root.$cpu_type/etc/" 2>/dev/null || true
}

#=============================================================================
# 删除旧系统
#=============================================================================

delete_all() {
    log_info "正在删除旧系统文件..."
    # 移除不可变标志
    if command -v chattr >/dev/null 2>&1; then
        find / -type f \( ! -path '/dev/*' -and ! -path '/proc/*' -and ! -path '/sys/*' -and ! -path '/selinux/*' -and ! -path "/root.$cpu_type/*" \) \
            -exec chattr -i {} + 2>/dev/null || true
    fi
    # 删除 bootstrap 和虚拟文件系统以外的所有文件
    find / \( ! -path '/dev/*' -and ! -path '/proc/*' -and ! -path '/sys/*' -and ! -path '/selinux/*' -and ! -path "/root.$cpu_type/*" \) -delete 2>/dev/null || true
}

#=============================================================================
# 安装软件包
#=============================================================================

install_packages() {
    log_info "正在使用 pacstrap 安装软件包..."

    local ld_so
    set -- "/root.$cpu_type/usr/lib"/ld-*.so.2
    ld_so=$1

    # 基础软件包
    set -- base openssh reflector

    # 内核和 LVM（容器环境除外）
    is_openvz || set -- "$@" linux linux-firmware lvm2

    # 引导程序
    [ "$BOOTLOADER" != "none" ] && set -- "$@" "$BOOTLOADER"
    [ "$BOOTLOADER" = "syslinux" ] && set -- "$@" gptfdisk
    [ -f /sys/firmware/efi/fw_platform_size ] && set -- "$@" efibootmgr

    # 网络
    [ "$NETWORK" = "netctl" ] && set -- "$@" netctl

    # 额外软件包
    set -- "$@" dhcpcd nano wget curl btop fastfetch

    # 如需 XFS 支持
    while read -r _ mountpoint filesystem _; do
        [ "$mountpoint" = "/" ] && [ "$filesystem" = "xfs" ] && set -- "$@" xfsprogs
    done < /proc/mounts

    # 确保 /mnt/etc/resolv.conf 存在，pacstrap -M 不会自动 bind mount 它
    # 必须使用 ld.so 技巧，因为宿主命令已被 delete_all 删除
    "$ld_so" --library-path "/root.$cpu_type/usr/lib" \
        "/root.$cpu_type/usr/bin/chroot" "/root.$cpu_type" \
        /bin/bash -c 'mkdir -p /mnt/etc && cp -L /etc/resolv.conf /mnt/etc/resolv.conf'

    # 使用 ld.so 技巧从 bootstrap 运行 pacstrap
    "$ld_so" --library-path "/root.$cpu_type/usr/lib" \
        "/root.$cpu_type/usr/bin/chroot" "/root.$cpu_type" /usr/bin/pacstrap -M /mnt "$@"
}

#=============================================================================
# 恢复 Root 密码
#=============================================================================

restore_root_pass() {
    log_info "正在恢复 root 密码..."
    if grep -qE '^root:[^$]' "/root.$cpu_type/root.passwd"; then
        echo "root:vps2arch" | chpasswd
        log_info "root 密码已设置为: vps2arch"
    else
        sed -i '/^root:/d' /etc/shadow
        cat "/root.$cpu_type/root.passwd" >> /etc/shadow
        log_info "已恢复原始 root 密码"
    fi
}

#=============================================================================
# 清理
#=============================================================================

cleanup() {
    log_info "正在清理 bootstrap 环境..."
    mv "/root.$cpu_type/etc/fstab" "/etc/fstab"

    # 复制备份文件到新系统
    cp -a "/root.$cpu_type/network_backup" /root/ 2>/dev/null || true

    # 恢复 SSH 公钥
    if [[ -f "/root.$cpu_type/ssh_backup/authorized_keys" ]]; then
        mkdir -p /root/.ssh
        chmod 700 /root/.ssh
        cp -a "/root.$cpu_type/ssh_backup/authorized_keys" /root/.ssh/
        chmod 600 /root/.ssh/authorized_keys
        log_info "已恢复 SSH authorized_keys"
    fi

    # 卸载 chroot
    awk "/\/root\.$cpu_type/ {print \$2}" /proc/mounts | sort -r | xargs umount -nl 2>/dev/null || true
    rm -rf "/root.$cpu_type/"
}

#=============================================================================
# 配置引导程序
#=============================================================================

configure_bootloader() {
    log_info "正在配置引导程序 ($BOOTLOADER)..."

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
        # 如果使用 eth* 网卡名，禁用新式网卡命名
        grep -q '^[[:space:]]*eth' /proc/net/dev 2>/dev/null && \
            sed -i.bak 's/GRUB_CMDLINE_LINUX_DEFAULT="/&net.ifnames=0 /' /etc/default/grub

        # 使用控制台终端输出
        sed -i.bak 's/^#GRUB_TERMINAL_OUTPUT=console/GRUB_TERMINAL_OUTPUT=console/' /etc/default/grub

        if [ $needs_lvm2 -eq 1 ]; then
            local vg=$(lvs --noheadings "$root_dev" 2>/dev/null | awk '{print $2}')
            root_dev=$(pvs --noheadings 2>/dev/null | awk -v vg="$vg" '($2 == vg) { print $1 }')
        fi

        # 查找物理磁盘
        for dev in $root_dev; do
            tmp=$(lsblk -npsro TYPE,NAME "$dev" 2>/dev/null | awk '($1 == "disk") { print $2}')
            case " $root_devs " in
            *" $tmp "*) ;;
            *) root_devs="${root_devs:+$root_devs }$tmp" ;;
            esac
        done

        case $uefi in
        0)
            # BIOS 模式
            for dev in $root_devs; do
                log_info "正在将 GRUB 安装到 $dev (BIOS 模式)..."
                grub-install --target=i386-pc --recheck --force "$dev"
            done
            ;;
        32|64)
            # UEFI 模式
            log_info "正在安装 GRUB (UEFI 模式)..."
            mkdir -p /boot/efi
            findmnt /boot/efi >/dev/null 2>&1 || {
                # 尝试查找并挂载 EFI 分区
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
                    log_info "已挂载 EFI 分区: $efi_dev"
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
# 配置网络
#=============================================================================

configure_network() {
    log_info "正在配置网络 ($NETWORK)..."

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

        # 检查是否需要静态 IPv6 配置
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
            log_info "已配置静态 IPv6: $ip6"
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

    # 确保新系统 DNS 可用（resolv.conf 可能被 systemd 覆盖为指向未运行的 systemd-resolved 的符号链接）
    if [[ ! -s /etc/resolv.conf ]] || readlink /etc/resolv.conf | grep -q systemd; then
        rm -f /etc/resolv.conf
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\n' \
            > /etc/resolv.conf
    fi
}

#=============================================================================
# 配置 SSH
#=============================================================================

configure_ssh() {
    log_info "正在配置 SSH..."

    # 允许 root 登录
    sed -i '/^#PermitRootLogin\s/s/.*/&\nPermitRootLogin yes/' /etc/ssh/sshd_config

    # 添加附加配置以确保可靠性
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/99-vps2arch.conf << 'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF

    log_info "SSH 配置完成（已允许 root 登录）"
}

#=============================================================================
# 配置区域、时区和自定义设置
#=============================================================================

configure_system() {
    log_info "正在配置区域和时区..."

    # 时区（尽量保留旧系统设置）
    if [[ ! -f /etc/localtime ]]; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    fi

    # 区域设置
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

    # 主机名
    if [[ -n "$ORIG_HOSTNAME" ]] && [[ ! -f /etc/hostname ]]; then
        echo "$ORIG_HOSTNAME" > /etc/hostname
        cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $ORIG_HOSTNAME
EOF
    fi

    # 控制台
    cat > /etc/vconsole.conf << 'EOF'
KEYMAP=us
EOF

    # 常用别名
    cat >> /etc/profile << 'EOF'

# 自定义别名
alias ls='ls --color=auto'
alias ll='ls -la --color=auto'
alias halt='halt -p'
EOF
}

#=============================================================================
# 完成
#=============================================================================

finalize() {
    # OpenVZ 兼容性修复
    if is_openvz; then
        mkdir -p /etc/resolvconf/resolv.conf.d
    fi

    # 运行 reflector 优化镜像源
    if command -v reflector >/dev/null 2>&1; then
        log_info "正在运行 reflector 优化镜像源..."
        reflector -l 35 -p https --sort rate --save /etc/pacman.d/mirrorlist || true
    fi

    cat <<-EOF

	==========================================
	  Arch Linux 安装完成！
	==========================================

	引导程序: $BOOTLOADER
	网络配置: $NETWORK

	root 密码: 沿用原密码（若原系统无密码则为 "vps2arch"）

	网络配置备份保存在: /root/network_backup/

	完成后请重启虚拟机:
	  sync ; reboot -f

	然后使用 root 密码通过 SSH 连接。
	==========================================
	EOF
}

#=============================================================================
# 解析参数
#=============================================================================

while getopts ":b:m:n:h" opt; do
    case $opt in
    b)
        if [ "$OPTARG" != "grub" ] && [ "$OPTARG" != "syslinux" ] && [ "$OPTARG" != "none" ]; then
            echo "无效的引导程序: $OPTARG" >&2
            exit 1
        fi
        BOOTLOADER="$OPTARG"
        ;;
    m)
        mirrors="${mirrors:+$mirrors }$OPTARG"
        ;;
    n)
        if [ "$OPTARG" != "systemd-networkd" ] && [ "$OPTARG" != "netctl" ] && [ "$OPTARG" != "none" ]; then
            echo "无效的网络配置: $OPTARG" >&2
            exit 1
        fi
        NETWORK="$OPTARG"
        ;;
    h)
        cat <<-EOF
			用法: ${0##*/} [选项]

			  选项:
			    -b (grub|syslinux|none)           引导程序（默认: grub）
			    -n (systemd-networkd|netctl|none)  网络配置（默认: systemd-networkd）
			    -m 镜像地址                        镜像 URL（可多次指定）
			    -h                                 显示此帮助

			  注意: OpenVZ 容器中将跳过引导程序安装，网络配置强制使用 netctl。
		EOF
        exit 0
        ;;
    :)
        printf "%s: 选项需要参数 -- '%s'\n" "${0##*/}" "$OPTARG" >&2
        exit 1
        ;;
    ?)
        printf "%s: 无效选项 -- '%s'\n" "${0##*/}" "$OPTARG" >&2
        exit 1
        ;;
    esac
done
shift $((OPTIND - 1))

# 兼容旧版位置参数传入镜像地址
if [[ -z "$mirrors" && -n "$1" ]]; then
    mirrors="$1"
fi

[ -z "$mirrors" ] && mirrors=$(get_worldwide_mirrors)

# 容器环境覆盖设置
if is_openvz; then
    BOOTLOADER=none
    NETWORK=netctl
elif is_lxc; then
    BOOTLOADER=none
fi

#=============================================================================
# 主流程
#=============================================================================

echo "=============================================="
echo "    VPS 转换 Arch Linux 脚本"
echo "=============================================="
echo ""
log_warn "此操作将完全替换当前系统为 Arch Linux！"
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
