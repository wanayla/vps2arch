#!/bin/bash
#
# vps2arch-cn.sh - 将任意 Linux VPS 在线转换为 Arch Linux
#
# 许可证: GPL-3.0
# 用法: ./vps2arch-cn.sh [镜像地址]
#
# 警告: 此脚本会完全替换当前系统！
#

set -e

#=============================================================================
# 配置区域
#=============================================================================

# Arch Linux 镜像源（可通过参数覆盖）
ARCH_MIRROR="${1:-https://mirrors.kernel.org/archlinux}"

# 工作目录
WORK_DIR="/tmp/vps2arch"

# 架构相关变量（在 check_arch 中设置）
ARCH=""
BOOTSTRAP_URL=""
NEW_ROOT=""

#=============================================================================
# 工具函数
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

# 检查是否为 root 用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 身份运行"
    fi
}

# 检查系统架构
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
            # ARM64 使用 Arch Linux ARM
            BOOTSTRAP_URL="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
            NEW_ROOT="${WORK_DIR}/root"
            ;;
        *)
            log_error "不支持的架构: $arch (仅支持 x86_64 和 aarch64)"
            ;;
    esac
    log_info "系统架构: $ARCH"
}

# 检查是否为虚拟化环境
check_virt() {
    if command -v systemd-detect-virt &>/dev/null; then
        local virt=$(systemd-detect-virt)
        log_info "虚拟化类型: $virt"
    fi
}

# 检测当前系统类型
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
                # 尝试通过包管理器检测
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

    log_info "检测到系统类型: $OS_TYPE (包管理器: $PKG_MANAGER)"

    if [[ "$PKG_MANAGER" == "" ]]; then
        log_error "无法检测系统类型，不支持当前系统"
    fi
}

# 安装依赖包
install_deps() {
    local packages="$@"
    log_info "安装依赖: $packages"

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
            log_error "不支持的包管理器: $PKG_MANAGER"
            ;;
    esac
}

# 安装 busybox（优先静态编译版本）
install_busybox() {
    BUSYBOX_OK=false
    BUSYBOX_STATIC=false

    # Debian/Ubuntu 有静态编译版本
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        log_info "安装 busybox-static (Debian/Ubuntu)..."
        if apt-get install -y busybox-static; then
            if [[ -f /bin/busybox ]]; then
                cp /bin/busybox "${WORK_DIR}/busybox"
                BUSYBOX_OK=true
                BUSYBOX_STATIC=true
                log_info "已安装 busybox-static"
            fi
        fi
    fi

    # OpenSUSE 有静态编译版本
    if [[ "$BUSYBOX_OK" != "true" && "$PKG_MANAGER" == "zypper" ]]; then
        log_info "安装 busybox-static (OpenSUSE)..."
        if zypper install -y busybox-static; then
            local bb=$(command -v busybox 2>/dev/null)
            if [[ -n "$bb" ]]; then
                cp "$bb" "${WORK_DIR}/busybox"
                BUSYBOX_OK=true
                BUSYBOX_STATIC=true
                log_info "已安装 busybox-static"
            fi
        fi
    fi

    # 尝试下载静态编译版本
    if [[ "$BUSYBOX_OK" != "true" ]]; then
        log_info "下载静态编译的 busybox..."

        # 根据架构选择下载地址
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
            log_info "尝试: $url"
            if wget -q --timeout=30 "$url" -O "${WORK_DIR}/busybox" 2>/dev/null; then
                if [[ -s "${WORK_DIR}/busybox" ]]; then
                    BUSYBOX_OK=true
                    BUSYBOX_STATIC=true
                    log_info "下载成功"
                    break
                fi
            fi
        done
    fi

    # 最后尝试：从包管理器安装动态版本
    if [[ "$BUSYBOX_OK" != "true" ]]; then
        log_warn "无法获取静态版本，尝试安装动态版本..."

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
            log_info "已安装动态版本 busybox: $bb"
        fi
    fi

    # 最终检查
    if [[ "$BUSYBOX_OK" != "true" ]]; then
        log_error "无法获取 busybox。请手动下载到 ${WORK_DIR}/busybox"
    fi

    chmod +x "${WORK_DIR}/busybox"

    # 验证是否静态编译
    if file "${WORK_DIR}/busybox" | grep -q "statically linked"; then
        log_info "busybox 是静态编译 ✓"
        BUSYBOX_STATIC=true
    elif ldd "${WORK_DIR}/busybox" 2>&1 | grep -q "not a dynamic"; then
        log_info "busybox 是静态编译 ✓"
        BUSYBOX_STATIC=true
    else
        log_warn "busybox 是动态编译，需要拷贝依赖库"
        BUSYBOX_STATIC=false
    fi

    # 导出变量供后续使用
    export BUSYBOX_STATIC
}

#=============================================================================
# 网络配置保存
#=============================================================================

