#!/usr/bin/env bash
#
# 使用 apk SDK 的主机工具直接打包 luci-app-szu-netauth。
#
# 本包只有 shell、UCI 和 LuCI 前端文件，没有要交叉编译的二进制。直接调用 SDK
# 自带的 apk mkpkg 可以避免部分快照 SDK 的 CONFIG_ALL 默认值把整套 OpenWrt
# 包和内核模块都带入构建。
#
# 用法：
#   ./build-apk.sh /path/to/openwrt-sdk
#   OPENWRT_SDK=/path/to/openwrt-sdk ./build-apk.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK="${OPENWRT_SDK:-${1:-}}"
PKG_NAME=luci-app-szu-netauth

die() {
	printf '错误：%s\n' "$*" >&2
	exit 1
}

if [ -z "$SDK" ] || [ ! -f "$SDK/rules.mk" ]; then
	printf '用法：%s /path/to/openwrt-sdk\n' "$0" >&2
	die "请传入使用 apk 的 OpenWrt SDK 根目录"
fi

SDK="$(cd "$SDK" && pwd)"
APK="$SDK/staging_dir/host/bin/apk"
MKHASH="$SDK/staging_dir/host/bin/mkhash"

[ -x "$APK" ] || die "SDK 缺少 apk 主机工具：$APK"
[ -x "$MKHASH" ] || die "SDK 缺少 mkhash 主机工具：$MKHASH"
"$APK" --version | grep -q '^apk-tools 3\.' ||
	die "需要 apk-tools 3.x SDK，当前版本不匹配"

PKG_VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$HERE/Makefile" | head -n1)"
PKG_RELEASE="$(sed -n 's/^PKG_RELEASE:=//p' "$HERE/Makefile" | head -n1)"
PKG_MAINTAINER="$(sed -n 's/^PKG_MAINTAINER:=//p' "$HERE/Makefile" | head -n1)"
if [ -z "$PKG_VERSION" ] || [ -z "$PKG_RELEASE" ] || [ -z "$PKG_MAINTAINER" ]; then
	die "无法从 Makefile 读取版本或维护者"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/$PKG_NAME.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

STAGE="$WORK/stage"
SCRIPTS="$WORK/scripts"
PACKAGE_FILE="$PKG_NAME-$PKG_VERSION-r$PKG_RELEASE.apk"
PACKAGE_TMP="$WORK/$PACKAGE_FILE"
OUT_DIR="$HERE/dist"

mkdir -p "$STAGE" "$SCRIPTS" "$OUT_DIR"
cp -a "$HERE/root/." "$STAGE/"

# 从 Windows / DrvFs 复制过来的文件可能全被标成 0777。APK 会记录这些
# 权限，因此先在 ext4 临时目录中统一收紧，再单独恢复三个可执行脚本。
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +
chmod 0600 "$STAGE/etc/config/szu-netauth"
chmod 0755 "$STAGE/etc/init.d/szu-netauth"
chmod 0755 "$STAGE/etc/szu-netauth/auth.sh"
chmod 0755 "$STAGE/etc/uci-defaults/50-$PKG_NAME"

# OpenWrt 3.x 的 apk 包把文件清单和 conffiles 索引一并放进
# /lib/apk/packages/。先生成清单，再放索引文件，避免索引列出自己。
mkdir -p "$STAGE/lib/apk/packages"
(
	cd "$STAGE"
	find . -type f -o -type l | sed 's#^\.##' | LC_ALL=C sort
) > "$STAGE/lib/apk/packages/$PKG_NAME.list"

printf '%s\n' "/etc/config/szu-netauth" \
	> "$STAGE/lib/apk/packages/$PKG_NAME.conffiles"
config_hash="$("$MKHASH" sha256 "$STAGE/etc/config/szu-netauth")"
printf '%s %s\n' "/etc/config/szu-netauth" "$config_hash" \
	> "$STAGE/lib/apk/packages/$PKG_NAME.conffiles_static"
chmod 0644 "$STAGE/lib/apk/packages/$PKG_NAME.list" \
	"$STAGE/lib/apk/packages/$PKG_NAME.conffiles" \
	"$STAGE/lib/apk/packages/$PKG_NAME.conffiles_static"

# 下面三个片段与 OpenWrt package-pack.mk 生成的脚本结构一致：
# default_postinst/default_prerm 负责 conffiles 和包数据库，插件自己的
# 一次性迁移以及卸载前停服放在它们之后。
cat > "$SCRIPTS/custom-postinst" <<'EOF'
[ -n "${IPKG_INSTROOT}" ] && exit 0
if [ -x /etc/uci-defaults/50-luci-app-szu-netauth ]; then
	/etc/uci-defaults/50-luci-app-szu-netauth
	rm -f /etc/uci-defaults/50-luci-app-szu-netauth
