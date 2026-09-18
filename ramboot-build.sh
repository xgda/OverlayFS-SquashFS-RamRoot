#!/usr/bin/env bash
# =============================================================================
#  Ubuntu 无盘内存镜像（PXE + SquashFS + OverlayFS + RAM Root）构建脚本
#
#  用法:
#    ./ramboot-build.sh [版本号]    完整构建（清理 → initramfs → squashfs → ISO）
#    ./ramboot-build.sh --check     只做环境自检，不改任何东西
#
#  用途：把当前这台机器（母机）做成一个可通过 PXE 网络启动、
#        完全运行在内存里、不往本地磁盘写任何东西的系统镜像。
#
#  ⚠ 警告：完整构建包含破坏性清理（删除 SSH 主机密钥、machine-id、日志文件、
#           swapfile、netplan 配置）。只在专用的镜像母机上执行一次。
#  ⚠ 建议：母机用虚拟机，每出一版镜像打一次快照，方便回滚。
# =============================================================================
set -euo pipefail

BASE="/opt/ramboot"
LABEL="${1:-noble-ramboot-$(date +%Y%m%d)}"

# 内核模块名 -> 内核 CONFIG 名（用于判断是编进内核 =y 还是模块 =m）
kconfig_of() {
    case "$1" in
        loop)     echo CONFIG_BLK_DEV_LOOP ;;
        squashfs) echo CONFIG_SQUASHFS ;;
        overlay)  echo CONFIG_OVERLAY_FS ;;
        isofs)    echo CONFIG_ISO9660_FS ;;
        *)        echo "" ;;
    esac
}

# -----------------------------------------------------------------------------
# 自检模式：只报告，不修改
# -----------------------------------------------------------------------------
if [ "${1:-}" = "--check" ]; then
    KVER="$(uname -r)"
    IMG="/boot/initrd.img-${KVER}"
    CFG="/boot/config-${KVER}"
    echo "=================== 环境自检 ==================="
    echo " 内核      : ${KVER}"
    echo " initramfs : ${IMG}"
    [ -f "${IMG}" ] || { echo " [错误] ${IMG} 不存在"; exit 1; }
    echo

    echo "--- 1) 构建工具 ---"
    for c in mksquashfs rsync xorriso unmkinitramfs lsinitramfs; do
        command -v "$c" >/dev/null 2>&1 && echo "   ${c}: OK" || echo "   ${c}: MISSING"
    done

    echo "--- 2) casper 包（无盘引导框架）---"
    if dpkg-query -W -f='${Status}' casper 2>/dev/null | grep -q 'install ok installed'; then
        echo "   casper 包: 已安装"
        ls -l /usr/share/initramfs-tools/hooks/casper \
              /usr/share/initramfs-tools/scripts/casper 2>/dev/null || echo "   （但文件缺失，重装一次）"
    else
        echo "   casper 包: 未安装  ← 这就是 initramfs 里没有 casper 脚本的原因"
        echo "   修复: apt-get update && apt-get install -y casper && update-initramfs -u -k ${KVER}"
    fi

    echo "--- 3) 内核编译方式（y = 编进内核不需要 .ko；m = 模块，必须进 initramfs）---"
    if [ -f "${CFG}" ]; then
        for m in loop squashfs overlay isofs; do
            kc="$(kconfig_of "$m")"
            v="$(grep -E "^${kc}=" "${CFG}" | head -1 | cut -d= -f2)"
            printf "   %-10s %s=%s  → %s\n" "$m" "$kc" "${v:-?}" \
                "$( [ "${v:-}" = "y" ] && echo '编进内核（initramfs 里查不到 .ko 是正常的）' || echo '模块（必须在 initramfs 里）' )"
        done
    else
        echo "   未找到 ${CFG}，无法判断"
    fi

    echo "--- 4) initramfs 实际内容（权威判据）---"
    LIST="$(lsinitramfs "${IMG}" 2>/dev/null)"
    [ -n "${LIST}" ] || { echo "   lsinitramfs 无输出，检查文件是否损坏"; exit 1; }

    if echo "${LIST}" | grep -qi 'casper'; then
        echo "   casper 脚本: OK"
        echo "${LIST}" | grep -i 'casper' | head -4 | sed 's/^/     /'
    else
        echo "   casper 脚本: MISSING  ← 装上 casper 后必须重跑 update-initramfs"
    fi

    for m in loop squashfs overlay isofs mlx5_core mlx5_ib; do
        if echo "${LIST}" | grep -qiE "/${m}\.ko"; then
            echo "   module ${m}: OK"
        else
            v="$( [ -f "${CFG}" ] && grep -E "^$(kconfig_of "$m" 2>/dev/null)=" "${CFG}" | head -1 | cut -d= -f2 || echo '')"
            if [ "${v:-}" = "y" ]; then
                echo "   module ${m}: 无 .ko（已编进内核，属正常）"
            else
                echo "   module ${m}: MISSING  ← 需要修"
            fi
        fi
    done

    echo "--- 5) 挂载工具 ---"
    if echo "${LIST}" | grep -qE '^usr/bin/(busybox|mount)$'; then
        echo "${LIST}" | grep -E '^usr/bin/(busybox|mount)$' | sed 's/^/   /'
    else
        echo "   没有独立的 mount 可执行文件 —— 由 busybox 内置提供，属正常"
    fi

    echo "--- 6) initramfs 分段情况（决定解包后的目录层级）---"
    # 多段（含 microcode）时 unmkinitramfs 会解出 main/ early/ 子目录，
    # 顶层直接 ls scripts/... 会误报 MISSING
    if echo "${LIST}" | grep -qE '^microcode|^early'; then
        echo "   多段镜像：unmkinitramfs 后内容在 main/ 下，顶层 scripts/ 查不到是假阴性"
    else
        echo "   单段镜像：内容直接解在当前目录"
    fi
    echo "================================================="
    exit 0