save_network_config() {
    log_info "保存当前网络配置..."

    mkdir -p "${WORK_DIR}/network_backup"

    # 获取默认网卡
    DEFAULT_IFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

    # 获取网卡 MAC 地址
    if [[ -n "$DEFAULT_IFACE" ]]; then
        MAC_ADDR=$(ip link show "$DEFAULT_IFACE" | grep link/ether | awk '{print $2}')
    fi

    # 获取 IP 地址和掩码
    IP_ADDR=$(ip -4 addr show "$DEFAULT_IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -n1)

    # 获取 IPv6 地址
    IP6_ADDR=$(ip -6 addr show "$DEFAULT_IFACE" scope global | grep -oP '(?<=inet6\s)[0-9a-f:]+/\d+' | head -n1)

    # 获取网关
    GATEWAY=$(ip route | grep default | awk '{print $3}' | head -n1)

    # 获取 IPv6 网关
    GATEWAY6=$(ip -6 route | grep default | awk '{print $3}' | head -n1)

    # 获取 DNS
    if [[ -f /etc/resolv.conf ]]; then
        DNS_SERVERS=$(grep "^nameserver" /etc/resolv.conf | awk '{print $2}' | head -n2)
    fi

    # 获取主机名
    if [[ -f /etc/hostname ]]; then
        HOSTNAME=$(cat /etc/hostname)
    elif command -v hostname &>/dev/null; then
        HOSTNAME=$(hostname)
    else
        HOSTNAME="archlinux"
    fi

    log_info "网卡: $DEFAULT_IFACE"
    log_info "MAC 地址: $MAC_ADDR"
    log_info "IPv4 地址: $IP_ADDR"
    log_info "IPv4 网关: $GATEWAY"
    log_info "IPv6 地址: $IP6_ADDR"
    log_info "IPv6 网关: $GATEWAY6"
    log_info "DNS: $DNS_SERVERS"
    log_info "主机名: $HOSTNAME"

    # 保存完整的网络状态
    ip addr show > "${WORK_DIR}/network_backup/ip_addr.txt"
    ip route show > "${WORK_DIR}/network_backup/ip_route.txt"
    ip -6 route show > "${WORK_DIR}/network_backup/ip6_route.txt" 2>/dev/null || true

    # 复制原系统网络配置文件
    cp -a /etc/resolv.conf "${WORK_DIR}/network_backup/" 2>/dev/null || true
    cp -a /etc/network "${WORK_DIR}/network_backup/" 2>/dev/null || true
    cp -a /etc/netplan "${WORK_DIR}/network_backup/" 2>/dev/null || true
    cp -a /etc/systemd/network "${WORK_DIR}/network_backup/" 2>/dev/null || true
    cp -a /etc/sysconfig/network-scripts "${WORK_DIR}/network_backup/" 2>/dev/null || true

    # 保存配置摘要
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

    log_info "网络配置已完整备份到 ${WORK_DIR}/network_backup/"
}

#=============================================================================
# SSH 配置保存
#=============================================================================

save_ssh_config() {
    log_info "保存 SSH 相关信息..."
    
    mkdir -p "${WORK_DIR}/ssh_backup"
    
    # 只保存 authorized_keys（不保存旧的主机密钥）
    if [[ -f /root/.ssh/authorized_keys ]]; then
        cp -a /root/.ssh/authorized_keys "${WORK_DIR}/ssh_backup/" 2>/dev/null || true
        log_info "已保存 authorized_keys"
    fi
    
    # 保存 root 密码哈希
    ROOT_PASSWORD_HASH=$(grep "^root:" /etc/shadow | cut -d: -f2)
}

#=============================================================================
# 下载并解压 Arch Bootstrap
#=============================================================================

download_bootstrap() {
    log_info "创建工作目录..."
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"
    
    log_info "下载 Arch Linux Bootstrap..."
    log_info "URL: $BOOTSTRAP_URL"
    
    # 安装必要的依赖
    local deps_to_install=""

    # zstd 仅 x86_64 需要（ARM 使用 tar.gz）
    if [[ "$ARCH" == "x86_64" ]] && ! command -v zstd &>/dev/null; then
        deps_to_install+=" zstd"
    fi

    if ! command -v wget &>/dev/null; then
        deps_to_install+=" wget"
    fi

    if [[ -n "$deps_to_install" ]]; then
        install_deps $deps_to_install
    fi

    # 安装 busybox（用于系统替换阶段）
    install_busybox
    
    # 下载 bootstrap
    log_info "下载 Bootstrap: $BOOTSTRAP_URL"
    if [[ "$ARCH" == "x86_64" ]]; then
        if ! wget -q --show-progress "$BOOTSTRAP_URL" -O archlinux-bootstrap.tar.zst; then
            log_error "下载失败，请检查网络或镜像地址"
        fi
        log_info "解压 Bootstrap..."
        tar -I zstd -xf archlinux-bootstrap.tar.zst
    elif [[ "$ARCH" == "aarch64" ]]; then
        if ! wget -q --show-progress "$BOOTSTRAP_URL" -O archlinux-bootstrap.tar.gz; then
            log_error "下载失败，请检查网络或镜像地址"
        fi
        log_info "解压 Bootstrap..."
        mkdir -p "$NEW_ROOT"
        tar -xzf archlinux-bootstrap.tar.gz -C "$NEW_ROOT"
    fi

    if [[ ! -d "$NEW_ROOT" ]]; then
        log_error "解压失败，未找到 $NEW_ROOT 目录"
    fi
    
    log_info "Bootstrap 准备完成"
}

#=============================================================================
# 配置新系统
#=============================================================================

configure_new_system() {
    log_info "配置新系统..."
    
    # 配置 pacman 镜像源
    log_info "配置 pacman 镜像源..."
    if [[ "$ARCH" == "x86_64" ]]; then
        cat > "${NEW_ROOT}/etc/pacman.d/mirrorlist" << EOF
# 镜像源列表
Server = ${ARCH_MIRROR}/\$repo/os/\$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch
Server = https://mirrors.aliyun.com/archlinux/\$repo/os/\$arch
EOF
    elif [[ "$ARCH" == "aarch64" ]]; then
        cat > "${NEW_ROOT}/etc/pacman.d/mirrorlist" << EOF
# Arch Linux ARM 镜像源列表
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/\$arch/\$repo
Server = https://mirrors.ustc.edu.cn/archlinuxarm/\$arch/\$repo
EOF
    fi

    # 配置 DNS（临时，用于 chroot 内联网）
    cat > "${NEW_ROOT}/etc/resolv.conf" << EOF
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

    # 挂载必要的文件系统
    log_info "挂载文件系统..."
    mount --bind "$NEW_ROOT" "$NEW_ROOT"
    mount -t proc /proc "${NEW_ROOT}/proc"
    mount -t sysfs /sys "${NEW_ROOT}/sys"
    mount --rbind /dev "${NEW_ROOT}/dev"
    mount --rbind /run "${NEW_ROOT}/run"
    
    # 确保 pacman 必要目录存在
    log_info "创建 pacman 必要目录..."
    mkdir -p "${NEW_ROOT}/var/lib/pacman/sync"
    mkdir -p "${NEW_ROOT}/var/cache/pacman/pkg"
    mkdir -p "${NEW_ROOT}/var/log"

    # 初始化 pacman 密钥
    log_info "初始化 pacman 密钥..."
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
    
    # 安装基本系统
    log_info "安装基本系统包..."
    if [[ "$ARCH" == "x86_64" ]]; then
        chroot "$NEW_ROOT" /bin/bash -c "
            pacman -Sy --noconfirm base linux linux-firmware openssh grub dhcpcd nano wget curl fastfetch btop ncurses
        "
    elif [[ "$ARCH" == "aarch64" ]]; then
        # ARM64 使用 linux-aarch64 内核，不使用 grub
        chroot "$NEW_ROOT" /bin/bash -c "
            pacman -Sy --noconfirm base linux-aarch64 linux-firmware openssh dhcpcd nano wget curl fastfetch btop ncurses
        "
    fi
}

#=============================================================================
# 配置网络
#=============================================================================

setup_network() {
    log_info "配置网络..."

    # 使用 dhcpcd 管理 IPv4（比 systemd-networkd 更简单可靠）
    # 禁用 systemd-networkd 避免冲突
    chroot "$NEW_ROOT" /bin/bash -c "
        systemctl disable systemd-networkd 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        systemctl enable dhcpcd
    "

    log_info "已启用 dhcpcd 管理 IPv4"

    # 检测是否需要静态 IPv6 配置（/128 地址通常需要静态配置）
    if [[ -n "$IP6_ADDR" && "$IP6_ADDR" == *"/128" ]]; then
        log_info "检测到 /128 IPv6 地址，配置静态 IPv6..."

        # 获取网卡名（新系统可能使用不同的命名）
        # 创建 systemd-networkd 配置仅用于 IPv6
        mkdir -p "${NEW_ROOT}/etc/systemd/network"

        # 创建基于 MAC 地址的网络配置（确保匹配正确的网卡）
        cat > "${NEW_ROOT}/etc/systemd/network/10-ipv6-static.network" << EOF
[Match]
MACAddress=${MAC_ADDR}

[Network]
# IPv4 由 dhcpcd 管理
DHCP=no

# 静态 IPv6 配置
Address=${IP6_ADDR}
Gateway=${GATEWAY6}
IPv6AcceptRA=no

[Route]
# OVH 等云服务商需要先添加网关的主机路由
Destination=${GATEWAY6}/128
Scope=link
EOF

        # 配置 dhcpcd 不管理 IPv6（避免冲突）
        mkdir -p "${NEW_ROOT}/etc/dhcpcd.conf.d"
        cat > "${NEW_ROOT}/etc/dhcpcd.conf.d/10-ipv4-only.conf" << EOF
# 仅使用 dhcpcd 管理 IPv4，IPv6 由 systemd-networkd 管理
noipv6
noipv6rs
EOF

        # 启用 systemd-networkd 用于 IPv6
        chroot "$NEW_ROOT" /bin/bash -c "
            systemctl enable systemd-networkd
        "

        log_info "已配置静态 IPv6: ${IP6_ADDR} -> ${GATEWAY6}"
    fi

    # 配置 resolv.conf
    cat > "${NEW_ROOT}/etc/resolv.conf" << EOF
nameserver 8.8.8.8
nameserver 2001:4860:4860::8888
nameserver 1.1.1.1
EOF
    log_info "已配置 DNS"

    # 设置主机名
    echo "$HOSTNAME" > "${NEW_ROOT}/etc/hostname"

    # 配置 hosts
    cat > "${NEW_ROOT}/etc/hosts" << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}
EOF

    # 复制网络配置备份到新系统（方便排查）
    cp -a "${WORK_DIR}/network_backup" "${NEW_ROOT}/root/" 2>/dev/null || true

    log_info "网络配置完成"
}

