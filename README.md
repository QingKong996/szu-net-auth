# luci-app-szu-netauth

深圳大学宿舍区有线校园网自动认证，面向 OpenWrt、小米 AX3000T 和单个 WAN 账号。

路由器从 WAN 网口连接宿舍校园网，向 DrCOM ePortal 登录一次；LAN 和 Wi-Fi
客户端通过 OpenWrt 的 NAT 共享这条连接。它不会按 LAN 设备切换账号，也不会修改
设备 MAC 或模拟手机。

## 适用环境

- 深大宿舍区有线入口：`http://172.30.255.42:801/eportal`
- 路由器 WAN 通过 DHCP 获取校园网内网 IPv4 地址
- OpenWrt SNAPSHOT，或使用 `apk` 包管理器的新版 OpenWrt
- 小米 AX3000T RD03 / RD03v2 已验证运行环境
- 一个校园网认证卡号和一个密码

教学区使用的 `net.szu.edu.cn` SRun 门户不在本项目范围内。

## 行为

- 开机、WAN 重连和配置变化后自动检测并登录。
- 每 5 分钟从 WAN 探测公网，掉线后每 60 秒重试，最多 5 次。
- 认证和探测都绑定 WAN 获取的 IPv4 源地址，避免代理、TUN 或额外路由把凭据发往其他接口。
- 门户返回“IP 已经在线”后仍要等公网探测通过，才显示“在线”。
- 账号密码只保存在 `/etc/config/szu-netauth`，文件权限为 `0600`。
- 登录凭据通过权限为 `0600` 的临时 curl 配置传给 curl，不出现在进程参数或应用日志里。
- 运行日志默认进入 logd 的内存缓冲区，不磨损 flash。

该方案仍受校园网自身的会话和设备策略约束。设备规则要求批准时，应由用户自行确认
已经获得许可。

## 构建 `.apk`

下载与路由器固件版本相符的 MediaTek Filogic OpenWrt SDK。快照版 SDK 可从
[OpenWrt Downloads](https://downloads.openwrt.org/snapshots/targets/mediatek/filogic/)
获取。

```sh
SDK=openwrt-sdk-mediatek-filogic_gcc-15.3.0_musl.Linux-x86_64
tar --zstd -xf "$SDK.tar.zst"
bash ./build-apk.sh "/absolute/path/to/$SDK"
```

`build-apk.sh` 直接调用 SDK 自带的主机版 `apk mkpkg`。这个包只有 shell、UCI
和 LuCI 文件，没有需要交叉编译的 ELF，因此不需要 `CONFIG_ALL` 或内核构建。
脚本会生成正确的 conffiles 元数据、安装/升级/卸载脚本和 `root:root` 文件
所有权，自检签名完整性，然后把产物放到：

```text
dist/luci-app-szu-netauth-2.0.0-r1.apk
```

脚本优先使用无密码的 user namespace 来记录 root 所有权；若系统禁用该功能，
则退回 `fakeroot`。仍建议使用与路由器同一快照版本的 SDK。

仓库顶层 `Makefile` 仍保留标准 OpenWrt feed 包构建方式。熟悉 SDK 菜单配置时，
也可以安装 LuCI feeds 后执行：

```sh
make package/luci-app-szu-netauth/compile V=s
```

## 安装

把 `.apk` 上传到路由器：

```sh
scp luci-app-szu-netauth-2.0.0-r1.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1
apk add --allow-untrusted /tmp/luci-app-szu-netauth-2.0.0-r1.apk
```

SDK 本地构建的包没有 OpenWrt 官方签名，所以需要 `--allow-untrusted`。正式发布时
应由维护者使用固定密钥签名。

安装完成后打开：

**服务 → 校园网认证 → 设置**

填写：

- 校园网卡号
- 校园网密码
- WAN 逻辑接口，默认 `wan`

点击“保存并应用”，再到状态页点击“重新认证”。

## 命令行验证

```sh
/etc/szu-netauth/auth.sh --check
/etc/szu-netauth/auth.sh --status
/etc/szu-netauth/auth.sh --login
/etc/szu-netauth/auth.sh --tail 100

/etc/init.d/szu-netauth restart
logread -e szu-netauth
```

`--check` 会显示 WAN 地址、门户可达性和公网探测结果，但不会显示账号密码。

## 网络条件

路由器必须满足以下条件：

```sh
ubus call network.interface.wan status
```

返回的 `ipv4-address` 不能为空；并且：

```sh
curl --interface "$(ubus call network.interface.wan status |
	jsonfilter -e '@["ipv4-address"][0].address')" \
	http://172.30.255.42:801/eportal
```

可以访问认证页。正式认证后，确认防火墙的 `wan` 区域启用了 `masquerade`，
LAN 客户端才会共享 WAN 的认证连接。

如果路由器前面还有上游路由器，WAN 接口必须是面对校园网的那一个，而不是连接
私人热点的接口。否则认证请求会被发往错误网络。

## 配置项

配置文件：

```text
/etc/config/szu-netauth
```

| 选项 | 默认值 | 说明 |
|---|---:|---|
| `enabled` | `1` | 自动认证开关 |
| `cardid` | 空 | 单个校园网卡号 |
| `password` | 空 | 校园网密码 |
| `wan_interface` | `wan` | OpenWrt 逻辑 WAN 接口 |
| `net_check` | `300` | 在线复检间隔，秒 |
| `retry_interval` | `60` | 失败重试间隔，秒 |
| `retry_max` | `5` | 单轮最多登录次数 |
| `login_min_interval` | `30` | 两次登录提交的绝对最小间隔 |
| `persist_log` | `0` | 是否把日志写入 flash |

修改后执行：

```sh
uci commit szu-netauth
/etc/init.d/szu-netauth reload
```

## 回滚

```sh
/etc/init.d/szu-netauth stop
/etc/init.d/szu-netauth disable
apk del luci-app-szu-netauth
rm -f /etc/config/szu-netauth
```

如果只是想临时恢复手工登录：

```sh
/etc/init.d/szu-netauth stop
/etc/init.d/szu-netauth disable
```

配置文件和已认证的 WAN 会话不会被清除。

## 旧 `.ipk` 固件

仓库仍保留旧固件使用的 `.ipk` 构建脚本：

```sh
./build-ipk.sh
opkg install dist/luci-app-szu-netauth_2.0.0-1_all.ipk
```

适用于 AX3000T 当前 `apk` 固件时应使用 SDK 生成的 `.apk`。

## 协议来源与许可

认证协议来自
[`ceynri/szu-network-connecter`](https://github.com/ceynri/szu-network-connecter)
（MIT，Copyright (c) 2020 Ceynri），并参考
[`Baibook-craft/szu-net-auth`](https://github.com/Baibook-craft/szu-net-auth)
的 OpenWrt 集成。

本项目使用 MIT License，详见 [LICENSE](LICENSE) 与
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