fi

# ---------- 前置检查 ----------
[ "$(id -u)" -eq 0 ] || { echo "[错误] 必须用 root 运行"; exit 1; }

for c in mksquashfs rsync xorriso; do
    command -v "$c" >/dev/null 2>&1 || {
        echo "[错误] 缺少 $c，请先执行："
        echo "       apt-get update && apt-get install -y squashfs-tools xorriso rsync casper initramfs-tools"
        exit 1
    }
done

# casper 是核心依赖：没有它 initramfs 里就没有无盘引导逻辑。
# 早期版本漏了这一步，导致按脚本跑完 initramfs 里没有 casper —— 这里强制补齐。
echo ">>> [0/7] 检查 casper 引导框架"
if ! dpkg-query -W -f='${Status}' casper 2>/dev/null | grep -q 'install ok installed'; then
    echo "    casper 未安装，正在安装…"
    apt-get update -qq
    apt-get install -y casper initramfs-tools
fi
[ -f /usr/share/initramfs-tools/hooks/casper ] || {
    echo "[错误] casper 装上了但 hooks/casper 不存在，请重装：apt-get install --reinstall casper"
    exit 1
}
echo "    casper: OK"

KVER="$(uname -r)"
ROOTFS="${BASE}/rootfs"
ISODIR="${BASE}/iso"
STAMP="${BASE}/${LABEL}.squashfs"
ISO="${BASE}/${LABEL}.iso"

echo "=============================================="
echo " 构建目标: ${LABEL}"
echo " 内核版本: ${KVER}"
echo "=============================================="

# ---------- 1. 清理机器唯一性标识 ----------
echo ">>> [1/7] 清理机器唯一性标识"
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /var/lib/systemd/random-seed
rm -rf /var/lib/cloud /var/log/cloud-init*

# ---------- 2. 解除本地磁盘依赖 ----------
echo ">>> [2/7] 解除本地磁盘依赖，日志改为纯内存"
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

systemctl disable \
    e2scrub_all.timer e2scrub_reap.service \
    fstrim.timer \
    apt-daily.timer apt-daily-upgrade.timer \
    unattended-upgrades.service 2>/dev/null || true

ln -sf /proc/self/mounts /etc/mtab

# ---------- 3. 瘦身 ----------
echo ">>> [3/7] 瘦身"
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /var/tmp/* /tmp/*
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
rm -rf /var/log/journal/*

# ---------- 4. initramfs ----------
echo ">>> [4/7] 生成支持网络启动的 initramfs"

# most 而不是 dep：dep 只含当前机器用到的模块，换硬件就废了
sed -i 's/^MODULES=.*/MODULES=most/' /etc/initramfs-tools/initramfs.conf
grep -q '^MODULES=' /etc/initramfs-tools/initramfs.conf || echo 'MODULES=most' >> /etc/initramfs-tools/initramfs.conf

touch /etc/initramfs-tools/modules
for m in loop squashfs overlay isofs \
         igb ixgbe i40e ice bnxt_en virtio_net \
         mlx5_core mlx5_ib ib_core ib_uverbs ib_umad rdma_ucm \
         nvme sd_mod ahci; do
    grep -qx "${m}" /etc/initramfs-tools/modules || echo "${m}" >> /etc/initramfs-tools/modules
done

# 兜底 hook：即使上面按名字没打进去（例如依赖链、别名问题），这里再强制一次。
# 编进内核（=y）的模块 force_load 会安全跳过，不会报错。
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