#=============================================================================
# 配置 SSH
#=============================================================================

setup_ssh() {
    log_info "配置 SSH..."

    # 创建 sshd 权限分离目录（关键！否则 sshd 无法启动）
    mkdir -p "${NEW_ROOT}/usr/share/empty.sshd"
    chmod 755 "${NEW_ROOT}/usr/share/empty.sshd"

    # 恢复 authorized_keys（使用新系统生成的主机密钥）
    mkdir -p "${NEW_ROOT}/root/.ssh"
    chmod 700 "${NEW_ROOT}/root/.ssh"
    if [[ -f "${WORK_DIR}/ssh_backup/authorized_keys" ]]; then
        cp -a "${WORK_DIR}/ssh_backup/authorized_keys" "${NEW_ROOT}/root/.ssh/"
        chmod 600 "${NEW_ROOT}/root/.ssh/authorized_keys"
        log_info "已恢复 authorized_keys"
    fi
    
    # 设置 root 密码（强制）
    echo ""
    log_info "========== 设置 root 密码 =========="
    echo -n "请输入新系统的 root 密码（直接回车使用随机密码）: "
    read -s NEW_ROOT_PASSWORD
    echo ""

    if [[ -z "$NEW_ROOT_PASSWORD" ]]; then
        # 生成随机密码
        NEW_ROOT_PASSWORD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
        echo ""
        echo "############################################"
        echo "#                                          #"
        echo "#   随机生成的 ROOT 密码（请务必记录）:    #"
        echo "#                                          #"
        echo "#   $NEW_ROOT_PASSWORD               #"
        echo "#                                          #"
        echo "############################################"
        echo ""
        log_warn "请立即记录以上密码！5秒后继续..."
        sleep 5
    fi

    echo "root:${NEW_ROOT_PASSWORD}" | chroot "$NEW_ROOT" chpasswd
    log_info "root 密码已设置"
    
    # 使用新系统默认 sshd_config，添加自定义配置允许 root 密码登录
    mkdir -p "${NEW_ROOT}/etc/ssh/sshd_config.d"
    cat > "${NEW_ROOT}/etc/ssh/sshd_config.d/99-custom.conf" << 'EOF'
# 允许 root 登录
PermitRootLogin yes

# 允许密码认证
PasswordAuthentication yes
EOF
    
    log_info "已配置允许 root 密码登录"
    
    # 启用 SSH 服务（开机自启）
    log_info "启用 SSH 服务..."
    chroot "$NEW_ROOT" /bin/bash -c "
        systemctl enable sshd.service
    "
    log_info "SSH 服务已设置为开机自启"
}