fi
exit 0
EOF

cat > "$SCRIPTS/custom-prerm" <<'EOF'
[ -n "${IPKG_INSTROOT}" ] && exit 0
case "$1" in
	remove|purge)
		if [ -x /etc/init.d/szu-netauth ]; then
			/etc/init.d/szu-netauth stop 2>/dev/null
			/etc/init.d/szu-netauth disable 2>/dev/null
		fi
		;;
esac
exit 0
EOF

cat > "$SCRIPTS/post-install" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT}/lib/functions.sh"
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-szu-netauth"
add_group_and_user
default_postinst
EOF
sed '1{/^#!/d;}' "$SCRIPTS/custom-postinst" >> "$SCRIPTS/post-install"

{
	printf '%s\n' '#!/bin/sh' 'export PKG_UPGRADE=1'
	sed '1{/^#!/d;}' "$SCRIPTS/post-install"
} > "$SCRIPTS/post-upgrade"

cat > "$SCRIPTS/pre-deinstall" <<'EOF'
#!/bin/sh
[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0
. "${IPKG_INSTROOT}/lib/functions.sh"
export root="${IPKG_INSTROOT}"
export pkgname="luci-app-szu-netauth"
default_prerm
EOF
sed '1{/^#!/d;}' "$SCRIPTS/custom-prerm" >> "$SCRIPTS/pre-deinstall"

chmod 0755 "$SCRIPTS/post-install" "$SCRIPTS/post-upgrade" \
	"$SCRIPTS/pre-deinstall"
sh -n "$SCRIPTS/post-install"
sh -n "$SCRIPTS/post-upgrade"
sh -n "$SCRIPTS/pre-deinstall"

BUILD_CMD=(
	"$APK" mkpkg
	--info "name:$PKG_NAME"
	--info "version:$PKG_VERSION-r$PKG_RELEASE"
	--info "tags:openwrt:section=luci"
	--info "description:SZU dormitory campus network authentication"
	--info "arch:noarch"
	--info "license:MIT"
	--info "origin:$PKG_NAME"
	--info "url:https://github.com/QingKong996/szu-net-auth"
	--info "maintainer:$PKG_MAINTAINER"
	--info "depends:libc luci-base rpcd rpcd-mod-file curl jsonfilter"
	--script "post-install:$SCRIPTS/post-install"
	--script "post-upgrade:$SCRIPTS/post-upgrade"
	--script "pre-deinstall:$SCRIPTS/pre-deinstall"
	--files "$STAGE"
)
if [ -f "$SDK/private-key.pem" ]; then
	BUILD_CMD+=(--sign "$SDK/private-key.pem")
fi
BUILD_CMD+=(--output "$PACKAGE_TMP")

# 包内文件必须记录为 root:root，否则路由器上的 apk 可能尝试还原一个不存在的
# 本机用户名。优先使用不需要密码的 user namespace；容器不允许时退回 fakeroot。
BUILDER="$WORK/package-as-root.sh"
{
	printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
	printf 'chown -R 0:0 %q %q\n' "$STAGE" "$SCRIPTS"
	printf '%q ' "${BUILD_CMD[@]}"
	printf '\n'
} > "$BUILDER"
chmod 0755 "$BUILDER"

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"
if [ "$(id -u)" -eq 0 ]; then
	bash "$BUILDER"
elif unshare -r true >/dev/null 2>&1; then
	unshare -r bash "$BUILDER"
elif command -v fakeroot >/dev/null 2>&1; then
	fakeroot bash "$BUILDER"
else
	die "无法建立 root 文件元数据；请启用 user namespace 或安装 fakeroot"
fi

"$APK" --allow-untrusted verify "$PACKAGE_TMP" >/dev/null ||
	die "APK 完整性自检失败"

owners="$("$APK" adbdump "$PACKAGE_TMP" |
	sed -n 's/^[[:space:]]*user: //p' | LC_ALL=C sort -u)"
[ "$owners" = "root" ] || die "APK 内文件所有者不是 root：${owners:-未知}"

cp "$PACKAGE_TMP" "$OUT_DIR/"
printf '完成：%s\n' "$OUT_DIR/$PACKAGE_FILE"
sha256sum "$OUT_DIR/$PACKAGE_FILE"