update-initramfs -c -k "${KVER}" 2>/dev/null || update-initramfs -u -k "${KVER}"

# ---------- 4b. 立即验证，不然后面白干 ----------
echo ">>> [4b/7] 验证 initramfs"
IMG="/boot/initrd.img-${KVER}"
LIST="$(lsinitramfs "${IMG}" 2>/dev/null || true)"
FATAL=0

if echo "${LIST}" | grep -qi casper; then
    echo "    casper 脚本: OK"
else
    # 某些环境下 casper 包自带的 hook 不会把脚本注入 initramfs。
    # 这里手工把 casper 运行时需要的文件塞进去，再重生成一次。
    echo "    casper 脚本: MISSING —— 加装手工注入 hook 后重试"
    cat > /etc/initramfs-tools/hooks/zz-casper-manual <<'EOF'
#!/bin/sh
# 兜底：casper 包自带 hook 未注入时，手工把 casper 运行时需要的文件打进 initramfs
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
    update-initramfs -u -k "${KVER}"
    LIST="$(lsinitramfs "${IMG}" 2>/dev/null || true)"
    if echo "${LIST}" | grep -qi casper; then
        echo "    casper 脚本: OK（手工注入成功）"
    else
        echo "    casper 脚本: 仍然 MISSING —— 构建中止"
        echo "    建议改用 dracut 路线（指南 5.2），不依赖 casper 的打包行为"
        FATAL=1
    fi
fi

for m in loop squashfs overlay isofs; do
    if echo "${LIST}" | grep -qiE "/${m}\.ko"; then
        echo "    module ${m}: OK"
    else
        CFGF="/boot/config-${KVER}"
        KC="$(kconfig_of "$m")"
        V="$( [ -f "${CFGF}" ] && grep -E "^${KC}=" "${CFGF}" | head -1 | cut -d= -f2 || echo '' )"
        if [ "${V:-}" = "y" ]; then
            echo "    module ${m}: 编进内核（无 .ko，正常）"
        else
            echo "    module ${m}: MISSING —— 构建中止"
            FATAL=1
        fi
    fi
done

[ "${FATAL}" -eq 0 ] || { echo "[错误] initramfs 自检未通过，中止"; exit 1; }

# ---------- 5. 同步根文件系统 ----------
echo ">>> [5/7] 同步根文件系统"
mkdir -p "${ROOTFS}"
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
    --exclude="${BASE}/*" \
    --exclude='/var/cache/apt/archives/*' \
    --exclude='/var/lib/apt/lists/*' \
    --exclude='/var/log/journal/*' \
    / "${ROOTFS}/"

mkdir -p "${ROOTFS}"/{proc,sys,dev/pts,dev/shm,run,run/lock,tmp,var/tmp,media,mnt}
chmod 1777 "${ROOTFS}"/tmp "${ROOTFS}"/var/tmp "${ROOTFS}"/dev/shm

# ---------- 6. 打包 ----------
echo ">>> [6/7] 打包 squashfs + ISO"
rm -f "${STAMP}"

# zstd 而不是 xz：xz 是 1MB 块整块解压，运行期随机读会把 CPU 吃穿
mksquashfs "${ROOTFS}" "${STAMP}" \
    -comp zstd \
    -Xcompression-level 19 \
    -b 1M \
    -processors "$(nproc)" \
    -noappend \
    -no-recovery \
    -e boot var/cache/apt/archives var/lib/apt/lists var/log/journal

mkdir -p "${ISODIR}/casper"
cp -f "${STAMP}" "${ISODIR}/casper/filesystem.squashfs"

rm -f "${ISO}"
xorriso -as mkisofs \
    -iso-level 3 -J -R -l \
    -V "${LABEL}" \
    -o "${ISO}" \
    "${ISODIR}"

# ---------- 7. 完成 ----------
echo
echo "=================== 构建完成 ==================="
echo " squashfs   ${STAMP}  ($(du -h "${STAMP}" | cut -f1))"
echo " iso        ${ISO}  ($(du -h "${ISO}" | cut -f1))"
echo " vmlinuz    /boot/vmlinuz-${KVER}"
echo " initrd     ${IMG}"
echo "================================================"
echo
echo "下一步：把上面 4 个文件传到 PXE 服务器的 /var/www/html/boot/，例如："
echo "  scp /boot/vmlinuz-${KVER}      <pxe>:/var/www/html/boot/"
echo "  scp ${IMG}                     <pxe>:/var/www/html/boot/"
echo "  scp ${ISO}                     <pxe>:/var/www/html/boot/"
echo
echo "然后修改 PXE 服务器上的 boot.ipxe，把版本号改成 ${LABEL}。"