#=============================================================================
# 配置时区和 Locale
#=============================================================================

setup_locale_timezone_alias() {
    log_info "配置时区和 Locale..."
    
    # 设置时区为 Asia/Shanghai
    chroot "$NEW_ROOT" /bin/bash -c "
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        hwclock --systohc
    "
    log_info "时区已设置为 Asia/Shanghai"
    
    # 配置 locale
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "${NEW_ROOT}/etc/locale.gen"
    
    chroot "$NEW_ROOT" /bin/bash -c "
        locale-gen
    "
    
    echo "LANG=en_US.UTF-8" > "${NEW_ROOT}/etc/locale.conf"
    log_info "Locale 已设置为 en_US.UTF-8"

    # 设置控制台配置（键盘布局、字体等）
    cat > "${NEW_ROOT}/etc/vconsole.conf" << 'EOF'
# 键盘布局
KEYMAP=us

# 控制台字体（支持更多字符）
FONT=ter-v16n
FONT_MAP=8859-1
EOF
    log_info "控制台配置已设置（键盘布局: us, 字体: ter-v16n）"

    # 安装 terminus 字体（提供 ter-v16n 等字体）
    chroot "$NEW_ROOT" /bin/bash -c "
        pacman -S --noconfirm terminus-font 2>/dev/null || true
    "

    # 添加常用别名到 /etc/profile
    log_info "添加常用别名..."
    cat >> "${NEW_ROOT}/etc/profile" << 'EOF'

# Custom aliases
alias ls='ls --color=auto'
alias ll='ls -ls --color=auto'
alias dir='dir --color=auto'
alias halt='halt -p'
EOF
    log_info "别名已添加到 /etc/profile"

    # 创建 /root/.bash_profile，登录时显示系统信息
    cat > "${NEW_ROOT}/root/.bash_profile" << 'EOF'
# ~/.bash_profile

# 加载 .bashrc
[[ -f ~/.bashrc ]] && . ~/.bashrc

# 显示系统信息
fastfetch
EOF
    log_info "已配置 /root/.bash_profile（登录时运行 fastfetch）"
}

#=============================================================================
# 配置 fstab
#=============================================================================

setup_fstab() {
    log_info "配置 fstab..."
    
    # 获取根分区信息
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
    
    log_info "根分区: $ROOT_DEV (UUID=$ROOT_UUID, 类型=$ROOT_FSTYPE)"
    
    cat > "${NEW_ROOT}/etc/fstab" << EOF
# /etc/fstab - 静态文件系统信息
# <device>                                <dir>   <type>  <options>       <dump> <pass>
UUID=${ROOT_UUID}   /       ${ROOT_FSTYPE}   defaults        0      1
EOF

    # 检查是否有 swap 分区
    local swap_dev=$(swapon --show=NAME --noheadings 2>/dev/null | head -n1)
    if [[ -n "$swap_dev" ]]; then
        local swap_uuid=$(blkid -s UUID -o value "$swap_dev")
        echo "UUID=${swap_uuid}   none    swap    defaults        0      0" >> "${NEW_ROOT}/etc/fstab"
    fi
}

#=============================================================================
# 安装 Bootloader
#=============================================================================

