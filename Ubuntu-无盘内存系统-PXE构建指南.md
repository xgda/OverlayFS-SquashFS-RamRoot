# Ubuntu 无盘内存系统（PXE + SquashFS + OverlayFS + RAM Root）构建指南

> **目标**：拿一台已经装好所有软件和工具的 Ubuntu 母机，把它整个系统"冻"成一个镜像文件，让机房里其他机器通过网卡启动进来，完全在本地磁盘上不落任何东西，整台系统跑在内存里。
>
> **成品形态**：节点开机 → 网卡 PXE → 下载内核 → 下载系统镜像到内存 → 内存里展开成一个可读写的根文件系统 → 正常进入多用户/图形界面。重启即还原到初始状态，跟重装一遍系统效果一样。
>
> **技术组合**：SquashFS（只读压缩根）+ OverlayFS（提供可写层）+ tmpfs（把镜像和可写层都放在内存）+ iPXE / PXELINUX（网络引导）。

---

## 目录

- [0. 最终架构](#0-最终架构)
- [1. 前置条件与全文约定](#1-前置条件与全文约定)
- [2. 阶段一：准备母机](#2-阶段一准备母机)
- [3. 阶段二：母机清理（最关键的一步）](#3-阶段二母机清理最关键的一步)
- [4. 阶段三：打包 SquashFS 根文件系统](#4-阶段三打包-squashfs-根文件系统)
- [5. 阶段四：构建网络启动用的 initramfs](#5-阶段四构建网络启动用的-initramfs)
- [6. 阶段五：搭建 PXE 服务端](#6-阶段五搭建-pxe-服务端)
- [7. 阶段六：iPXE 菜单与启动参数](#7-阶段六ipxe-菜单与启动参数)
- [8. 阶段七：节点差异化（主机名 / IP / SSH 密钥）](#8-阶段七节点差异化主机名--ip--ssh-密钥)
- [9. 阶段八：验收清单](#9-阶段八验收清单)
- [10. AI 算力节点的特别注意事项](#10-ai-算力节点的特别注意事项)
- [11. 故障排查速查表](#11-故障排查速查表)
- [12. 日常运维：更新镜像与灰度发布](#12-日常运维更新镜像与灰度发布)
- [附录 A：一键构建脚本](#附录-a一键构建脚本)
- [附录 B：内核启动参数速查](#附录-b内核启动参数速查)

---

## 0. 最终架构

### 0.1 三层结构

节点内存里最终是这样叠起来的：

```
    ┌──────────────────────────────────────────┐
    │   /  （merged，进程看到的根，可读写）        │  ← switch_root 到这里
    ├──────────────────────────────────────────┤
    │            OverlayFS 合并引擎              │
    ├─────────────────────┬────────────────────┤
    │  upperdir: tmpfs    │  lowerdir: squashfs │
    │  只存"改动"          │  只读，按需读        │
    │  实打实占用 RAM      │  走 page cache，可回收│
    └─────────────────────┴────────────────────┘
```

关键点：**只读层不占内存**。SquashFS 是压缩的，内核按页按需读取，读过的数据进 page cache，内存紧张时可被回收。真正常驻内存的只有 upperdir 里写进去的改动。

### 0.2 三种镜像内容存放方式

| 方式 | SquashFS 放哪 | 内存消耗 | 断网后运行 | 适用场景 |
|---|---|---|---|---|
| **① copy2ram（推荐）** | 开机一次性下载，**整份放 tmpfs** | 实打实 = 镜像大小 | 完全不受影响 | 算力节点、GPU 服务器（RAM 512GB 起） |
| ② overlay-upper-only | 走 NFS / NBD / HTTP-FUSE **按需读** | page cache（可回收）+ upper 写入 | 立刻卡死 | 镜像远大于可用内存 |
| ③ NFS Root | 整个根在服务器上 | 最省 | 立刻卡死 | 实验室、小规模验证 |

本指南按 **方式 ①** 展开。

> **为什么不推荐 NFS Root**：所有节点的脏页回写全部压在一台服务器上，规模一大必然卡顿甚至死锁；而且 NFS hang 时进程进入 D 状态，连 `kill -9` 都杀不掉。

### 0.3 内存账怎么算

```
节点常驻内存 ≈ rootfs.squashfs 文件大小（压缩后）
             + upperdir 里累积的改动量
             + 运行时工作集（进程本身要用的）
```

举例：镜像压缩后 4GB + 运行时改动 2GB + 业务进程 20GB = 26GB。一台 512GB 的 GPU 服务器毫无压力。

---

## 1. 前置条件与全文约定

### 1.1 环境假设

| 角色 | 地址 | 说明 |
|---|---|---|
| PXE 服务器 | `192.168.1.110` | 跑 DHCP + TFTP + HTTP |
| 网段 | `192.168.1.0/24` | |
| 网关 | `192.168.1.254` | |
| DHCP 地址池 | `192.168.1.111 - 130` | |
| DNS | `8.8.8.8` | |
| 母机 | Ubuntu 24.04 LTS | 已装好所有需要的软件 |
| 引导方式 | UEFI | 传统 BIOS 见 6.5 |
| 镜像版本 | `noble-ramboot-v1` | 每次重打都换名字，便于灰度 |

下文所有命令中出现的 IP、路径、版本名，请按你自己的环境替换。

### 1.2 约定

- 全文命令默认在 **root** 下执行（前缀 `sudo` 已省略）。
- 母机上所有操作在工作目录 `/opt/ramboot/` 下进行。
- `<KVER>` 代表内核版本字符串，用 `uname -r` 得到，例如 `6.8.0-45-generic`。

---

## 2. 阶段一：准备母机

### 2.1 母机来源（任选其一）

| 方式 | 优点 | 注意点 |
|---|---|---|
| 物理机全新安装 | 驱动最全 | 会和这台机器绑定，需清理硬件相关配置 |
| **虚拟机全新安装（推荐）** | 干净、可快照、可回滚 | 驱动可能偏少，需补 `linux-generic` |
| `debootstrap` 构建 | 体积最小 | 需要手动补很多包 |

**强烈建议用虚拟机**，做完可以打个快照存着，后面迭代镜像随时回滚。

### 2.2 母机上检查软件是否齐全

```bash
# 确认目标软件都在，例如 CUDA / Docker / MLNX_OFED 等
dpkg -l | grep -i cuda
docker --version
ibstat | head -5
nvidia-smi          # 如果在母机上没 GPU，至少确认包已安装
```

### 2.3 安装构建工具（仅在母机）

```bash
apt-get update
apt-get install -y squashfs-tools xorriso rsync casper initramfs-tools
```

| 包 | 用途 |
|---|---|
| `squashfs-tools` | 提供 `mksquashfs` 和 `unsquashfs` |
| `xorriso` | 打 ISO（路线 A 需要） |
| `rsync` | 复制根文件系统，带权限和 ACL/XATTR |
| `casper` | Ubuntu 的 live 引导框架，提供 copy2ram 能力 |
| `initramfs-tools` | 生成 initramfs |

---

## 3. 阶段二：母机清理（最关键的一步）

这一步决定 100 台机器同时跑会不会互相打架。**不要跳过。**

### 3.1 删除机器唯一性标识

这些如果不删，所有节点会拥有**相同的 SSH 私钥、相同的 machine-id**，轻则 MITM 告警刷屏，重则 DHCP 抢地址（machine-id 会参与 DUID 计算）。

```bash
# SSH 主机密钥 —— 删掉，让每台机器首次启动时各自生成
rm -f /etc/ssh/ssh_host_*

# machine-id —— 清空，systemd 首次启动会重新生成一个
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

# systemd 随机种子
rm -f /var/lib/systemd/random-seed

# cloud-init 状态（如果母机用过 cloud-init）
rm -rf /var/lib/cloud /var/log/cloud-init*
```

### 3.2 解除本地磁盘依赖

```bash
# swap —— 不删的话开机要找 swapfile，找不到就卡 90 秒超时
rm -f /swapfile /swap.img
sed -i '/swap/d' /etc/fstab

# hostname 还原成通用值（真正的主机名在节点差异化阶段设置，见第 8 章）
echo "localhost" > /etc/hostname

# 清掉旧的 hosts 里写死的本机条目
sed -i '/127\.0\.1\.1/d' /etc/hosts
```

### 3.3 清理网络配置残留

```bash
# 网卡名会随硬件变化（ens160 / eno1np0 / ens3f0np0 ...），
# 硬编码的配置会让节点起不来网。统一用 match-by-all 的通写法。
cat > /etc/netplan/99-ramdisk-default.yaml <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all:
      match:
        name: "en*"
      dhcp4: true
EOF
chmod 600 /etc/netplan/99-ramdisk-default.yaml

# 删掉安装时生成的、带旧 MAC/UUID 的配置
rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/00-installer-config.yaml


vim /etc/systemd/system/ssh-keygen-a.service
[Unit]
Description=Generate SSH host keys if missing
Before=sshd.service sshd.socket
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target

# 重新加载 systemd 配置
systemctl daemon-reload

# 设置开机自启
systemctl enable ssh-keygen-a.service

# 可选：立即测试一次
systemctl start ssh-keygen-a.service
systemctl status ssh-keygen-a.service
```

### 3.4 日志改成纯内存

**不改的话日志会把 upperdir 的 tmpfs 撑爆。**

```bash
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-volatile.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=256M
RuntimeMaxFileSize=32M
EOF

# 清空已有日志
journalctl --rotate 2>/dev/null
journalctl --vacuum-time=1s 2>/dev/null
rm -rf /var/log/journal/*
```

### 3.5 瘦身

```bash
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/archives/*
rm -rf /var/tmp/* /tmp/*
rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null
truncate -s 0 /var/log/*.log 2>/dev/null
```

### 3.6 对无盘环境的额外加固

```bash
# 关掉会试图读写磁盘、在无盘下必然失败或超时的服务
systemctl disable \
  e2scrub_all.timer e2scrub_reap.service \
  fstrim.timer \
  apt-daily.timer apt-daily-upgrade.timer \
  unattended-upgrades.service 2>/dev/null

# 确保 /etc/mtab 指向内核
ln -sf /proc/self/mounts /etc/mtab

# 关掉 cloud-init（无盘场景下一般用不到，要用见第 8 章）
touch /etc/cloud/cloud-init.disabled
```

---

## 4. 阶段三：打包 SquashFS 根文件系统

### 4.1 同步根文件系统到临时目录

用 `rsync` 而不是 `cp`，才能完整保留权限、ACL、xattr、硬链接和稀疏文件。

```bash
mkdir -p /opt/ramboot/rootfs

rsync -aHAX --numeric-ids --delete \
  --exclude='/dev/*' \
  --exclude='/proc/*' \
  --exclude='/sys/*' \
  --exclude='/run/*' \
  --exclude='/tmp/*' \
  --exclude='/mnt/*' \
  --exclude='/media/*' \
  --exclude='/lost+found' \
  --exclude='/swapfile' \
  --exclude='/boot/*' \
  --exclude='/opt/ramboot/*' \
  --exclude='/var/cache/apt/archives/*' \
  --exclude='/var/lib/apt/lists/*' \
  --exclude='/var/log/journal/*' \
  /  /opt/ramboot/rootfs/
```

`-aHAX --numeric-ids` 的含义：归档模式 + 保留硬链接 + 保留 ACL + 保留扩展属性 + 保留数字型 UID/GID（避免不同机器的用户名 ID 错位）。

### 4.2 重建必须的基础目录

rsync 排除了 `/proc` `/sys` 等，但 mountpoint 本身必须存在：

```bash
cd /opt/ramboot/rootfs
mkdir -p proc sys dev/pts dev/shm run run/lock tmp var/tmp media mnt opt/ramboot
chmod 1777 tmp var/tmp dev/shm
```

### 4.3 生成 squashfs

```bash
KVER=$(uname -r)
LABEL="noble-ramboot-v1"

mksquashfs /opt/ramboot/rootfs \
  "/opt/ramboot/${LABEL}.squashfs" \
  -comp zstd \
  -Xcompression-level 19 \
  -b 1M \
  -processors $(nproc) \
  -noappend \
  -no-recovery \
  -wildcards \
  -e boot var/cache/apt/archives var/lib/apt/lists var/log/journal

chmod 644 "/opt/ramboot/${LABEL}.squashfs"
ls -lh "/opt/ramboot/${LABEL}.squashfs"
```

> **为什么用 zstd 不用 xz**：xz 能再小 10~15%，但它是 1MB 块整块解压 —— 只读层每一次随机读都要解压整个 1MB 块，运行期 CPU 会被吃穿，表现为系统莫名其妙地卡。zstd 解压快一个数量级，是 RAM root 的正解。

参数说明：

| 参数 | 作用 |
|---|---|
| `-comp zstd` | zstd 压缩，解压快 |
| `-Xcompression-level 19` | 压缩级别（19 是性价比拐点，再高压制时间暴涨而收益很小） |
| `-b 1M` | 1MB 块大小，兼顾随机读和压缩率 |
| `-noappend` | 覆盖已存在的同名文件，而不是往里追加 |
| `-no-recovery` | 不生成恢复数据，省几 MB |

---

## 5. 阶段四：构建网络启动用的 initramfs

这一章是整个流程里唯一有难度的部分。给三条路线，**推荐路线 A**。

### 5.1 路线 A（推荐）：用 Ubuntu 官方的 casper

casper 是 Canonical 用来做 Live ISO 的引导框架，Ubuntu 桌面/服务器安装盘全靠它。它已经内置了「下载镜像 → 拷进内存 → OverlayFS → switch_root」的完整逻辑，不用自己写一行挂载代码。

#### A-0. 第一步：先确认内核是怎么编的

后面所有「模块 MISSING」的判断都依赖这一步。`=y` 表示**编译进内核**，根本不存在 `.ko` 文件；`=m` 表示**模块**，必须打进 initramfs。

```bash
KVER=$(uname -r)
grep -E '^CONFIG_(BLK_DEV_LOOP|SQUASHFS|OVERLAY_FS|ISO9660_FS)=' "/boot/config-${KVER}"
```

典型输出：

```
CONFIG_BLK_DEV_LOOP=m
CONFIG_SQUASHFS=m
CONFIG_OVERLAY_FS=m
CONFIG_ISO9660_FS=m
```

- 全是 `=m` → 四个 `.ko` 都必须在 initramfs 里，缺一个就起不来
- 某个是 `=y` → 那个在 initramfs 里查不到 `.ko` **是正常现象，不是故障**

> 某些定制内核（DGX OS、云厂商内核）会把 `SQUASHFS` / `BLK_DEV_LOOP` 直接编进内核，这时用 `find -name '*.ko'` 去查必然查不到。

#### A-1. 安装 casper（这一步最容易漏）

**没有 `casper` 包，initramfs 里就不会有任何无盘引导逻辑。** `ramboot-build.sh` 的早期版本没有自动装它，这是最容易踩的坑：

```bash
apt-get update
apt-get install -y casper

# 确认装上了
dpkg-query -W -f='${Status}\n' casper
ls -l /usr/share/initramfs-tools/hooks/casper \
      /usr/share/initramfs-tools/scripts/casper
```

> **关键**：装完 casper 之后**必须重新生成 initramfs**，`update-initramfs` 只在执行时把 casper 打进镜像。先装包、再生成，顺序不能反。

#### A-1b. casper 装了，但 initramfs 里没有（常见）

`dpkg` 显示已安装、`/usr/share/initramfs-tools/hooks/casper` 也在，可 `lsinitramfs` 就是看不到 `scripts/casper`。先定性：

```bash
# 1) hook 到底有没有被调用（-v 会打印 hook 执行过程）
mkinitramfs -v -o /tmp/test.img "$(uname -r)" 2>&1 | grep -iE 'casper|hook' | head -20

# 2) 手工跑一次 hook，看它往哪拷、报什么错
rm -rf /tmp/hooktest && mkdir -p /tmp/hooktest/scripts
DESTDIR=/tmp/hooktest version="$(uname -r)" MODULES=most \
  sh -x /usr/share/initramfs-tools/hooks/casper 2>&1 | tail -30
ls -R /tmp/hooktest/scripts 2>/dev/null | head -20

# 3) 有没有同名 hook 互相干扰
ls -l /etc/initramfs-tools/hooks/ /usr/share/initramfs-tools/hooks/
```

不管什么原因，**兜底做法是自己写一个 hook 手工注入**（`ramboot-build.sh` 已内置：检测到 casper 没进 initramfs 会自动装上这个 hook 并重生成）：

```bash
cat > /etc/initramfs-tools/hooks/zz-casper-manual <<'EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions
S=/usr/share/initramfs-tools/scripts
mkdir -p "${DESTDIR}/scripts" "${DESTDIR}/etc"
for f in casper casper-functions casper-helpers; do
    [ -f "${S}/${f}" ] && cp -a "${S}/${f}" "${DESTDIR}/scripts/${f}"
done
for d in casper-bottom casper-premount; do
    [ -d "${S}/${d}" ] && cp -a "${S}/${d}" "${DESTDIR}/scripts/"
done
[ -f /etc/casper.conf ] && cp -a /etc/casper.conf "${DESTDIR}/etc/casper.conf"
force_load overlay 2>/dev/null || true
EOF
chmod +x /etc/initramfs-tools/hooks/zz-casper-manual

update-initramfs -u -k "$(uname -r)"
lsinitramfs "/boot/initrd.img-$(uname -r)" | grep -i casper
```

> 仍然不行就别跟 casper 耗了，直接走 **5.2 的 dracut 路线** —— 两三条命令，不依赖 casper 的打包行为。

#### A-2. 强制包含关键内核模块

无盘启动最怕的就是 initramfs 里没有**这张网卡的驱动** —— 镜像下载不了，直接卡死。

```bash
cat >> /etc/initramfs-tools/modules <<'EOF'
# 通用网卡
igb
ixgbe
i40e
ice
bnxt_en
mlx5_core
virtio_net
# InfiniBand / RoCE（算力节点必加）
mlx5_ib
ib_core
ib_uverbs
ib_umad
rdma_ucm
# 存储
nvme
sd_mod
ahci
EOF

# 必须是 most，不能用 dep
# dep 只会包含"当前这台机器"用到的模块，换一台硬件就废了
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
grep '^MODULES' /etc/initramfs-tools/initramfs.conf
```

#### A-3. 确保 initramfs 里有 loop / squashfs / overlay / iso9660

`iso9660`（模块名 `isofs`）是**挂载 ISO 用的**，走 `iso-url=` 路线时必不少 —— 少了它 casper 拿到 ISO 也挂不上。

```bash
cat >> /etc/initramfs-tools/modules <<'EOF'
loop
squashfs
overlay
isofs
EOF
```

再补一个强制 hook 兜底（按名字没打进去时，这里再压一次；编进内核的模块 `force_load` 会安全跳过）：

```bash
cat > /etc/initramfs-tools/hooks/zz-ramboot-force <<'EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions
force_load loop squashfs overlay isofs 2>/dev/null || true
EOF
chmod +x /etc/initramfs-tools/hooks/zz-ramboot-force
```

#### A-4. 生成 initramfs

```bash
KVER=$(uname -r)
/usr/sbin/update-initramfs -c -k "${KVER}"

ls -lh "/boot/initrd.img-${KVER}"
```

#### A-5. 验证 initramfs 内容是否齐了

**用 `lsinitramfs`，不要手工解包。** 手工解包有两个坑，都会导致误报：

1. Ubuntu 的 initramfs 是**多段拼接**的（前面是 microcode，后面才是真正的内容）。`unmkinitramfs` 解出来会分成 `early/` 和 `main/` 两个子目录 —— 此时在顶层执行 `ls scripts/casper*` **必然报 MISSING**，但内容其实在 `main/scripts/casper`。这是**假阴性**。
2. `zstd -dc | cpio -idm` 只会解出**第一段**（microcode），`find` 什么都搜不到。

一条命令搞定，不用解包：

```bash
KVER=$(uname -r)
lsinitramfs "/boot/initrd.img-${KVER}" | grep -Ei 'casper|/(loop|squashfs|overlay|isofs)\.ko'
```

期望看到（顺序不重要）：

```
scripts/casper
scripts/casper-bottom/...
scripts/casper-helpers
usr/lib/modules/.../kernel/drivers/block/loop.ko
usr/lib/modules/.../kernel/fs/squashfs/squashfs.ko
usr/lib/modules/.../kernel/fs/overlayfs/overlay.ko
usr/lib/modules/.../kernel/fs/isofs/isofs.ko
```

想看全貌就去掉 grep：`lsinitramfs /boot/initrd.img-$(uname -r) | less`

**判断标准（结合 A-0 的结果）：**

| `lsinitramfs` 结果 | `config` 里是 `=y` | 结论 |
|---|---|---|
| 能查到 `.ko` | — | ✅ 正常 |
| 查不到 `.ko` | 是 | ✅ 正常，编进内核了 |
| 查不到 `.ko` | 否（`=m`） | ❌ 真缺，回到 A-3 |
| 查不到 `casper` | — | ❌ casper 没装，或装了之后没重跑 `update-initramfs` |

**一条命令跑全套自检（不改任何东西）**：

```bash
./ramboot-build.sh --check

root@localhost:/opt/ramboot# bash check.sh --check
=================== 环境自检 ===================
 内核      : 5.15.0-164-generic
 initramfs : /boot/initrd.img-5.15.0-164-generic

--- 1) 构建工具 ---
   mksquashfs: OK
   rsync: OK
   xorriso: OK
   unmkinitramfs: OK
   lsinitramfs: OK
--- 2) casper 包（无盘引导框架）---
   casper 包: 已安装
-rwxr-xr-x 1 root root  2081 May 30  2022 /usr/share/initramfs-tools/hooks/casper
-rw-r--r-- 1 root root 35071 May 30  2022 /usr/share/initramfs-tools/scripts/casper
--- 3) 内核编译方式（y = 编进内核不需要 .ko；m = 模块，必须进 initramfs）---
   loop       CONFIG_BLK_DEV_LOOP=y  → 编进内核（initramfs 里查不到 .ko 是正常的）
   squashfs   CONFIG_SQUASHFS=y  → 编进内核（initramfs 里查不到 .ko 是正常的）
   overlay    CONFIG_OVERLAY_FS=m  → 模块（必须在 initramfs 里）
   isofs      CONFIG_ISO9660_FS=m  → 模块（必须在 initramfs 里）
--- 4) initramfs 实际内容（权威判据）---
   casper 脚本: MISSING  ← 装上 casper 后必须重跑 update-initramfs
   module loop: 无 .ko（已编进内核，属正常）
   module squashfs: 无 .ko（已编进内核，属正常）
   module overlay: OK
   module isofs: OK
   module mlx5_core: OK
   module mlx5_ib: OK
--- 5) 挂载工具 ---
   没有独立的 mount 可执行文件 —— 由 busybox 内置提供，属正常
--- 6) initramfs 分段情况（决定解包后的目录层级）---
   单段镜像：内容直接解在当前目录
=================================================
root@localhost:/opt/ramboot# update-initramfs -u -k "$(uname -r)"
lsinitramfs "/boot/initrd.img-$(uname -r)" | grep -i casper
update-initramfs: Generating /boot/initrd.img-5.15.0-164-generic
etc/casper.conf
scripts/casper
scripts/casper-bottom
scripts/casper-bottom/05mountpoints
scripts/casper-bottom/07remove_oem_config
.................
scripts/casper-premount/ORDER
usr/bin/casper-preseed
usr/bin/casper-reconfigure
usr/bin/casper-set-selections
usr/lib/casper


```

它会把「工具 / casper 包 / 内核编译方式 / initramfs 实际内容 / 分段情况」一次打印出来，并明确区分「真缺」和「假阴性」。

> **关于 `mount`**：initramfs 里通常没有独立的 `/usr/bin/mount`，`mount` 由 busybox 内置提供（busybox 的 mount 支持 `-o loop`）。这个是正常的，不用管。

#### A-6. 把 squashfs 打成 ISO（走标准 live 结构）

casper 最稳的输入是一个含 `casper/filesystem.squashfs` 的 ISO —— Ubuntu 官方 netboot 就是这么干的。

```bash
LABEL="noble-ramboot-v1"
mkdir -p /opt/ramboot/iso/casper
cp "/opt/ramboot/${LABEL}.squashfs" /opt/ramboot/iso/casper/filesystem.squashfs

xorriso -as mkisofs \
  -iso-level 3 -J -R -l \
  -V "${LABEL}" \
  -o "/opt/ramboot/${LABEL}.iso" \
  /opt/ramboot/iso

ls -lh "/opt/ramboot/${LABEL}.iso"
```

> **备选：直接 fetch squashfs，不打 ISO**
> casper 也支持 `fetch=http://192.168.1.110/boot/xxx.squashfs`。但要注意：casper 内部用的是 busybox 的wget，**DNS 解析不可用，URL 必须写纯 IP，不能写主机名**；另外某些版本对这个分支的支持不如 ISO 路径完整。出问题优先回到 ISO 方案。



你已经有了 noble-ramboot-v1.squashfs，不用重跑整套构建（那套会清 machine-id、删日志，没必要再来一遍）。用新给的 squash2iso.sh：

```bash

chmod +x squash2iso.sh
./squash2iso.sh /opt/ramboot/noble-ramboot-v1.squashfs noble-ramboot-v1
它做的事就是把 squashfs 放到 ISO 里的 casper/filesystem.squashfs —— 这个路径 casper 认死了，改一个字符都挂不上，然后自动做结构校验。


mkdir -p /tmp/isomnt
mount -o loop,ro /opt/ramboot/noble-ramboot-v1.iso /tmp/isomnt
ls -lh /tmp/isomnt/casper/filesystem.squashfs     # 必须存在
umount /tmp/isomnt
```

#### A-7. casper 的"自作主张"要裁掉

casper 是为 Live 安装器设计的，自带一堆保姆行为（比如自动创建 `ubuntu` 用户、改 hostname、准备给 subiquity 用的一堆东西）。生产无盘环境不需要这些，进容器前把它删干净：

```bash
cd /etc/initramfs-tools/scripts/casper-bottom
ls -1
```

常见可以直接删掉的（按需保留）：

```bash
rm -f 25adduser          # 自动创建 ubuntu 用户
rm -f 22screensaver      # 屏保
rm -f 22desktop          # 桌面相关
rm -f 24preseed          # installer preseed
rm -f 31disable_update_notifier
rm -f 32disable_hibernation
```

改完**必须重新生成 initramfs**：

```bash
update-initramfs -u -k $(uname -r)
```

### 5.2 路线 B：dracut + livenet

**如果 casper 死活装不上、或者裁剪后行为还是不对，直接换这条路线** —— 不用跟 Live 安装器打架，参数也更干净。dracut 的 `livenet` + `dmsquash-live` 就是为网络 live 启动设计的，而且它**会自动把 squashfs / loop / overlay / iso9660 全部带进 initramfs**（模块声明了依赖），不用手工列模块。

```bash
apt-get install -y dracut-core dracut-network squashfs-tools
KVER=$(uname -r)
dracut --force --kver "${KVER}" \
  --add "livenet dmsquash-live network" \
  --omit "multipath plymouth" \
  /opt/ramboot/initrd-ramboot.img
```

启动参数：

```
root=live:http://192.168.1.110/boot/noble-ramboot-v1.squashfs rd.live.image rd.live.ram=1 rd.live.overlay.size=4096 rd.neednet=1 ip=dhcp
```

| 参数 | 作用 |
|---|---|
| `rd.live.ram=1` | **把整份 squashfs 拷进 RAM**（就是我们要的 copy2ram） |
| `rd.live.image` | 允许直接给 `.squashfs` 而不用包 ISO |
| `rd.live.overlay.size=4096` | upperdir 的 tmpfs 限额（MB） |
| `rd.neednet=1` | 强制在 initramfs 阶段就把网络拉起来（下载镜像必需） |

验证：

```bash
lsinitramfs /opt/ramboot/initrd-ramboot.img | grep -E 'dmsquash|livenet|squashfs\.ko|loop\.ko'
```

> **注意**：dracut 在 Ubuntu 上不是默认的 initramfs 生成器（默认是 initramfs-tools）。两者可以共存，但**输出文件要写到不同路径**（上面写的是 `/opt/ramboot/initrd-ramboot.img`，不会覆盖 `/boot/initrd.img-*`）。生产环境如果不受限于 deb 生态，**用 Rocky / Fedora 作为母机会更顺**。

### 5.3 路线 C：自写 boot script（进阶）

想要完全掌控（比如要做特殊的网络才能到达镜像服务器）才走这条路。核心骨架：

在 `/etc/initramfs-tools/scripts/local-top/ramboot`：

```sh
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
  prereqs) prereqs; exit 0 ;;
esac

. /scripts/functions

SRV="http://192.168.1.110/boot"
IMG="${SRV}/noble-ramboot-v1.squashfs"

mkdir -p /run/ramboot/lower /run/ramboot/upper /run/ramboot/work

# 1) 起网络（initramfs 阶段，用 busybox 的 udhcpc）
ip link set lo up
for i in /sys/class/net/*; do ip link set "$(basename $i)" up 2>/dev/null; done
busybox udhcpc -i eth0 -q -n -s /scripts/ram-udhcp-script || true

# 2) 把镜像下载到内存
busybox wget -O /run/ramboot/rootfs.squashfs "${IMG}" || panic "download failed"

# 3) 挂 loop → 这是 lowerdir
mount -t squashfs -o loop,ro /run/ramboot/rootfs.squashfs /run/ramboot/lower \
  || panic "loop mount failed"

# 4) upperdir 用 tmpfs，务必封顶
mount -t tmpfs -o size=4G,mode=755 tmpfs /run/ramboot/upper
mkdir -p /run/ramboot/upper/upper /run/ramboot/upper/work
```

难点在于**让 initramfs 用这个 overlay 作为最终根**。Ubuntu 的 `/scripts/local` 里 `mountroot()` 会自己执行一次 `mount ... ${ROOT} ${rootmnt}`，它不认 overlay。

可行的接管方式：在 `/etc/initramfs-tools/scripts/local` 放一份你自己的 `local` 脚本 —— `mkinitramfs` 复制脚本时 `/etc/initramfs-tools/scripts/` 会**覆盖** `/usr/share/initramfs-tools/scripts/` 的同名文件。你的版本只需做：

```sh
#!/bin/sh
mount -t overlay overlay \
  -o lowerdir=/run/ramboot/lower,upperdir=/run/ramboot/upper/upper,workdir=/run/ramboot/upper/work \
  "${rootmnt}" || panic "overlay mount failed"
run_scripts /scripts/local-bottom
exec run-init "${rootmnt}" "${init}" "$@" <"${rootmnt}/dev/console" >"${rootmnt}/dev/console" 2>&1
```

> **提醒**：覆盖 `/scripts/local` 会失去上游对该文件的维护。Ubuntu 大版本升级后要重新校验这份脚本。除非有特殊需求，**优先用路线 A**。

---

## 6. 阶段五：搭建 PXE 服务端

PXE 服务器需要三个服务。下面给出的都是最小化可用配置。

### 6.1 目录规划

```
/srv/tftpboot/                     ← TFTP 根目录
├── ipxe.efi                       ← UEFI 引导程序
├── undionly.kpxe                  ← 传统 BIOS 引导程序
└── boot.ipxe                      ← 菜单脚本

/var/www/html/boot/                ← HTTP 提供大文件（内核/initrd/镜像）
├── vmlinuz-6.8.0-45-generic
├── initrd.img-6.8.0-45-generic
└── noble-ramboot-v1.iso
```

> 原则：**只有几百 KB 的引导程序走 TFTP，内核和镜像一律走 HTTP**。TFTP 基于 UDP、块小、无拥塞控制，传几百 MB 会慢到无法接受。

### 6.2 安装服务

```bash
apt-get install -y isc-dhcp-server tftpd-hpa nginx ipxe
```

### 6.3 DHCP 配置

编辑 `/etc/dhcp/dhcpd.conf`：

```conf
option arch code 93 = unsigned integer 16;

default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.1.0 netmask 255.255.255.0 {
    range 192.168.1.111 192.168.1.130;
    option routers 192.168.1.254;
    option domain-name-servers 8.8.8.8;
    next-server 192.168.1.110;

    # 按客户端架构下发不同的引导程序
    if option arch = 00:07 or option arch = 00:09 {
        filename "ipxe.efi";        # UEFI x64 / ARM64
    } else {
        filename "undionly.kpxe";   # 传统 BIOS
    }
}
```

> 如果你已经有生产 DHCP 服务器，不要抢地址池，改用 DHCP Proxy / 中继分工。

### 6.4 HTTP 服务（nginx）

`/etc/nginx/sites-available/pxe-boot`：

```nginx
server {
    listen 80;
    server_name _;
    root /var/www/html;
    autoindex off;

    location /boot/ {
        alias /var/www/html/boot/;
        sendfile        on;
        sendfile_max_chunk 8m;
        tcp_nopush      on;
        tcp_nodelay     on;
        aio             threads;
        directio        off;
        keepalive_timeout 60;

        types { }
        default_type application/octet-stream;
    }
}
```

```bash
ln -sf /etc/nginx/sites-available/pxe-boot /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

> `sendfile on` + `aio threads` 配合 `directio off`：让同一份镜像被 100 台机器重复读取时几乎全走 page cache，磁盘不再是瓶颈，网络才是。

### 6.5 引导程序

```bash
cp /usr/lib/ipxe/ipxe.efi         /srv/tftpboot/ 2>/dev/null || \
  curl -o /srv/tftpboot/ipxe.efi https://boot.ipxe.org/ipxe.efi
cp /usr/lib/ipxe/undionly.kpxe   /srv/tftpboot/ 2>/dev/null || \
  curl -o /srv/tftpboot/undionly.kpxe https://boot.ipxe.org/undionly.kpxe
chmod 644 /srv/tftpboot/*.efi /srv/tftpboot/*.kpxe
```

> **如果目标机器支持 HTTPS 和 IPv6**，可以去 https://ipxe.org/ 自己编译一个只带必要驱动的 `ipxe.efi`，体积更小、启动更快。

### 6.6 上传构建产物

```bash
KVER=$(uname -r)
LABEL=noble-ramboot-v1

mkdir -p /var/www/html/boot
# 从母机拷过来（在母机上执行 scp，或在这里 scp 拉取）
scp root@<母机IP>:/boot/vmlinuz-${KVER}          /var/www/html/boot/
scp root@<母机IP>:/boot/initrd.img-${KVER}       /var/www/html/boot/
scp root@<母机IP>:/opt/ramboot/${LABEL}.iso      /var/www/html/boot/

chmod 644 /var/www/html/boot/*
ls -lh /var/www/html/boot/
```

### 6.7 启动并检查

```bash
systemctl enable --now isc-dhcp-server tftpd-hpa nginx
systemctl status isc-dhcp-server tftpd-hpa nginx --no-pager
```

快速自检 HTTP 是否可用（**这条必须通，否则节点肯定起不来**）：

```bash
curl -sI http://192.168.1.110/boot/noble-ramboot-v1.iso | head -3
curl -sI http://192.168.1.110/boot/vmlinuz-6.8.0-45-generic | head -3
```

---

## 7. 阶段六：iPXE 菜单与启动参数

### 7.1 菜单脚本

`/srv/tftpboot/boot.ipxe`：

```ipxe
#!ipxe
set server 192.168.1.110
set base http://${server}/boot
set label noble-ramboot-v1

:start
menu ================= PXE Boot Menu =================
item --key r ramboot   Ubuntu 24.04 无盘内存系统 (${label})
item --key l local     从本地磁盘启动
item --key s shell     进入 iPXE shell
item --key x reboot    重启
choose --timeout 100 --default ramboot target && goto ${target}

:ramboot
kernel ${base}/vmlinuz-6.8.0-45-generic initrd=initrd.img-6.8.0-45-generic
initrd ${base}/initrd.img-6.8.0-45-generic
imgargs vmlinuz-6.8.0-45-generic \
        boot=casper \
        iso-url=${base}/${label}.iso \
        ip=dhcp \
        net.ifnames=1 biosdevname=0 \
        console=tty0 console=ttyS0,115200 \
        quiet splash ---
boot || goto failed

:local
exit 1

:shell
shell
goto start

:reboot
reboot

:failed
echo !!!!! BOOT FAILED !!!!!
echo press any key to return to menu
prompt
goto start
```

### 7.2 关键参数解释

| 参数 | 作用 | 备注 |
|---|---|---|
| `boot=casper` | 启用 casper 引导框架 | **必需**，少它 casper 脚本不执行 |
| `iso-url=<URL>` | 告诉 casper 去哪拿 live image | URL **必须是纯 IP** |
| `ip=dhcp` | initramfs 阶段初始化网络 | 也可以在内核行写 `ip=dhcp` |
| `net.ifnames=1` | 启用可预测网卡名 | 不加就是 `eth0` 老式命名 |
| `console=ttyS0,115200` | 串口控制台 | 服务器有 BMC/IPMI 时强烈建议加上 |
| `---` | iPXE 的参数分隔符 | 后面的参数传给内核而不是 iPXE |

### 7.3 想直接用裸 squashfs、不打 ISO：必须换 dracut（重要）

**casper 的网络拉取（`netboot=url` + `url=` / `iso-url=`）只认 ISO**：它把 ISO 下载到内存、loop 挂载、再从里面找 `casper/filesystem.squashfs`。给裸 squashfs 它不会挂（`fetch=` 分支在 casper 1.470 里并不完整，别赌）。

所以两条路二选一：

- **用 casper → 必须上 ISO**（7.1 的菜单），ISO 由 `ramboot-build.sh` 产出
- **坚持裸 squashfs 直连 HTTP → 用 dracut**（5.2 生成 initramfs），iPXE 菜单如下：

```
:ramboot
kernel ${base}/vmlinuz \
       ip=dhcp \
       rd.neednet=1 \
       root=live:${base}/${label}.squashfs \
       rd.live.image \
       rd.live.ram=1 \
       rd.live.overlay.size=8192 \
       net.ifnames=1 biosdevname=0 \
       console=tty0 console=ttyS0,115200 || goto failed
initrd ${base}/initrd-ramboot.img || goto failed
boot || goto failed
```

| 参数 | 说明 |
|---|---|
| `root=live:http://…/xxx.squashfs` | dracut 的 `livenet` **直接下载裸 squashfs**，不需要 ISO |
| `rd.live.ram=1` | 下载后整份拷进内存（copy2ram），之后断网也能跑 |
| `rd.neednet=1` | 强制 initramfs 阶段把网络拉起来 |
| `rd.live.overlay.size=8192` | upper 层 tmpfs 限额（MB），按机器内存调 |

**注意**：dracut 的 initramfs（`initrd-ramboot.img`）和 initramfs-tools 生成的（`initrd.img-*`）**不通用** —— 前者认 `root=live:`，后者认 `boot=casper`。配错对就是截图里那个下场（见 7.4）。

### 7.4 起不来时的快速判读

initramfs 阶段卡住，先看它走到哪一步：

| 屏幕上的迹象 | 含义 |
|---|---|
| `Running /scripts/local-top` → `No root device specified` → busybox shell | **casper/dracut 都没参与**，走的是"找本地盘"的标准路径。十有八九是内核参数缺 `boot=casper`（或用了不匹配的 initramfs） |
| casper 输出后卡在 `Waiting for xx` | 网卡驱动 / 网络没通，回第 5 章检查模块 |
| 已挂上 squashfs 但起不来 | 镜像内容问题，回第 3 章检查清理 |

### 7.5 最小可用 iPXE 片段（casper + ISO）

如果已经在流程里生成了 `.iso`（`ramboot-build.sh` 第 6 步会产出），或者用 `squash2iso.sh` 把现有 squashfs 包了一层 ISO，菜单照下面写：

```
#!ipxe

:FD
set base-url http://${server-ip}/x86/FD
kernel ${base-url}/vmlinuz boot=casper netboot=url url=${base-url}/noble-ramboot-v1.iso ip=dhcp net.ifnames=1 biosdevname=0 console=tty0 console=ttyS0,115200 || goto failed
initrd ${base-url}/initrd || goto failed
boot || goto failed

:failed
echo !!!!! BOOT FAILED !!!!!
prompt
shell
```

第一次调试建议加 `debug=1` 并去掉 `quiet splash`，能看到 casper 每一步在干什么。

**三条硬性约束：**

| 约束 | 原因 |
|---|---|
| 必须有 `boot=casper` | casper 的总开关，缺了它走本地盘路径，直接 `No root device specified` |
| `url=` 必须是**纯 IP** | casper 里是 busybox 的 wget，**DNS 不工作**；`${server-ip}` 由 DHCP 给出，天然满足 |
| `url=` 必须是 **http**，不能 https | busybox wget 不支持 TLS |

> casper 的 netboot 分支在 jammy（casper 1.470）上用 `netboot=url url=<iso>` 最稳；部分新版本也认 `iso-url=<iso>`，两者都试试。

**部署前先在 PXE 服务器上确认三件事：**

```bash
# 1) HTTP 能拿到 ISO（大小要和母机一致）
curl -sI http://<server-ip>/x86/FD/noble-ramboot-v1.iso | head -3

# 2) PXE 上的 initrd 确实是新生成那份（含 casper），不是旧的
md5sum /var/www/html/x86/FD/initrd          # PXE 服务器
md5sum /boot/initrd.img-$(uname -r)         # 母机，两者必须一样

# 3) vmlinuz 和 initrd 是同一个内核版本
file /var/www/html/x86/FD/vmlinuz | grep -o '5\.15\.0-[0-9]*-generic'
```

**启动成功的判据**：屏幕上出现一连串 `[  ... ]` 的 casper 进度条并把 ISO 拉下来，进系统后执行：

```bash
findmnt -no SOURCE,FSTYPE /
# 期望：overlay（不是 /dev/sda*，也不是 loop）

touch /root/STATELESS_TEST && reboot
# 重启后文件没了 = 真的跑在内存里
```

---

## 8. 阶段七：节点差异化（主机名 / IP / SSH 密钥）

**这是现实里必须解决的问题**：所有节点跑同一个镜像，怎么让它们有不同的主机名、固定的 IP、各自的 SSH 密钥？

### 8.1 SSH 主机密钥（自动）

因为第 3.1 步已经删掉了 `ssh_host_*`，每台机器首次启动时 `ssh-keygen` 会各自生成一套。`ssh.service` 的 `sshd-keygen@.service` 或 `sshd.service` 会自动完成。无需额外操作。

### 8.2 machine-id（自动）

空的 `/etc/machine-id` 在首次启动时会由 systemd 生成永久值，但因为根节点在内存里，**每次重启都会重新生成**。这通常是我们想要的（彻底无状态）。如需多台机器共享某种持久标识，走 8.3。

### 8.3 主机名：按 MAC 从服务器拉映射表（推荐）

在 PXE 服务器上维护一张表 `/var/www/html/boot/nodes.map`：

```
# mac                 hostname        ip              role
aa:bb:cc:dd:ee:01     gpu-node-01     192.168.1.51    gpu
aa:bb:cc:dd:ee:02     gpu-node-02     192.168.1.52    gpu
aa:bb:cc:dd:ee:03     cpu-node-01     192.168.1.61    cpu
```

在**母机**上放一个 oneshot 服务，开机那一刻去拉这张表。

`/usr/local/sbin/ramboot-identity`：

```bash
#!/bin/bash
# 从 PXE 服务器按 MAC 拉取节点身份，写入 hostname
MAP_URL="http://192.168.1.110/boot/nodes.map"
TIMEOUT=15

ifname=$(ip -o route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')
[ -z "$ifname" ] && ifname=$(ls /sys/class/net | grep -E '^(en|eth)' | head -1)
[ -z "$ifname" ] && exit 0

mac=$(cat "/sys/class/net/${ifname}/address" 2>/dev/null)
[ -z "$mac" ] && exit 0

mapfile=$(mktemp)
if curl -sf --max-time "${TIMEOUT}" -o "${mapfile}" "${MAP_URL}"; then
    line=$(grep -i "^${mac}" "${mapfile}")
    if [ -n "$line" ]; then
        hostname=$(echo "$line" | awk '{print $2}')
        [ -n "$hostname" ] && hostnamectl set-hostname "${hostname}"
    fi
fi
rm -f "${mapfile}"
```

配套 systemd unit `/etc/systemd/system/ramboot-identity.service`：

```ini
[Unit]
Description=RamBoot node identity from MAC map
DefaultDependencies=no
After=network-online.target
Wants=network-online.target
Before=ssh.service nvidia-persistenced.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ramboot-identity
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
```

```bash
chmod +x /usr/local/sbin/ramboot-identity
systemctl enable ramboot-identity
```

### 8.4 固定 IP

两种方式，选其一：

- **DHCP 静态绑定（推荐）**：在 dhcpd.conf 里按 MAC 分配固定地址，节点继续 `dhcp4: true`。集中管理，改一次生效所有节点。
  ```conf
  host gpu-node-01 {
      hardware ethernet aa:bb:cc:dd:ee:01;
      fixed-address 192.168.1.51;
      option host-name "gpu-node-01";
  }
  ```
- **镜像内动态下发**：同一个 oneshot 服务里从 `nodes.map` 的第 3 列拿到 IP，用 `ip addr add` 配上。适合没有 DHCP 控制权的场景。

### 8.5 （可选）用 cloud-init 做差异化

如果需要更复杂的初始化（注入 SSH 公钥、写文件、跑脚本），可以在母机里保留 cloud-init，配 NoCloud 数据源：

```bash
rm -f /etc/cloud/cloud-init.disabled
mkdir -p /var/lib/cloud/seed/nocloud-net
cat > /var/lib/cloud/seed/nocloud-net/meta-data <<'EOF'
instance-id: ramboot-generic
local-hostname: ramboot-node
EOF
cat > /var/lib/cloud/seed/nocloud-net/user-data <<'EOF'
#cloud-config
ssh_pwauth: false
EOF
```

> 注意无盘场景下 cloud-init 每次重启都会跑一遍（`/var/lib/cloud` 的状态也被重置了）。要么接受这个行为，要么用 8.3 的方案替代。

---

## 9. 阶段八：验收清单

挑一台机器 PXE 起来，逐项确认：

```bash
# 1) 根文件系统是不是 overlay —— 这是整个方案有没有生效的判据
findmnt -no SOURCE,FSTYPE /
# 期望：overlay

# 2) 只读层挂在哪
mount | grep -E 'squashfs|loop'

# 3) 内核启动参数对不对
cat /proc/cmdline

# 4) 网卡、IB、GPU 驱动
ip -br link
ibstat | head -20
nvidia-smi

# 5) 主机名是不是按 MAC 拿到了预期值
hostnamectl status

# 6) 内存账 —— 看看 upperdir 吃了多少
df -h /
free -h
mount | grep upper

# 7) 无状态验证（最重要的一条）
touch /root/STATELESS_TEST
reboot
# 重启后执行：
ls /root/STATELESS_TEST
# 期望：ls: cannot access ...: No such file or directory  → 证明确实无落盘

# 8) 断网验证（copy2ram 的核心价值）
# 起来之后拔网线，看系统是否照常运行
ip link show
```

全部通过，就可以批量推开了。

---

## 10. AI 算力节点的特别注意事项

这一节是给 GPU / InfiniBand / RoCE 集群加的，普通无盘用不到。

### 10.1 内核必须同源（第一铁律）

PXE 加载的 `vmlinuz` **必须是母机 `/boot/vmlinuz-$(uname -r)`**，不要图省事去下载 Ubuntu 官方 ISO 里的内核。

原因：MLNX_OFED 和 NVIDIA GPU 驱动都是通过 DKMS 针对**特定内核版本**编译的 `.ko`。版本对不上就是符号不匹配，典型症状：

- 系统正常起来了，但 `ib0` 出不来 → `ibstat` 报 "no device"
- `nvidia-smi` 报 "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver"
- 报错信息里出现 `Unknown symbol in module` 或 `module layout version mismatch`

**唯一正确的做法**：vmlinuz / initrd / squashfs 三件套全部从同一台母机上取。

### 10.2 initramfs 必须带上 IB / RDMA 驱动

见 5.1 的 A-2 步。漏了 `mlx5_core` 的后果是：initramfs 阶段起不来网卡 → 镜像下载不了 → 卡在 `Waiting for network configuration...`。

### 10.3 upperdir tmpfs 必须封顶

默认的 tmpfs 上限是物理内存的一半。跑容器 / vGPU / 大模型推理时，容器自身的 overlay + /var/log + 各种缓存会迅速把 upperdir 吃光，触发 OOM。

建议把高写入目录拆成独立 tmpfs 并分别限额（在母机的 fstab 里）：

```
tmpfs   /tmp            tmpfs   defaults,nosuid,nodev,size=2G,mode=1777   0 0
tmpfs   /var/log        tmpfs   defaults,nosuid,nodev,size=512M           0 0
tmpfs   /var/lib/docker tmpfs   defaults,nosuid,nodev,size=8G             0 0
tmpfs   /dev/shm        tmpfs   defaults,nosuid,nodev,size=64G            0 0
```

> **`/dev/shm` 一定要给大。** NCCL / OpenMPI 的集合通信严重依赖共享内存做 intra-node 通信，默认的 `size=64M`（有些发行版是 RAM 的一半，有些是 64MB）会造成训练吞吐断崖式下降甚至直接 hang。

### 10.4 NCCL 与共享内存

无盘系统上跑多卡训练，除了 `/dev/shm`，还要确认：

```bash
# 检查 NCCL 是否走 SHM 而不是退化到 socket
export NCCL_DEBUG=INFO
# 日志里应看到 Transport via NET/Socket 之外的 SHM 通道

# ulimit.memlock 通常要放开
ulimit -l unlimited
```

### 10.5 时间同步

无盘节点没有 RTC 备份、也没有持久化的 `hwclock`，开机时间可能从 1970 开始。影响面：

- RDMA CM 建连时的证书/PSN 校验
- Kubernetes 的 token 签发与校验
- TLS 证书有效期校验
- 日志时序分析

必须配好 NTP：

```bash
systemctl enable systemd-timesyncd
sed -i 's|^#NTP=.*|NTP=192.168.1.254|' /etc/systemd/timesyncd.conf
```

### 10.6 大规模并发的带宽账

这是唯一会让方案在规模化时翻车的地方。

```
总传输量 = 节点数 × 镜像大小
100 台 × 4GB = 400GB
```

| 链路 | 带宽 | 400GB 传完耗时 |
|---|---|---|
| 1 GbE | ~110 MB/s | ~60 分钟 |
| 10 GbE | ~1.1 GB/s | ~6 分钟 |
| 25 GbE | ~2.8 GB/s | ~2.5 分钟 |
| 100 GbE (RoCE/IB) | ~11 GB/s | ~40 秒 |

磁盘不是瓶颈（同一份文件反复读，全部进 page cache），**网络才是**。

应对手段：

1. PXE 服务器至少万兆上联（算力网络通常有 25G/100G 接入交换机，直接用）
2. nginx 开 `sendfile` + `aio threads`（见 6.4）
3. 分批开机，错峰
4. 镜像精简（- 去掉 doc、locales、firmware 中不需要的）
5. 极端规模下可以考虑多播分发（iPXE 支持，但要交换机配合）

---

## 11. 故障排查速查表

| 现象 | 最可能的原因 | 处理 |
|---|---|---|
| **initramfs 里查不到 `casper`** | `casper` 包没装；或装了之后没重跑 `update-initramfs` | `apt-get install -y casper && update-initramfs -u -k $(uname -r)`，再用 `lsinitramfs \| grep casper` 确认 |
| **initramfs 里查不到 `loop.ko` / `squashfs.ko`** | ① 内核把功能编进去了（`=y`，**属正常**）；② `MODULES=dep`；③ 手工解包只解出第一段 | `grep -E '^CONFIG_(BLK_DEV_LOOP\|SQUASHFS)=' /boot/config-$(uname -r)` 先定性；是 `=m` 就按 A-3 补 hook 重做 |
| **`ls scripts/casper*` 报 MISSING，但 `lsinitramfs` 能看到** | `unmkinitramfs` 多段解包，内容在 `main/` 子目录 | **假阴性**，看 `main/scripts/casper`；以后一律用 `lsinitramfs` 判 |
| 卡在 `No root device specified` | 缺 `boot=casper` 或 root= 参数 | 检查内核启动参数是否传进去了 |
| `Waiting for network configuration` 然后超时 | initramfs 里没有这张网卡的驱动 | 补驱动到 `/etc/initramfs-tools/modules`，`MODULES=most`，重做 initramfs |
| 下载镜像到一半报 timeout | **URL 用了主机名；TFTP 传大文件** | casper 的 busybox wget 不支持 DNS，改纯 IP；大文件必须走 HTTP |
| 起来后 `/` 是 squashfs 而不是 overlay | casper 没生效 | 确认 initramfs 里有 `scripts/casper`（用 A-5 的命令验证） |
| `Unknown symbol in module nvidia` | 内核版本和 NVIDIA 驱动不匹配 | 回到母机重取 vmlinuz/initrd（见 10.1） |
| `ibstat` 报 no device | 同上，或漏了 mlx5_core | 补模块 |
| 多台机器 SSH 提示 host key 冲突 | 母机没清 SSH 主机密钥 | 重跑 3.1 |
| DHCP 抢地址 / IP 冲突 | machine-id 清空但 /etc/machine-id 又被打了 | 确认清空后没有再被 cloud-init 写回 |
| 开机卡 90 秒 | fstab 里有 swap 或找不到的设备 | 删掉 swap 条目，检查 fstab 全部条目是否都可达 |
| upperdir 撑爆内存 OOM | 没给 tmpfs 限额 | 按 10.3 拆分限额 |
| journal 占满 tmpfs | journald 没改 volatile | 跑 3.4 |
| 训练吞吐异常低 | `/dev/shm` 太小 | 按 10.3 给到几十 GB |
| 100 台同时开机奇慢 | 出口带宽瓶颈 | 见 10.6 |
| **initramfs 卡在 `mlx5_core ...: Link down` 后不动** | ① 只是慢：mlx5 链路起来要 10～60 秒；② 卡多网卡探测：`ip=dhcp` 先试了根线没插的这个口；③ ConnectX 口是 IB 模式，没有 Subnet Manager 链路永远起不来 | 先等 60 秒看有没有 `Link up`；用 `break=network` 进 shell 跑 `ip link` 找 `LOWER_UP` 的口，用 `ip=:::::<网口名>:dhcp` 钉死；查口模式 `mlxconfig -d <PCI> q \| grep LINK_TYPE`（IB 要改 Ethernet 或起 SM）；同时在 DHCP 服务器 `journalctl -u isc-dhcp-server -f` 看收没收到 DISCOVER |
| DHCP 服务器**收到了** DISCOVER 但节点还在等 | casper 停在了错误的网口上 | 内核参数把接口钉死：`ip=:::::enp1s0f0np1:dhcp`；或去掉多余网卡的探测 |
| DHCP 服务器**完全没收到** DISCOVER | 节点发包的口和 DHCP 不在同一线路/VLAN；或口的模式不对 | 换确认接线那个口的 `ip=:::::<网口名>:dhcp`；查交换机端口 VLAN、PVID |

**通用调试手段**：把内核参数里的 `quiet splash` 去掉，加上 `debug=1 rd.live.debug`，可以看到 casper 每一步在干什么。

---

## 12. 日常运维：更新镜像与灰度发布

### 12.1 迭代流程

母机是唯一的"源"。改完再打一次镜像即可，**不要在运行的节点上打补丁**（重启就丢了）。

```
母机改动 → rsync → mksquashfs → 打 ISO → 上传 PXE 服务器 → 改菜单版本 → 重启节点生效
```

### 12.2 不要覆盖旧镜像

每次都用新名字，好处是可以秒回滚：

```
noble-ramboot-v1.iso    ← 上一版，保留
noble-ramboot-v2.iso    ← 当前
```

boot.ipxe 里改一行 `set label noble-ramboot-v2` 就切换了。出问题改回 v1 即可。

### 12.3 灰度建议

1. 先在**一台**机器上重启验证（第 9 章清单过一遍）
2. 确认无误后，按批次（比如一次 10 台）重启
3. 全量推开前保留至少一个批次观察 30 分钟

### 12.4 母机快照

如果用虚拟机做母机，**每出一版镜像打一次快照**，加上日期和版本号。这样后续要追溯某个驱动版本时可以直接回到当时的状态。

---

## 附录 A：一键构建脚本

把第 2、3、4、5 章串起来。放在母机上 `/opt/ramboot/build.sh`。

> **注意**：脚本里包含破坏性的清理操作（删除 SSH 主机密钥、machine-id、日志）。只在专用母机上跑。

```bash
#!/usr/bin/env bash
# =============================================================================
#  Ubuntu 无盘内存镜像构建脚本
#  用法: ./build.sh [版本号]      例: ./build.sh noble-ramboot-v3
# =============================================================================
set -euo pipefail

LABEL="${1:-noble-ramboot-$(date +%Y%m%d)}"
BASE="/opt/ramboot"
ROOTFS="${BASE}/rootfs"
ISODIR="${BASE}/iso"
STAMP="${BASE}/${LABEL}.squashfs"
ISO="${BASE}/${LABEL}.iso"

# casper 是关键依赖：没装它，initramfs 里就不会有无盘引导逻辑
if ! dpkg-query -W -f='${Status}' casper 2>/dev/null | grep -q 'install ok installed'; then
  apt-get update -qq && apt-get install -y casper initramfs-tools
fi

command -v mksquashfs >/dev/null || { echo "请先 apt install squashfs-tools xorriso rsync casper"; exit 1; }

echo ">>> [1/5] 清理母机唯一性标识"
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id /var/lib/systemd/random-seed
rm -rf /var/lib/cloud /var/log/cloud-init*

echo ">>> [2/5] 解除本地磁盘依赖 + 日志改内存"
rm -f /swapfile /swap.img
sed -i '/swap/d' /etc/fstab
echo "localhost" > /etc/hostname
sed -i '/127\.0\.1\.1/d' /etc/hosts

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-volatile.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=256M
RuntimeMaxFileSize=32M
EOF

mkdir -p /etc/netplan
cat > /etc/netplan/99-ramdisk-default.yaml <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all:
      match:
        name: "en*"
      dhcp4: true
EOF
chmod 600 /etc/netplan/99-ramdisk-default.yaml
rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/00-installer-config.yaml

echo ">>> [3/5] 瘦身"
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/tmp/* /tmp/*
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
rm -rf /var/log/journal/*

echo ">>> [4/5] 同步根文件系统"
mkdir -p "${ROOTFS}"
rsync -aHAX --numeric-ids --delete \
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' \
  --exclude='/run/*' --exclude='/tmp/*' --exclude='/mnt/*' \
  --exclude='/media/*' --exclude='/lost+found' --exclude='/swapfile' \
  --exclude='/boot/*' --exclude="${BASE}/*" \
  --exclude='/var/cache/apt/archives/*' --exclude='/var/lib/apt/lists/*' \
  --exclude='/var/log/journal/*' \
  / "${ROOTFS}/"

mkdir -p "${ROOTFS}"/{proc,sys,dev/pts,dev/shm,run,run/lock,tmp,var/tmp,media,mnt}
chmod 1777 "${ROOTFS}"/tmp "${ROOTFS}"/var/tmp "${ROOTFS}"/dev/shm

echo ">>> [4.5/5] 生成 initramfs"
KVER="$(uname -r)"
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
for m in loop squashfs overlay isofs mlx5_core mlx5_ib ib_core ib_uverbs rdma_ucm nvme; do
  grep -qx "${m}" /etc/initramfs-tools/modules 2>/dev/null || echo "${m}" >> /etc/initramfs-tools/modules
done
cat > /etc/initramfs-tools/hooks/zz-ramboot-force <<'HOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions
force_load loop squashfs overlay isofs 2>/dev/null || true
HOOK
chmod +x /etc/initramfs-tools/hooks/zz-ramboot-force
update-initramfs -c -k "${KVER}" 2>/dev/null || update-initramfs -u -k "${KVER}"

# 生成完立刻自检，不然后面全白干
lsinitramfs "/boot/initrd.img-${KVER}" | grep -qi casper || { echo "casper 没进 initramfs，中止"; exit 1; }
lsinitramfs "/boot/initrd.img-${KVER}" | grep -Ei 'casper|/(loop|squashfs|overlay|isofs)\.ko'

echo ">>> [5/5] 打包"
rm -f "${STAMP}"
mksquashfs "${ROOTFS}" "${STAMP}" \
  -comp zstd -Xcompression-level 19 -b 1M \
  -processors "$(nproc)" -noappend -no-recovery \
  -e boot var/cache/apt/archives var/lib/apt/lists var/log/journal

mkdir -p "${ISODIR}/casper"
cp -f "${STAMP}" "${ISODIR}/casper/filesystem.squashfs"
rm -f "${ISO}"
xorriso -as mkisofs -iso-level 3 -J -R -l -V "${LABEL}" -o "${ISO}" "${ISODIR}"

echo
echo "=========== 构建完成 ==========="
echo "  squashfs : ${STAMP}    $(du -h "${STAMP}" | cut -f1)"
echo "  iso      : ${ISO}    $(du -h "${ISO}" | cut -f1)"
echo "  vmlinuz  : /boot/vmlinuz-${KVER}"
echo "  initrd   : /boot/initrd.img-${KVER}"
echo
echo "下一步：把上面四个文件传到 PXE 服务器的 /var/www/html/boot/"
```

用法：

```bash
chmod +x /opt/ramboot/build.sh
/opt/ramboot/build.sh noble-ramboot-v1
```

---

## 附录 B：内核启动参数速查

### casper（Ubuntu 路线）

| 参数 | 说明 |
|---|---|
| `boot=casper` | **必需**，激活 casper 引导框架 |
| `iso-url=<URL>` | 从指定位置下载 live ISO 并加载（RAM 中） |
| `fetch=<URL>` | 直接下载 squashfs 到 RAM（URL 必须是**纯 IP**） |
| `httpfs=<URL>` | 用 FUSE 挂载远端镜像，**按需读取**，省内存但持续依赖网络 |
| `toram` | 把已经找到的镜像拷进 RAM |
| `ip=dhcp` | initramfs 阶段通过 DHCP 起网 |
| `debug` / `rd.live.debug` | 打印详细引导过程，排障必开 |

### dracut livenet（路线 B）

| 参数 | 说明 |
|---|---|
| `root=live:<URL>` | 指定 live 镜像位置 |
| `rd.live.image` | 允许直接使用 .squashfs 而非 ISO |
| `rd.live.ram=1` | **整份拷进 RAM**（copy2ram） |
| `rd.live.overlay.size=<MB>` | upperdir tmpfs 限额 |
| `rd.live.debug` | 详细日志 |

### 通用

| 参数 | 说明 |
|---|---|
| `net.ifnames=1` | 启用可预测网卡名（`ens3f0np0` 这种） |
| `biosdevname=0` | 关闭 Dell 风格的 `em1` 命名 |
| `console=ttyS0,115200` | 串口控制台，配合 BMC/IPMI |
| `systemd.log_level=debug` | systemd 详细日志 |

---

## 参考

- ISC DHCP 官方文档 `dhcpd.conf(5)`、`dhcp-options(5)`
- Ubuntu casper 源码：`/usr/share/initramfs-tools/scripts/casper`
- dracut 文档 `dracut.cmdline(7)` 的 `rd.live.*` 部分
- iPXE 官方文档 https://ipxe.org/cmd 的内核/镜像加载命令
- Linux 内核文档 `Documentation/filesystems/overlayfs.rst`
