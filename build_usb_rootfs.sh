#!/bin/bash
# build_usb_rootfs.sh - 为海思USB刷机包构建纯净Ubuntu系统
set -e

echo "=== 开始为USB刷机包构建纯净根文件系统 ==="

# 1. 准备工作目录
ROOTFS_DIR=$(pwd)/usb_pure_rootfs
sudo rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

# 2. 下载并解压最干净的 Ubuntu Base 20.04 (armhf)
echo "下载官方 Ubuntu Base..."
wget -q -c https://cdimage.ubuntu.com/ubuntu-base/releases/20.04/release/ubuntu-base-20.04.5-base-armhf.tar.gz
sudo tar -xpf ubuntu-base-20.04.5-base-armhf.tar.gz -C "$ROOTFS_DIR"

# 3. 准备Chroot环境
echo "准备Chroot环境..."
sudo cp /usr/bin/qemu-arm-static "$ROOTFS_DIR/usr/bin/"
sudo cp /etc/resolv.conf "$ROOTFS_DIR/etc/"

# 挂载虚拟文件系统
sudo mount -t proc /proc "$ROOTFS_DIR/proc"
sudo mount -t sysfs /sys "$ROOTFS_DIR/sys"
sudo mount -o bind /dev "$ROOTFS_DIR/dev"
sudo mount -o bind /dev/pts "$ROOTFS_DIR/dev/pts"

# 4. 创建在Chroot内部执行的配置脚本
cat > /tmp/usb_chroot_install.sh << 'INNER_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

echo "（USB包）配置软件源与系统..."
# 挂载tmpfs，防止空间不足
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /var/cache/apt/archives

# 配置国内软件源
cat > /etc/apt/sources.list << 'SOURCES'
deb http://repo.huaweicloud.com/ubuntu-ports/ focal main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu-ports/ focal-updates main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu-ports/ focal-security main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu-ports/ focal-backports main restricted universe multiverse
SOURCES

# 更新并安装最核心的软件包
apt-get update
apt-get install -y systemd systemd-sysv dbus
apt-get install -y ifupdown net-tools iputils-ping openssh-server ssh sudo
apt-get install -y vim-tiny wget curl cron rsyslog bash-completion

# 基础系统配置
echo "hi3798mv100" > /etc/hostname
echo -e "127.0.0.1\tlocalhost\n127.0.1.1\thi3798mv100" > /etc/hosts
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "root:root123" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# 网络配置 (DHCP)
mkdir -p /etc/network/interfaces.d
echo -e "auto eth0\niface eth0 inet dhcp" > /etc/network/interfaces.d/eth0

# 深度清理
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /usr/bin/qemu-arm-static

echo "✅ USB包专用纯净系统配置完成"
INNER_EOF

sudo chmod +x /tmp/usb_chroot_install.sh
sudo cp /tmp/usb_chroot_install.sh "$ROOTFS_DIR/tmp/"

# 5. 执行Chroot脚本
echo "在Chroot中执行安装脚本..."
sudo chroot "$ROOTFS_DIR" /bin/bash -c "/tmp/usb_chroot_install.sh"

# 6. 卸载环境
sudo umount -lf "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
sudo umount -lf "$ROOTFS_DIR/dev" 2>/dev/null || true
sudo umount -lf "$ROOTFS_DIR/sys" 2>/dev/null || true
sudo umount -lf "$ROOTFS_DIR/proc" 2>/dev/null || true

echo "=== USB刷机包纯净根文件系统构建完成 ==="