setup_bootloader() {
    log_info "配置 Bootloader..."

    # 获取根分区信息
    ROOT_DEV=$(findmnt -n -o SOURCE /)
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
    ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
    BOOT_DISK=$(lsblk -no PKNAME "$ROOT_DEV" | head -n1)
    BOOT_DISK="/dev/${BOOT_DISK}"
    log_info "启动磁盘: $BOOT_DISK"
    log_info "根分区 UUID: $ROOT_UUID"
    log_info "根分区文件系统: $ROOT_FSTYPE"

    # 检测内核文件名
    if [[ "$ARCH" == "x86_64" ]]; then
        KERNEL_FILE="vmlinuz-linux"
    else
        KERNEL_FILE="Image"
    fi

    # 生成 GRUB 配置的函数
    generate_grub_config() {
        local target_file="$1"
        local kernel="$2"
        cat > "$target_file" << GRUBCFG
# GRUB 配置文件
# 由 vps2arch 自动生成

set default=0
set timeout=5

# 加载必要的模块
insmod part_gpt
insmod part_msdos
insmod ${ROOT_FSTYPE}

menuentry 'Arch Linux' --class arch --class gnu-linux --class os {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/${kernel} root=UUID=${ROOT_UUID} rw quiet
    initrd /boot/initramfs-linux.img
}

menuentry 'Arch Linux (fallback initramfs)' --class arch --class gnu-linux --class os {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    linux /boot/${kernel} root=UUID=${ROOT_UUID} rw quiet
    initrd /boot/initramfs-linux-fallback.img
}
GRUBCFG
    }

    if [[ "$ARCH" == "x86_64" ]]; then
        # 检测是否有 EFI 支持
        if [[ -d /sys/firmware/efi ]]; then
            log_info "检测到 UEFI 启动模式"

            # 查找 EFI 分区
            EFI_DEV=""

            # 方法1: 检查当前挂载的 EFI 分区
            EFI_DEV=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null)

            # 方法2: 检查 /boot 是否是 EFI 分区
            if [[ -z "$EFI_DEV" ]]; then
                local boot_fstype=$(findmnt -n -o FSTYPE /boot 2>/dev/null)
                if [[ "$boot_fstype" == "vfat" ]]; then
                    EFI_DEV=$(findmnt -n -o SOURCE /boot 2>/dev/null)
                fi
            fi

            # 方法3: 通过分区类型查找 EFI 分区
            if [[ -z "$EFI_DEV" ]]; then
                EFI_DEV=$(blkid -t TYPE="vfat" | grep -i "EFI\|esp" | cut -d: -f1 | head -n1)
            fi

            # 方法4: 通过 GPT 分区标签查找
            if [[ -z "$EFI_DEV" ]]; then
                for part in $(lsblk -ln -o NAME,PARTTYPE | grep -i "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" | awk '{print $1}'); do
                    EFI_DEV="/dev/$part"
                    break
                done
            fi

            # 方法5: 尝试常见位置
            if [[ -z "$EFI_DEV" ]]; then
                for dev in /dev/sda1 /dev/sda15 /dev/vda1 /dev/vda15 /dev/nvme0n1p1 /dev/nvme0n1p15; do
                    if [[ -b "$dev" ]]; then
                        local fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null)
                        if [[ "$fstype" == "vfat" ]]; then
                            EFI_DEV="$dev"
                            log_info "通过常见位置找到 EFI 分区: $EFI_DEV"
                            break
                        fi
                    fi
                done
            fi

            if [[ -n "$EFI_DEV" ]]; then
                log_info "EFI 分区: $EFI_DEV"
                EFI_UUID=$(blkid -s UUID -o value "$EFI_DEV")
                log_info "EFI 分区 UUID: $EFI_UUID"

                # 挂载 EFI 分区到新系统
                mkdir -p "${NEW_ROOT}/boot/efi"
                mount "$EFI_DEV" "${NEW_ROOT}/boot/efi"

                # 添加 EFI 到 fstab
                if ! grep -q "$EFI_UUID" "${NEW_ROOT}/etc/fstab"; then
                    echo "UUID=${EFI_UUID}   /boot/efi   vfat    umask=0077      0      2" >> "${NEW_ROOT}/etc/fstab"
                fi

                # 安装 GRUB EFI
                log_info "安装 GRUB EFI..."
                chroot "$NEW_ROOT" /bin/bash -c "
                    pacman -S --noconfirm efibootmgr dosfstools
                    # 安装到标准 EFI 路径
                    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch --removable 2>&1 || true
                    # 同时尝试非 removable 模式
                    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch 2>&1 || true
                "

                # 生成根分区的 GRUB 配置
                log_info "生成 GRUB 配置..."
                mkdir -p "${NEW_ROOT}/boot/grub"
                generate_grub_config "${NEW_ROOT}/boot/grub/grub.cfg" "$KERNEL_FILE"

                # 在 EFI 分区也放置完整的 grub.cfg（关键修复！）
                log_info "在 EFI 分区创建 GRUB 配置..."

                # EFI/arch 目录（非 removable 模式）
                mkdir -p "${NEW_ROOT}/boot/efi/EFI/arch"
                generate_grub_config "${NEW_ROOT}/boot/efi/EFI/arch/grub.cfg" "$KERNEL_FILE"

                # EFI/BOOT 目录（removable 模式 fallback）
                mkdir -p "${NEW_ROOT}/boot/efi/EFI/BOOT"
                generate_grub_config "${NEW_ROOT}/boot/efi/EFI/BOOT/grub.cfg" "$KERNEL_FILE"

                # 验证 EFI 文件是否存在
                log_info "验证 EFI 启动文件..."
                if [[ -f "${NEW_ROOT}/boot/efi/EFI/BOOT/BOOTX64.EFI" ]]; then
                    log_info "找到 EFI/BOOT/BOOTX64.EFI ✓"
                else
                    log_warn "未找到 EFI/BOOT/BOOTX64.EFI，尝试复制..."
                    if [[ -f "${NEW_ROOT}/boot/efi/EFI/arch/grubx64.efi" ]]; then
                        cp "${NEW_ROOT}/boot/efi/EFI/arch/grubx64.efi" "${NEW_ROOT}/boot/efi/EFI/BOOT/BOOTX64.EFI"
                        log_info "已复制 grubx64.efi 到 BOOTX64.EFI"
                    fi
                fi

                # 列出 EFI 分区内容用于调试
                log_info "EFI 分区内容:"
                find "${NEW_ROOT}/boot/efi" -type f 2>/dev/null | head -20

                # 备份 EFI 内容到工作目录（关键！在卸载前备份）
                log_info "备份 EFI 内容到工作目录..."
                mkdir -p "${WORK_DIR}/efi_content"
                cp -a "${NEW_ROOT}/boot/efi/EFI" "${WORK_DIR}/efi_content/" 2>/dev/null || true

                # 保存 EFI 设备路径
                echo "$EFI_DEV" > "${WORK_DIR}/efi_device"

                # 卸载 EFI 分区
                sync
                umount "${NEW_ROOT}/boot/efi" 2>/dev/null || true

                log_info "UEFI GRUB 配置完成"
            else
                log_error "未找到 EFI 分区！UEFI 系统需要 EFI 分区才能启动"
            fi
        else
            # BIOS 模式
            log_info "检测到 BIOS 启动模式，安装 GRUB..."
            chroot "$NEW_ROOT" /bin/bash -c "
                grub-install --target=i386-pc ${BOOT_DISK}
            "

            # 生成 GRUB 配置
            log_info "生成 GRUB 配置..."
            mkdir -p "${NEW_ROOT}/boot/grub"
            generate_grub_config "${NEW_ROOT}/boot/grub/grub.cfg" "$KERNEL_FILE"

            log_info "BIOS GRUB 配置完成"
        fi

    elif [[ "$ARCH" == "aarch64" ]]; then
        # ARM64
        if [[ -d /sys/firmware/efi ]]; then
            log_info "ARM64 UEFI 模式，安装 GRUB..."

            # 查找 EFI 分区（与 x86_64 相同的逻辑）
            EFI_DEV=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null)
            if [[ -z "$EFI_DEV" ]]; then
                EFI_DEV=$(blkid -t TYPE="vfat" | grep -i "EFI\|esp" | cut -d: -f1 | head -n1)
            fi
            if [[ -z "$EFI_DEV" ]]; then
                for dev in /dev/sda1 /dev/sda15 /dev/vda1 /dev/vda15; do
                    if [[ -b "$dev" ]] && [[ "$(blkid -s TYPE -o value "$dev" 2>/dev/null)" == "vfat" ]]; then
                        EFI_DEV="$dev"
                        break
                    fi
                done
            fi

            if [[ -n "$EFI_DEV" ]]; then
                log_info "EFI 分区: $EFI_DEV"
                EFI_UUID=$(blkid -s UUID -o value "$EFI_DEV")

                mkdir -p "${NEW_ROOT}/boot/efi"
                mount "$EFI_DEV" "${NEW_ROOT}/boot/efi"

                if ! grep -q "$EFI_UUID" "${NEW_ROOT}/etc/fstab"; then
                    echo "UUID=${EFI_UUID}   /boot/efi   vfat    umask=0077      0      2" >> "${NEW_ROOT}/etc/fstab"
                fi

                chroot "$NEW_ROOT" /bin/bash -c "
                    pacman -S --noconfirm grub efibootmgr dosfstools
                    grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=arch --removable 2>&1 || true
                    grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=arch 2>&1 || true
                "

                # 生成配置
                log_info "生成 ARM64 GRUB 配置..."
                mkdir -p "${NEW_ROOT}/boot/grub"
                generate_grub_config "${NEW_ROOT}/boot/grub/grub.cfg" "$KERNEL_FILE"

                # EFI 分区配置
                mkdir -p "${NEW_ROOT}/boot/efi/EFI/arch"
                generate_grub_config "${NEW_ROOT}/boot/efi/EFI/arch/grub.cfg" "$KERNEL_FILE"

                mkdir -p "${NEW_ROOT}/boot/efi/EFI/BOOT"
                generate_grub_config "${NEW_ROOT}/boot/efi/EFI/BOOT/grub.cfg" "$KERNEL_FILE"

                # 验证并复制 EFI 文件
                if [[ ! -f "${NEW_ROOT}/boot/efi/EFI/BOOT/BOOTAA64.EFI" ]]; then
                    if [[ -f "${NEW_ROOT}/boot/efi/EFI/arch/grubaa64.efi" ]]; then
                        cp "${NEW_ROOT}/boot/efi/EFI/arch/grubaa64.efi" "${NEW_ROOT}/boot/efi/EFI/BOOT/BOOTAA64.EFI"
                    fi
                fi

                # 列出 EFI 分区内容用于调试
                log_info "ARM64 EFI 分区内容:"
                find "${NEW_ROOT}/boot/efi" -type f 2>/dev/null | head -20

                # 备份 EFI 内容到工作目录（关键！在卸载前备份）
                log_info "备份 EFI 内容到工作目录..."
                mkdir -p "${WORK_DIR}/efi_content"
                cp -a "${NEW_ROOT}/boot/efi/EFI" "${WORK_DIR}/efi_content/" 2>/dev/null || true

                # 保存 EFI 设备路径
                echo "$EFI_DEV" > "${WORK_DIR}/efi_device"

                sync
                umount "${NEW_ROOT}/boot/efi" 2>/dev/null || true

                log_info "ARM64 UEFI GRUB 配置完成"
            else
                log_error "未找到 EFI 分区！"
            fi
        else
            log_warn "ARM64 非 UEFI 模式，跳过 bootloader 配置"
        fi
    fi
}

