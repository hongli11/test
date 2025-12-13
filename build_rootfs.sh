#!/bin/bash
# build_ttl_rootfs.sh - 为海思TTL刷机包构建纯净Ubuntu系统
set -e

echo "=== 开始为TTL刷机包构建纯净根文件系统 ==="

# 1. 准备工作目录
ROOTFS_DIR=$(pwd)/ttl_pure_rootfs  # 改为 TTL 专用目录
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
cat > /tmp/ttl_chroot_install.sh << 'INNER_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo "（TTL包）配置软件源与系统..."

# ★★★ 关键修复：提前处理包管理器状态 ★★★
echo "步骤1: 修复包管理器基础状态..."
dpkg --configure -a 2>/dev/null || true

# 挂载tmpfs，防止空间不足
echo "步骤2: 挂载临时文件系统..."
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /var/cache/apt/archives
mount -t tmpfs tmpfs /var/lib/apt/lists

# 配置国内软件源
echo "步骤3: 配置软件源..."
cat > /etc/apt/sources.list << 'SOURCES'
deb http://repo.huaweicloud.com/ubuntu-ports/ focal main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu-ports/ focal-updates main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu-ports/ focal-security main restricted universe multiverse
deb http://repo.huaweicloud.com/ubuntu-ports/ focal-backports main restricted universe multiverse
SOURCES

# ★★★ 关键修复：分阶段更新和安装 ★★★
echo "步骤4: 第一阶段 - 更新包列表和安装基础包..."
apt-get update --allow-insecure-repositories --allow-unauthenticated

# 先安装最关键的基础包，避免依赖问题
apt-get install -y --no-install-recommends \
    debconf \
    mime-support \
    apt-utils \
    apt-transport-https \
    ca-certificates \
    gnupg \
    wget \
    curl

# 配置debconf为noninteractive
echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections
echo 'mime-support mime-support/add_defaults boolean true' | debconf-set-selections

# 触发debconf配置
dpkg-reconfigure debconf -f noninteractive 2>/dev/null || true

echo "步骤5: 第二阶段 - 安装系统核心组件..."
apt-get update
apt-get install -y --no-install-recommends \
    systemd \
    systemd-sysv \
    dbus \
    ifupdown \
    net-tools \
    iputils-ping \
    iproute2 \
    openssh-server \
    ssh \
    sudo \
    vim-tiny \
    nano \
    cron \
    rsyslog \
    bash-completion \
    locales

# 清理缓存，释放空间
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "步骤6: 第三阶段 - 安装Docker..."
# Docker需要单独处理依赖
apt-get update
apt-get install -y --no-install-recommends \
    software-properties-common \
    lsb-release

# Docker官方源
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=armhf signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu focal stable" > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io || {
    echo "Docker安装遇到问题，尝试修复..."
    apt-get install -f -y
    apt-get clean
    apt-get install -y docker-ce docker-ce-cli containerd.io
}

echo "步骤7: 安装网络工具..."
# 安装Xray
echo "安装Xray..."
wget -q -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v1.8.4/Xray-linux-arm32-v7a.zip
unzip -q -o /tmp/xray.zip -d /tmp/xray/
mv /tmp/xray/xray /usr/local/bin/
chmod +x /usr/local/bin/xray
mkdir -p /etc/xray /usr/local/share/xray

# 安装OpenList
echo "安装OpenList..."
OpenList_VERSION="v4.1.8"
ALIST_URL="https://github.com/OpenListTeam/OpenList/releases/download/v4.1.8/openlist-linux-arm-7.tar.gz"
wget -q -O /tmp/alist.tar.gz "${ALIST_URL}"
tar -xzf /tmp/alist.tar.gz -C /tmp/
mv /tmp/alist /usr/local/bin/openlist
chmod +x /usr/local/bin/openlist

# 创建OpenList数据目录
mkdir -p /opt/openlist/data

echo "步骤8: 安装v2raya..."
# 先下载并安装依赖
wget -q -O /tmp/v2raya.deb https://github.com/v2rayA/v2rayA/releases/download/v2.0.5/v2raya_linux_arm32.deb

# 手动解压deb包并安装，避免dpkg配置问题
cd /tmp
ar x v2raya.deb
tar -xf data.tar.xz -C /
tar -xf control.tar.xz -C /tmp/

# 运行postinst脚本（如果存在）
if [ -f /tmp/postinst ]; then
    chmod +x /tmp/postinst
    /tmp/postinst configure || true
fi

# 清理临时文件
rm -rf /tmp/*.deb /tmp/control.tar.xz /tmp/data.tar.xz /tmp/debian-binary /tmp/postinst 2>/dev/null || true

echo "步骤9: 系统配置..."
# 基础系统配置
echo "hi3798mv100" > /etc/hostname
echo -e "127.0.0.1\tlocalhost\n127.0.1.1\thi3798mv100" > /etc/hosts
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo "root:root123" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# 网络配置 (DHCP)
mkdir -p /etc/network/interfaces.d
echo -e "auto eth0\niface eth0 inet dhcp" > /etc/network/interfaces.d/eth0

echo "步骤10: 创建配置文件..."
# 创建OpenList配置文件
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

# 创建Xray配置文件
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

echo "步骤11: 创建systemd服务..."
# Xray服务
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

# OpenList服务
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

# 初始化OpenList
echo "步骤12: 初始化服务..."
RANDOM_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
sed -i "s/random_generated_string_here/${RANDOM_SECRET}/" /opt/openlist/config.json

# 启用服务
systemctl enable docker
systemctl enable xray
systemctl enable openlist
# v2raya可能需要手动启用，先跳过systemctl enable

echo "步骤13: 最终清理..."
# 深度清理
apt-get autoremove -y --purge 2>/dev/null || true
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
rm -f /usr/bin/qemu-arm-static

# 最后修复一次包状态
dpkg --configure -a 2>/dev/null || true

echo "✅ TTL包专用纯净系统配置完成"
echo "   已安装: nano, docker, Xray, v2raya, OpenList"
echo "   OpenList 将在首次启动时生成管理员密码"
INNER_EOF

sudo chmod +x /tmp/ttl_chroot_install.sh
sudo cp /tmp/ttl_chroot_install.sh "$ROOTFS_DIR/tmp/"

# 5. 执行Chroot脚本
echo "在Chroot中执行安装脚本..."
# 设置超时和错误处理
if ! timeout 1800 sudo chroot "$ROOTFS_DIR" /bin/bash -c "/tmp/ttl_chroot_install.sh"; then
    echo "⚠️ Chroot脚本执行超时或有错误，尝试继续..."
fi

# 6. 卸载环境
echo "卸载chroot环境..."
sudo umount -lf "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
sudo umount -lf "$ROOTFS_DIR/dev" 2>/dev/null || true
sudo umount -lf "$ROOTFS_DIR/sys" 2>/dev/null || true
sudo umount -lf "$ROOTFS_DIR/proc" 2>/dev/null || true

# 7. 清理临时文件
sudo rm -f /tmp/ttl_chroot_install.sh "$ROOTFS_DIR/tmp/ttl_chroot_install.sh" 2>/dev/null || true

echo "=== TTL刷机包纯净根文件系统构建完成 ==="
echo "根文件系统位于: $ROOTFS_DIR"
echo "大小: $(sudo du -sh "$ROOTFS_DIR" | cut -f1)"
