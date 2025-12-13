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

# 安装 nano 编辑器
apt-get install -y nano

# 安装 Docker
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=armhf signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu focal stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

# 安装 Xray
wget -q -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v1.8.4/Xray-linux-arm32-v7a.zip
unzip -q /tmp/xray.zip -d /tmp/xray/
mv /tmp/xray/xray /usr/local/bin/
chmod +x /usr/local/bin/xray
mkdir -p /etc/xray /usr/local/share/xray

# 安装 OpenList
echo "正在安装 OpenList for USB包..."
OpenList_VERSION="v4.1.8"
ALIST_URL="https://github.com/OpenListTeam/OpenList/releases/download/v4.1.8/openlist-linux-arm-7.tar.gz"
wget -q -O /tmp/alist.tar.gz "${ALIST_URL}"
tar -xzf /tmp/alist.tar.gz -C /tmp/
mv /tmp/alist /usr/local/bin/openlist
chmod +x /usr/local/bin/openlist

# 创建 OpenList 数据目录
mkdir -p /opt/openlist/data

# 创建 OpenList 配置文件
cat > /opt/openlist/config.json << 'OL_CONFIG'
{
  "force": false,
  "address": "0.0.0.0",
  "port": 5244,
  "site_url": "",
  "cdn": "",
  "jwt_secret": "random_generated_string_here",
  "token_expires_in": 48,
  "database": {
    "type": "sqlite3",
    "host": "",
    "port": 0,
    "user": "",
    "password": "",
    "name": "",
    "db_file": "/opt/openlist/data/data.db",
    "table_prefix": "x_",
    "ssl_mode": ""
  },
  "scheme": {
    "https": false,
    "cert_file": "",
    "key_file": ""
  },
  "temp_dir": "/opt/openlist/data/temp",
  "static_cache_ttl": 60
}
OL_CONFIG

# 安装 v2raya
wget -q -O /tmp/v2raya.deb https://github.com/v2rayA/v2rayA/releases/download/v2.0.5/v2raya_linux_arm32.deb
dpkg -i /tmp/v2raya.deb || apt-get install -f -y

# 基础系统配置
echo "hi3798mv100" > /etc/hostname
echo -e "127.0.0.1\tlocalhost\n127.0.1.1\thi3798mv100" > /etc/hosts
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "root:root123" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# 网络配置 (DHCP)
mkdir -p /etc/network/interfaces.d
echo -e "auto eth0\niface eth0 inet dhcp" > /etc/network/interfaces.d/eth0

# 创建 Xray 配置文件
cat > /etc/xray/config.json << 'XRAY_CONFIG'
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 1080,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
XRAY_CONFIG

# 创建 systemd 服务

# Xray 服务
cat > /etc/systemd/system/xray.service << 'XRAY_SERVICE'
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
XRAY_SERVICE

# OpenList 服务
cat > /etc/systemd/system/openlist.service << 'OL_SERVICE'
[Unit]
Description=OpenList - A file list program that supports multiple storage
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/openlist
Environment=HOME=/opt/openlist
ExecStart=/usr/local/bin/openlist server --data /opt/openlist/data
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
OL_SERVICE

# 初始化 OpenList
# 生成随机的 JWT Secret
RANDOM_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
sed -i "s/random_generated_string_here/${RANDOM_SECRET}/" /opt/openlist/config.json

# 启用服务
systemctl enable docker
systemctl enable v2raya
systemctl enable xray
systemctl enable openlist

echo "✅ USB包专用纯净系统配置完成"
echo "   已安装: nano, docker, Xray, v2raya, OpenList"
echo "   OpenList 将在首次启动时生成管理员密码"

# 深度清理
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /usr/bin/qemu-arm-static

echo "✅ USB包专用纯净系统配置完成，已安装 nano, docker, Xray, v2raya, OpenList"
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
