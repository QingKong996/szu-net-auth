#
# Copyright (C) 2026 baibook
#
# This is free software, licensed under the MIT License.
#
# 这是标准 OpenWrt feed 包。OpenWrt 24.10 以前由 SDK 生成 .ipk；
# 使用 apk 的 OpenWrt SNAPSHOT / 25.x 会由同一份 Makefile 生成 .apk。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-szu-netauth
PKG_VERSION:=2.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=QingKong996

LUCI_TITLE:=SZU dormitory campus network authentication
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file +curl +jsonfilter
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# ---------------------------------------------------------------------------
# 显式写 install 规则，覆盖 luci.mk 的默认目录映射。
#
# 为什么不让 luci.mk 自动映射 root/：显式写死之后，装到路由器上的路径
# 一目了然，不依赖 luci.mk 的版本差异。
#
# 为什么需要在 install 之后补一次 chmod：Git 的 core.fileMode 在 Windows
# 上默认关闭，clone 出来的 auth.sh / init.d 脚本很可能丢掉可执行位。
# 打出来的包缺 x 位 = 服务起不来，所以这里强制纠正一次。
# ---------------------------------------------------------------------------
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/
	$(CP) ./root/* $(1)/
	chmod 0755 $(1)/etc/init.d/szu-netauth
	chmod 0755 $(1)/etc/uci-defaults/50-luci-app-szu-netauth
	chmod 0755 $(1)/etc/szu-netauth/auth.sh
	# 0600：配置文件里是明文卡号密码，仅 root 可读。
	chmod 0600 $(1)/etc/config/szu-netauth
endef

# 用户改过的卡号密码，升级时不能被默认配置覆盖。
define Package/$(PKG_NAME)/conffiles
/etc/config/szu-netauth
endef

# 默认 luci.mk postinst 不会执行 uci-defaults。安装/升级后立即迁移旧配置、
# 收紧配置权限、清理 LuCI 缓存并启用服务，避免必须重启一次才生效。
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if [ -x /etc/uci-defaults/50-luci-app-szu-netauth ]; then
	/etc/uci-defaults/50-luci-app-szu-netauth
	rm -f /etc/uci-defaults/50-luci-app-szu-netauth
fi
exit 0
endef

# 卸载前把常驻服务停掉并取消开机自启，否则 init.d 脚本被删了、
# 进程还在后台跑。
#
# 升级（$1 = upgrade）时故意什么都不做 —— 让认证服务继续跑，不要白掉一次线。
define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
case "$$1" in
	remove|purge)
		if [ -x /etc/init.d/szu-netauth ]; then
			/etc/init.d/szu-netauth stop    2>/dev/null
			/etc/init.d/szu-netauth disable 2>/dev/null
		fi

		_pidfile=/var/run/szu-netauth/daemon.pid
		_i=0
		while [ "$$_i" -lt 15 ]; do
			_dp="$$(cat "$$_pidfile" 2>/dev/null)"
			[ -z "$$_dp" ] || ! kill -0 "$$_dp" 2>/dev/null && break
			sleep 1
			_i=$$((_i + 1))
		done

		_dp="$$(cat "$$_pidfile" 2>/dev/null)"
		if [ -n "$$_dp" ] && kill -0 "$$_dp" 2>/dev/null; then
			kill "$$_dp" 2>/dev/null
			sleep 1
			kill -9 "$$_dp" 2>/dev/null
		fi
		;;
esac
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
