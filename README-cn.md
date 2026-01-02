# VPS2Arch - VPS 在线转换 Arch Linux 脚本

将任意 Linux VPS 在线转换为 Arch Linux，支持 x86_64 和 ARM64 架构。

[English Documentation](README.md)

## 功能特性

- **多源系统支持**：Debian、Ubuntu、CentOS、RHEL、Fedora、OpenSUSE、Arch Linux
- **多架构支持**：x86_64 (AMD64) 和 aarch64 (ARM64)
- **自动网络配置**：使用 dhcpcd 自动获取网络配置
- **SSH 保持**：自动保留 authorized_keys，支持密码登录
- **UEFI/BIOS 双模式**：自动检测并配置 GRUB 引导
- **静态 busybox**：使用静态编译的 busybox 确保系统替换过程稳定

## 系统要求

- Root 权限
- 至少 1GB 内存
- 至少 5GB 磁盘空间
- 网络连接

## 支持的源系统

| 发行版 | 包管理器 | 状态 |
|--------|----------|------|
| Debian / Ubuntu | apt | ✅ |
| CentOS / RHEL / Rocky / AlmaLinux | yum / dnf | ✅ |
| Fedora | dnf | ✅ |
| OpenSUSE / SLES | zypper | ✅ |
| Arch Linux / Manjaro | pacman | ✅ |

## 支持的目标架构

| 架构 | Bootstrap 来源 | 引导方式 |
|------|----------------|----------|
| x86_64 | Arch Linux | GRUB (BIOS/UEFI) |
| aarch64 | Arch Linux ARM | GRUB (UEFI) |

## 使用方法

### 基本用法

```bash
# 下载脚本
wget https://example.com/vps2arch-cn.sh
chmod +x vps2arch-cn.sh

# 运行（使用默认镜像源）
./vps2arch-cn.sh

# 或指定镜像源
./vps2arch-cn.sh https://mirrors.tuna.tsinghua.edu.cn/archlinux
```

### 执行流程

1. 检测系统架构和发行版
2. 保存当前网络配置和 SSH 密钥
3. 下载 Arch Linux Bootstrap
4. 配置新系统（镜像源、密钥、基础包）
5. 设置网络（dhcpcd）
6. 配置 SSH 和 root 密码
7. 安装 GRUB 引导
8. 替换系统并重启

## 安装的软件包

### 基础包
- base
- linux / linux-aarch64（根据架构）
- linux-firmware
- openssh
- grub（x86_64）/ grub + efibootmgr（ARM64 UEFI）
- dhcpcd

### 工具包
- nano
- wget
- curl
- fastfetch
- btop

## 配置说明

### 网络配置

脚本使用 `dhcpcd` 自动获取网络配置，适用于大多数 VPS 环境。原系统的网络配置会备份到 `/root/network_backup/`。

对于 IPv6 /128 地址（OVH 等云服务商常见），会自动使用 systemd-networkd 配置静态 IPv6。

### SSH 配置

- 自动保留原系统的 `authorized_keys`
- 允许 root 密码登录
- sshd 服务开机自启

### Root 密码

运行脚本时会提示设置 root 密码：
- 输入密码：使用输入的密码
- 直接回车：生成 16 位随机密码（会显示在屏幕上）

### 时区和语言

- 时区：Asia/Shanghai
- 语言：en_US.UTF-8

### Shell 别名

自动添加到 `/etc/profile`：

```bash
alias ls='ls --color=auto'
alias ll='ls -ls --color=auto'
alias dir='dir --color=auto'
alias halt='halt -p'
```

### 登录欢迎

登录时自动运行 `fastfetch` 显示系统信息。

## 镜像源

### x86_64 (Arch Linux)

```
https://mirrors.kernel.org/archlinux
https://mirrors.tuna.tsinghua.edu.cn/archlinux
https://mirrors.ustc.edu.cn/archlinux
https://mirrors.aliyun.com/archlinux
```

### aarch64 (Arch Linux ARM)

```
http://mirror.archlinuxarm.org
https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm
https://mirrors.ustc.edu.cn/archlinuxarm
```

## 故障排除

### 网络不通

1. 检查 dhcpcd 服务状态：
   ```bash
   systemctl status dhcpcd
   ```

2. 查看备份的网络配置：
   ```bash
   cat /root/network_backup/summary.txt
   cat /root/network_backup/ip_route.txt
   ```

3. 手动配置网络（如果 DHCP 不可用）

### SSH 无法连接

1. 检查 sshd 服务：
   ```bash
   systemctl status sshd
   ```

2. 检查防火墙（Arch 默认无防火墙）

3. 使用 VNC/控制台登录排查

### 引导失败

1. 使用救援模式挂载磁盘
2. 检查 `/boot/grub/grub.cfg` 配置
3. 重新运行 `grub-install`

## 注意事项

⚠️ **警告**：此脚本会完全替换当前系统，操作不可逆！

- 运行前请确保已备份重要数据
- 确保有 VNC/IPMI/控制台访问权限（以防 SSH 无法连接）
- 建议先在测试环境验证
- ARM64 非 UEFI 环境可能需要手动配置引导

## 技术细节

### 系统替换原理

1. 下载 Arch Linux Bootstrap 到 `/tmp/vps2arch/`
2. 在 chroot 环境中配置新系统
3. 使用静态编译的 busybox 执行替换操作
4. 删除旧系统文件（保留 /proc /sys /dev /run /tmp /srv）
5. 复制新系统到根目录
6. 通过 sysrq 触发重启

### 为什么使用 busybox

系统替换过程中会删除 `/lib` 等目录，导致动态链接的命令（cp、rm 等）无法执行。使用静态编译的 busybox 可以避免这个问题。

### 动态 busybox 支持

对于无法获取静态 busybox 的平台（如 Arch Linux、CentOS），脚本会自动安装动态版本并拷贝其依赖库到内存中执行。

## 脚本说明

- `vps2arch.sh` - 英文版
- `vps2arch-cn.sh` - 中文版

## 技术支持

- Telegram 群组: https://t.me/OpineWorkOfficial
- Telegram 频道: https://t.me/OpineWorkPublish

## 许可证

GPL-3.0 License

## 贡献

欢迎提交 Issue 和 Pull Request。