#=============================================================================
# 替换系统
#=============================================================================

replace_system() {
    log_info "准备替换系统..."
    log_warn "这是不可逆操作！5秒后开始..."
    sleep 5

    # 同步文件系统
    sync

    # 创建内存临时目录
    RAMDIR="/srv/vps2arch_exec"

    # 先卸载可能存在的旧挂载
    umount "$RAMDIR" 2>/dev/null || true
    rm -rf "$RAMDIR" 2>/dev/null || true

    mkdir -p "$RAMDIR"
    mount -t tmpfs -o size=200M tmpfs "$RAMDIR" || log_error "挂载 tmpfs 失败"
    log_info "tmpfs 已挂载到 $RAMDIR"

    # ========== 关键：处理 EFI 分区 ==========
    EFI_PART_DEV=""
    if [[ -d /sys/firmware/efi ]]; then
        log_info "准备 EFI 分区数据..."

        # 从 setup_bootloader 保存的文件读取 EFI 设备路径
        if [[ -f "${WORK_DIR}/efi_device" ]]; then
            EFI_PART_DEV=$(cat "${WORK_DIR}/efi_device")
            log_info "EFI 分区设备（从配置读取）: $EFI_PART_DEV"
        fi

        # 如果没找到，尝试其他方法
        if [[ -z "$EFI_PART_DEV" ]]; then
            EFI_PART_DEV=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || findmnt -n -o SOURCE /boot 2>/dev/null | head -n1)
        fi

        if [[ -z "$EFI_PART_DEV" ]]; then
            for dev in /dev/sda1 /dev/sda15 /dev/vda1 /dev/vda15 /dev/nvme0n1p1 /dev/nvme0n1p15; do
                if [[ -b "$dev" ]] && [[ "$(blkid -s TYPE -o value "$dev" 2>/dev/null)" == "vfat" ]]; then
                    EFI_PART_DEV="$dev"
                    break
                fi
            done
        fi

        if [[ -n "$EFI_PART_DEV" ]]; then
            log_info "EFI 分区设备: $EFI_PART_DEV"

            # 从 WORK_DIR 复制 EFI 备份到 RAMDIR（setup_bootloader 已经备份过）
            log_info "复制 EFI 内容到内存..."
            mkdir -p "$RAMDIR/efi_backup"

            if [[ -d "${WORK_DIR}/efi_content/EFI" ]]; then
                cp -a "${WORK_DIR}/efi_content/EFI" "$RAMDIR/efi_backup/"
                log_info "从工作目录复制 EFI 内容成功"
            else
                log_warn "工作目录中没有 EFI 备份，尝试从挂载点获取..."
                mkdir -p /tmp/efi_mount
                mount "$EFI_PART_DEV" /tmp/efi_mount 2>/dev/null || true
                if [[ -d /tmp/efi_mount/EFI ]]; then
                    cp -a /tmp/efi_mount/EFI "$RAMDIR/efi_backup/"
                    log_info "从挂载点复制 EFI 内容"
                fi
                umount /tmp/efi_mount 2>/dev/null || true
            fi

            # 验证备份
            if [[ -d "$RAMDIR/efi_backup/EFI" ]]; then
                log_info "EFI 备份内容:"
                find "$RAMDIR/efi_backup" -type f 2>/dev/null | head -15
            else
                log_error "EFI 备份失败！无法继续"
            fi

            # 卸载所有 EFI 相关挂载点
            umount "${NEW_ROOT}/boot/efi" 2>/dev/null || true
            umount /boot/efi 2>/dev/null || true
            umount /boot 2>/dev/null || true

            log_info "EFI 数据已准备好"
        else
            log_error "未找到 EFI 分区！UEFI 系统无法启动"
        fi
    fi

    # 保存 EFI 设备路径供 do_replace.sh 使用
    echo "$EFI_PART_DEV" > "$RAMDIR/efi_device"

    # 复制 busybox 到内存
    log_info "复制 busybox 到内存..."
    cp "${WORK_DIR}/busybox" "$RAMDIR/busybox" || log_error "复制 busybox 失败"
    chmod +x "$RAMDIR/busybox"

    # 如果是动态编译的 busybox，需要拷贝依赖库
    if [[ "$BUSYBOX_STATIC" != "true" ]]; then
        log_info "busybox 是动态编译，拷贝依赖库..."

        # 获取动态链接器路径
        LD_LINUX=""
        for ld in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 /lib/ld-linux-aarch64.so.1 /lib64/ld-linux-aarch64.so.1; do
            if [[ -f "$ld" ]]; then
                LD_LINUX="$ld"
                break
            fi
        done

        if [[ -z "$LD_LINUX" ]]; then
            log_error "找不到动态链接器"
        fi

        # 复制动态链接器
        cp -L "$LD_LINUX" "$RAMDIR/ld-linux.so"
        chmod +x "$RAMDIR/ld-linux.so"
        log_info "已复制动态链接器: $LD_LINUX"

        # 复制 busybox 的依赖库
        mkdir -p "$RAMDIR/lib"
        ldd "${WORK_DIR}/busybox" 2>/dev/null | while read line; do
            # 提取库文件路径
            lib=$(echo "$line" | grep -oE '/[^ ]+' | head -1)
            if [[ -n "$lib" && -f "$lib" ]]; then
                cp -L "$lib" "$RAMDIR/lib/" 2>/dev/null || true
                log_info "  复制库: $(basename $lib)"
            fi
        done

        # 设置库路径
        export LD_LIBRARY_PATH="$RAMDIR/lib"
        BUSYBOX_CMD="$RAMDIR/ld-linux.so --library-path $RAMDIR/lib $RAMDIR/busybox"
    else
        BUSYBOX_CMD="$RAMDIR/busybox"
    fi

    # 测试 busybox
    log_info "测试 busybox..."
    if ! $BUSYBOX_CMD echo "busybox test ok"; then
        log_error "busybox 无法执行"
    fi
    log_info "busybox 测试通过"

    # 创建替换脚本
    if [[ "$BUSYBOX_STATIC" == "true" ]]; then
        # 静态版本：直接使用 busybox
        cat > "$RAMDIR/do_replace.sh" << 'REPLACE_SCRIPT'
