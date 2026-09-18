#!/usr/bin/env bash
# =============================================================================
#  squash2iso.sh —— 把已有的 .squashfs 打成 casper 可引导的 ISO
#
#  非破坏性：不动母机任何东西，只是把 squashfs 按 live 结构包一层 ISO。
#
#  用法: ./squash2iso.sh <xxx.squashfs> [卷标]
#        例: ./squash2iso.sh /opt/ramboot/noble-ramboot-v1.squashfs noble-ramboot-v1
#
#  产出: <同名>.iso，ISO 根目录下必须有 casper/filesystem.squashfs —— casper 认死这个路径。
# =============================================================================
set -euo pipefail

SRC="${1:-}"
VOL="${2:-RambootISO}"

if [ -z "${SRC}" ] || [ ! -f "${SRC}" ]; then
    echo "用法: $0 <xxx.squashfs> [卷标]"
    exit 1
fi

command -v xorriso >/dev/null 2>&1 || { echo "[错误] 缺少 xorriso：apt-get install -y xorriso"; exit 1; }
[ "$(id -u)" -eq 0 ] || echo "[提示] 非 root，iso9660 挂载校验会跳过（不影响打包）"

SRCDIR="$(cd "$(dirname "${SRC}")" && pwd)"
SRCBASE="$(basename "${SRC}")"
STAGE="${SRCDIR}/iso-stage"
ISO="${SRC%.squashfs}.iso"

echo "=============================================="
echo " 源 squashfs : ${SRC}"
echo " 输出 ISO    : ${ISO}"
echo "=============================================="

rm -rf "${STAGE}"
mkdir -p "${STAGE}/casper"
cp -v "${SRC}" "${STAGE}/casper/filesystem.squashfs"

rm -f "${ISO}"
xorriso -as mkisofs \
    -iso-level 3 -J -R -l \
    -V "${VOL}" \
    -o "${ISO}" \
    "${STAGE}"

echo
echo "--- ISO 内容（casper 会来找 casper/filesystem.squashfs）---"
if command -v isoinfo >/dev/null 2>&1; then
    isoinfo -J -l -i "${ISO}" 2>/dev/null | grep -i filesystem.squashfs || echo "   警告：isoinfo 没列到 filesystem.squashfs"
elif command -v mount >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    MNT="/tmp/squash2iso-mnt-$$"
    mkdir -p "${MNT}"
    mount -o loop,ro "${ISO}" "${MNT}" && {
        ls -lh "${MNT}/casper/filesystem.squashfs" || echo "   警告：ISO 里没有 casper/filesystem.squashfs"
        umount "${MNT}"
    } || echo "   跳过挂载校验"
    rmdir "${MNT}" 2>/dev/null || true
else
    echo "   跳过（缺少 isoinfo）"
fi

echo
echo "=================== 完成 ==================="
echo " iso   ${ISO}  ($(du -h "${ISO}" | cut -f1))"
echo " 源    ${SRCBASE}  ($(du -h "${SRC}" | cut -f1))"
echo "============================================"
echo
echo "下一步：把三个文件传到 PXE 服务器（假设 HTTP 根是 /var/www/html）"
echo "  scp /boot/vmlinuz-$(uname -r)   <pxe>:/var/www/html/x86/FD/vmlinuz"
echo "  scp /boot/initrd.img-$(uname -r) <pxe>:/var/www/html/x86/FD/initrd"
echo "  scp ${ISO}                       <pxe>:/var/www/html/x86/FD/"
echo
echo "iPXE 菜单写法见指南第 7.5 节。"