#!/srv/vps2arch_exec/busybox sh

RAMDIR="/srv/vps2arch_exec"
BB="$RAMDIR/busybox"
REPLACE_SCRIPT
    else
        # 动态版本：使用动态链接器
        cat > "$RAMDIR/do_replace.sh" << 'REPLACE_SCRIPT'
#!/srv/vps2arch_exec/ld-linux.so --library-path /srv/vps2arch_exec/lib /srv/vps2arch_exec/busybox sh

RAMDIR="/srv/vps2arch_exec"
BB="$RAMDIR/ld-linux.so --library-path $RAMDIR/lib $RAMDIR/busybox"
REPLACE_SCRIPT
    fi

    # 追加公共脚本内容
    cat >> "$RAMDIR/do_replace.sh" << REPLACE_SCRIPT

NEW_ROOT="$NEW_ROOT"
EFI_DEV="\$(cat \$RAMDIR/efi_device 2>/dev/null)"

echo "========== 开始系统替换 =========="

# 验证新系统文件存在
if [ ! -d "\${NEW_ROOT}/bin" ]; then
    echo "错误: 新系统文件不存在，中止操作"
    exit 1
fi
echo "新系统文件验证通过"

# 切换到根目录
cd /

echo "删除旧系统文件..."
# 删除旧系统文件（保留必要目录）
for item in /*; do
    case "\$item" in
        /proc|/sys|/dev|/run|/tmp|/mnt|/srv)
            continue
            ;;
        *)
            echo "删除: \$item"
            \$BB rm -rf "\$item" 2>/dev/null || true
            ;;
    esac
done

echo "复制新系统..."
# 复制新系统
\$BB cp -a "\${NEW_ROOT}"/* /

echo "同步磁盘..."
\$BB sync

# ========== 关键：恢复 EFI 分区内容 ==========
if [ -n "\$EFI_DEV" ] && [ -d "\$RAMDIR/efi_backup/EFI" ]; then
    echo "恢复 EFI 分区内容..."
    echo "EFI 设备: \$EFI_DEV"

    # 创建挂载点
    \$BB mkdir -p /boot/efi

    # 挂载 EFI 分区
    \$BB mount -t vfat "\$EFI_DEV" /boot/efi
    if [ \$? -eq 0 ]; then
        echo "EFI 分区挂载成功"

        # 清空 EFI 分区（保留 NvVars 等系统文件）
        \$BB rm -rf /boot/efi/EFI 2>/dev/null || true

        # 复制 EFI 内容
        \$BB cp -a "\$RAMDIR/efi_backup/EFI" /boot/efi/
        \$BB sync

        # 验证
        echo "EFI 分区恢复后内容:"
        \$BB ls -la /boot/efi/EFI/ 2>/dev/null || echo "(无法列出)"
        \$BB ls -la /boot/efi/EFI/BOOT/ 2>/dev/null || echo "(无法列出 BOOT)"

        # 卸载
        \$BB umount /boot/efi
        echo "EFI 分区恢复完成"
    else
        echo "警告: EFI 分区挂载失败！"
    fi
else
    echo "跳过 EFI 恢复（非 UEFI 或无备份）"
fi

echo "最终同步..."
\$BB sync
\$BB sleep 1
\$BB sync

# 重启
echo "========== 系统替换完成 =========="
echo "3秒后重启..."
\$BB sleep 3
echo b > /proc/sysrq-trigger
REPLACE_SCRIPT

    chmod +x "$RAMDIR/do_replace.sh"

    # 卸载 chroot 挂载点
    umount -l "${NEW_ROOT}/dev" 2>/dev/null || true
    umount -l "${NEW_ROOT}/run" 2>/dev/null || true
    umount -l "${NEW_ROOT}/sys" 2>/dev/null || true
    umount -l "${NEW_ROOT}/proc" 2>/dev/null || true
    umount -l "$NEW_ROOT" 2>/dev/null || true

    # 执行替换
    log_info "开始替换系统..."

    if [[ "$BUSYBOX_STATIC" == "true" ]]; then
        log_info "使用静态 busybox 执行替换脚本"
        exec "$RAMDIR/busybox" sh "$RAMDIR/do_replace.sh"
    else
        log_info "使用动态 busybox + ld-linux 执行替换脚本"
        exec "$RAMDIR/ld-linux.so" --library-path "$RAMDIR/lib" "$RAMDIR/busybox" sh "$RAMDIR/do_replace.sh"
    fi
}

#=============================================================================
# 主函数
#=============================================================================

main() {
    echo "=============================================="
    echo "    VPS to Arch Linux 转换脚本"
    echo "=============================================="
    echo ""
    
    log_warn "此脚本将完全替换当前系统为 Arch Linux"
    log_warn "请确保已备份重要数据！"
    echo ""
    
    read -p "确定要继续吗？(输入 YES 确认): " confirm
    if [[ "$confirm" != "YES" ]]; then
        log_info "操作已取消"
        exit 0
    fi
    
    # 执行检查
    check_root
    check_arch
    check_virt
    detect_os

    # 保存配置
    save_network_config
    save_ssh_config
    
    # 下载并配置
    download_bootstrap
    configure_new_system
    setup_locale_timezone_alias
    setup_network
    setup_ssh
    setup_fstab
    setup_bootloader
    
    # 替换系统
    replace_system
}

# 运行主函数
main "$@"
