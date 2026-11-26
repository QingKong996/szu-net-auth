#!/bin/sh
# =============================================================================
#  深圳大学宿舍区校园网自动认证
#  OpenWrt / AX3000T / DrCOM ePortal / 单账号
# -----------------------------------------------------------------------------
#  认证协议参考：
#    - Baibook-craft/szu-net-auth
#    - ceynri/szu-network-connecter
#  二者均为 MIT License。
#
#  设计边界：
#    - 只认证路由器自己的 WAN IPv4，不在 LAN 设备之间轮换账号。
#    - 凭据不会出现在 curl 命令的 argv 或本脚本日志中。
#    - 门户返回“IP 已经在线”后仍必须通过公网探测才判定成功。
# =============================================================================

export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin
umask 077

# rc.common 会加载它，但手动执行 auth.sh 时也必须能使用 config_load。
# shellcheck source=/dev/null
[ -f /lib/functions.sh ] && . /lib/functions.sh

TAG=szu-netauth
CONF_PKG=szu-netauth
CONF_SEC=global
STATE_DIR=/var/run/szu-netauth
STATUS_FILE=$STATE_DIR/status.json
HEARTBEAT=$STATE_DIR/heartbeat
WAKE_FILE=$STATE_DIR/wake
LOGIN_TS_FILE=$STATE_DIR/last_login
FAIL_FILE=$STATE_DIR/fail_count
PERSIST_LOG=/etc/szu-netauth/state.log

# 宿舍区有线入口。固定为 IPv4 字面地址，避免 DNS 被代理或校园重定向接管。
EPORTAL_BASE='http://172.30.255.42:801'
EPORTAL_PAGE="$EPORTAL_BASE/eportal"
EPORTAL_LOGIN="$EPORTAL_BASE/eportal/portal/login"

# 两个独立的公网探测目标。只有正文或状态码完全匹配才算在线，
# 不跟随跳转，因此门户劫持会被识别为离线。
NCSI_URL='http://www.msftconnecttest.com/connecttest.txt'
GEN204_URL='http://connect.rom.miui.com/generate_204'

UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) SZUNetAuth/2.0'
WATCHDOG_LIMIT=240

# 运行时状态，由 cfg / 探测函数更新。
ENABLED=1
CARDID=''
PASSWORD=''
WAN_INTERFACE='wan'
NET_CHECK=300
RETRY_INTERVAL=60
RETRY_MAX=5
LOGIN_MIN=30
PERSIST_LOG_ON=0
WANIP=''
PORTAL_OK=0
LOGIN_OK=0
LOGIN_MSG=''
LOGIN_KIND=''

nlog() { logger -t "$TAG" "$*"; }

clamp() {
	_v=$1
	_lo=$2
	_hi=$3
	case "$_v" in ''|*[!0-9]*) _v=$_lo ;; esac
	[ "$_v" -lt "$_lo" ] && _v=$_lo
	[ "$_v" -gt "$_hi" ] && _v=$_hi
	printf '%s' "$_v"
}

jesc() {
	printf '%s' "$1" | tr -d '\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

jnum() {
	_jn=$(printf '%s' "$2" \
		| sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([-0-9][0-9]*\)".*/\1/p' \
		| head -n1)
	[ -n "$_jn" ] || _jn=$(printf '%s' "$2" \
		| sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([-0-9][0-9]*\).*/\1/p' \
		| head -n1)
	printf '%s' "$_jn"
}

jstr() {
	printf '%s' "$2" \
		| sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
		| head -n1 | tr -d '\r\n' | head -c 240
}

tr_msg() {
	case "$1" in
		'ldap auth error') printf '%s' '账号或密码错误（ldap auth error）' ;;
		'error hid')       printf '%s' '登录请求过于频繁，请稍后重试（error hid）' ;;
		*)                 printf '%s' "$1" ;;
	esac
}

# 门户错误正文可能回显卡号。只要检测到凭据子串，就丢弃原文，
# 确保状态页与 logd 中不会出现真实凭据。
sanitize_portal_msg() {
	_msg_in=$1
	if printf '%s' "$_msg_in" | LC_ALL=C grep -q '[^ -~]'; then
		printf '%s' '门户拒绝登录（原始提示非 UTF-8，已转换为通用错误）'
		return 0
	fi
	if [ -n "$CARDID" ] && printf '%s' "$_msg_in" | grep -Fq -- "$CARDID"; then
		printf '%s' '门户拒绝登录（错误详情含账号信息，已隐藏）'
		return 0
	fi
	if [ -n "$PASSWORD" ] && printf '%s' "$_msg_in" | grep -Fq -- "$PASSWORD"; then
		printf '%s' '门户拒绝登录（错误详情含密码信息，已隐藏）'
		return 0
	fi
	printf '%s' "$_msg_in"
}

plog() {
	[ "$PERSIST_LOG_ON" = "1" ] || return 0
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PERSIST_LOG"
	_sz=$(wc -c < "$PERSIST_LOG" 2>/dev/null)
	if [ -n "$_sz" ] && [ "$_sz" -gt 131072 ]; then
		mv -f "$PERSIST_LOG" "$PERSIST_LOG.1"
	fi
}

cfg() {
	config_load "$CONF_PKG"
	config_get_bool ENABLED        "$CONF_SEC" enabled              1
	config_get      CARDID         "$CONF_SEC" cardid               ''
	config_get      PASSWORD       "$CONF_SEC" password             ''
	config_get      WAN_INTERFACE  "$CONF_SEC" wan_interface        'wan'
	config_get      NET_CHECK      "$CONF_SEC" net_check            300
	config_get      RETRY_INTERVAL "$CONF_SEC" retry_interval       60
	config_get      RETRY_MAX      "$CONF_SEC" retry_max            5
	config_get      LOGIN_MIN      "$CONF_SEC" login_min_interval   30
	config_get_bool PERSIST_LOG_ON "$CONF_SEC" persist_log          0

	NET_CHECK=$(clamp "$NET_CHECK" 60 86400)
	RETRY_INTERVAL=$(clamp "$RETRY_INTERVAL" 15 3600)
	RETRY_MAX=$(clamp "$RETRY_MAX" 1 20)
	LOGIN_MIN=$(clamp "$LOGIN_MIN" 10 3600)

	case "$WAN_INTERFACE" in
		''|*[!A-Za-z0-9_]*) WAN_INTERFACE=wan ;;
	esac

	# UCI 文本选项不允许可靠地保存多行凭据；去除换行，避免污染 curl 配置。
	CARDID=$(printf '%s' "$CARDID" | tr -d '\r\n')
	PASSWORD=$(printf '%s' "$PASSWORD" | tr -d '\r\n')
}

curlx() {
	curl -sS --noproxy '*' -A "$UA" "$@"
}

# 所有认证与公网探测都绑定 WAN 的 IPv4 源地址。这样即使设备装有代理、
# TUN 或额外默认路由，也不会从 LAN 或其他接口误发凭据。
curl_wan() {
	if [ -n "$WANIP" ]; then
		curlx -4 --interface "$WANIP" "$@"
	else
		return 28
	fi
}

wan_ip() {
	ubus call "network.interface.$WAN_INTERFACE" status 2>/dev/null \
		| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null
}

portal_reachable() {
	PORTAL_OK=0
	_code=$(curl_wan -m 6 -o /dev/null -w '%{http_code}' "$EPORTAL_PAGE" 2>/dev/null)
	case "$_code" in
		200|301|302|303|307|308) PORTAL_OK=1; return 0 ;;
	esac
	return 1
}

http_probe() {
	_r=$(curl_wan -m 7 -w '\n%{http_code}' "$NCSI_URL" 2>/dev/null)
	_code=$(printf '%s' "$_r" | tail -n1)
	_body=$(printf '%s' "$_r" | sed '$d')
	if [ "$_code" = "200" ] && printf '%s' "$_body" | grep -q 'Microsoft Connect Test'; then
		return 0
	fi

	_code=$(curl_wan -m 7 -o /dev/null -w '%{http_code}' "$GEN204_URL" 2>/dev/null)
	[ "$_code" = "204" ]
}

wait_online() {
	_try=1
	while [ "$_try" -le 3 ]; do
		http_probe && return 0
		[ "$_try" -lt 3 ] && sleep 2
		_try=$((_try + 1))
	done
	return 1
}

read_fail_count() {
	_f=$(cat "$FAIL_FILE" 2>/dev/null)
	case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
	printf '%s' "$_f"
}

reset_fail() {
	rm -f "$FAIL_FILE" 2>/dev/null
}

curl_config_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 认证请求通过 curl 的 0600 配置读取，凭据不会出现在 curl 的 argv。
portal_login_request() {
	_cfg="$STATE_DIR/login-curl.$$"
	_id=$(curl_config_escape ",0,$CARDID")
	_pw=$(curl_config_escape "$PASSWORD")
	{
		printf 'url = "%s"\n' "$EPORTAL_LOGIN"
		printf '%s\n' 'data-urlencode = "callback=dr1003"'
		printf '%s\n' 'data-urlencode = "login_method=1"'
		printf 'data-urlencode = "user_account=%s"\n' "$_id"
		printf 'data-urlencode = "user_password=%s"\n' "$_pw"
		printf '%s\n' 'data-urlencode = "wlan_user_ip="'
		printf '%s\n' 'data-urlencode = "wlan_user_ipv6="'
		printf '%s\n' 'data-urlencode = "wlan_user_mac=000000000000"'
		printf '%s\n' 'data-urlencode = "wlan_ac_ip="'
		printf '%s\n' 'data-urlencode = "wlan_ac_name="'
		printf '%s\n' 'data-urlencode = "jsVersion=4.1.3"'
		printf '%s\n' 'data-urlencode = "terminal_type=1"'
		printf '%s\n' 'data-urlencode = "lang=zh"'
		printf '%s\n' 'data-urlencode = "v=10353"'
	} > "$_cfg"
	chmod 600 "$_cfg" 2>/dev/null
	_resp=$(curl_wan -G -m 10 --config "$_cfg" 2>/dev/null)
	_rc=$?
	rm -f "$_cfg"
	[ "$_rc" -eq 0 ] || return "$_rc"
	printf '%s' "$_resp"
}

login_once() {
	LOGIN_OK=0
	LOGIN_MSG=''
	LOGIN_KIND=''

	if [ -z "$CARDID" ] || [ -z "$PASSWORD" ]; then
		LOGIN_MSG='校园网卡号或密码尚未配置'
		LOGIN_KIND='unconfigured'
		return 1
	fi
	if [ -z "$WANIP" ]; then
		LOGIN_MSG='WAN 尚未获取 IPv4 地址'
		LOGIN_KIND='no-wan'
		return 1
	fi
	if ! portal_reachable; then
		LOGIN_MSG='宿舍区认证入口不可达，暂不发送凭据'
		LOGIN_KIND='portal'
		return 1
	fi

	_resp=$(portal_login_request)
	_rc=$?
	date +%s > "$LOGIN_TS_FILE"
	if [ "$_rc" -ne 0 ] || [ -z "$_resp" ]; then
		LOGIN_MSG="认证请求失败（curl=$_rc）"
		LOGIN_KIND='network'
		printf '%s' "$LOGIN_MSG" > "$STATE_DIR/last_login_result"
		return 1
	fi

	_result=$(jnum result "$_resp")
	_ret=$(jnum ret_code "$_resp")
	_msg=$(jstr msg "$_resp")
	[ -n "$_msg" ] && _msg=$(sanitize_portal_msg "$_msg")
	[ -n "$_msg" ] && _msg=$(tr_msg "$_msg")

	if [ "$_result" != "1" ] && [ "$_ret" != "2" ]; then
		LOGIN_MSG=${_msg:-认证被拒绝}
		LOGIN_KIND='rejected'
		printf '%s' "$LOGIN_MSG" > "$STATE_DIR/last_login_result"
		return 1
	fi

	# 门户可能返回“IP 已经在线”，这不等于本次提交的密码正确，也不等于
	# 外网真的可用。必须再从 WAN 探测公网；给会话下发留有限的重试时间。
	if wait_online; then
		if [ "$_result" = "1" ]; then
			LOGIN_MSG='认证成功'
			LOGIN_KIND='success'
		else
			LOGIN_MSG='该 WAN 已在线，公网探测通过'
			LOGIN_KIND='online'
		fi
		LOGIN_OK=1
		printf '%s' "$LOGIN_MSG" > "$STATE_DIR/last_login_result"
		return 0
	fi

	LOGIN_MSG='门户已接受请求，但公网探测仍失败'
	LOGIN_KIND='not-online'
	printf '%s' "$LOGIN_MSG" > "$STATE_DIR/last_login_result"
	return 1
}

write_status() {
	_state=$1
	_detail=$2
	_color=$3
	_campus=$4
	_online=$5
	_interval=$6
	mkdir -p "$STATE_DIR"

	_now=$(date +%s)
	_ll=$(cat "$LOGIN_TS_FILE" 2>/dev/null)
	case "$_ll" in ''|*[!0-9]*) _ll=0 ;; esac
	_lr=$(cat "$STATE_DIR/last_login_result" 2>/dev/null)
	_fc=$(read_fail_count)
	_pid=$(cat "$STATE_DIR/daemon.pid" 2>/dev/null)
	case "$_pid" in ''|*[!0-9]*) _pid=0 ;; esac
	_dr=0
	[ "$_pid" -gt 0 ] && kill -0 "$_pid" 2>/dev/null && _dr=1
	_configured=0
	[ -n "$CARDID" ] && [ -n "$PASSWORD" ] && _configured=1

	cat > "$STATUS_FILE.tmp" <<EOF
{"ts":$_now,"time":"$(date '+%Y-%m-%d %H:%M:%S')","state":"$_state","detail":"$(jesc "$_detail")","color":"$_color","enabled":$ENABLED,"configured":$_configured,"campus":$_campus,"portal":$PORTAL_OK,"online":$_online,"wan_interface":"$(jesc "$WAN_INTERFACE")","wan_ip":"$(jesc "$WANIP")","net_check":$NET_CHECK,"retry_interval":$RETRY_INTERVAL,"retry_max":$RETRY_MAX,"last_check":$_now,"last_login":$_ll,"last_login_result":"$(jesc "$_lr")","login_kind":"$(jesc "$LOGIN_KIND")","fail_count":$_fc,"next_retry":0,"daemon_pid":$_pid,"daemon_running":$_dr,"interval":$_interval,"portal_url":"$(jesc "$EPORTAL_PAGE")"}
EOF
	mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}

sleep_loop() {
	_total=$1
	[ "$_total" -lt 1 ] && _total=1
	_left=$_total
	while [ "$_left" -gt 0 ]; do
		_slice=5
		[ "$_left" -lt "$_slice" ] && _slice=$_left
		sleep "$_slice"
		_left=$((_left - _slice))
		touch "$HEARTBEAT"
		if [ -f "$WAKE_FILE" ]; then
			return 0
		fi
	done
}

daemon_main() {
	mkdir -p "$STATE_DIR"
	echo $$ > "$STATE_DIR/daemon.pid"
	trap 'nlog "收到终止信号，退出"; rm -f "$STATE_DIR/daemon.pid"; exit 0' TERM INT
	nlog "守护进程启动（pid $$，单账号、固定 WAN）"

	while :; do
		_now=$(date +%s)
		if [ -f "$HEARTBEAT" ]; then
			_hb=$(stat -c %Y "$HEARTBEAT" 2>/dev/null)
			case "$_hb" in ''|*[!0-9]*) _hb=$_now ;; esac
			if [ $((_now - _hb)) -gt "$WATCHDOG_LIMIT" ]; then
				nlog "看门狗触发：心跳停滞 $((_now - _hb)) 秒，退出交给 procd 重启"
				rm -f "$STATE_DIR/daemon.pid"
				exit 1
			fi
		fi

		cfg
		WANIP=$(wan_ip)
		PORTAL_OK=0
		LOGIN_KIND=''
		_wake=$(cat "$WAKE_FILE" 2>/dev/null)
		rm -f "$WAKE_FILE"
		_force=0
		[ "$_wake" = "login" ] && _force=1

		if [ "$ENABLED" != "1" ]; then
			reset_fail
			write_status disabled '自动认证已在配置中停用' grey 0 0 30
			sleep_loop 30
			continue
		fi

		if [ -z "$CARDID" ] || [ -z "$PASSWORD" ]; then
			reset_fail
			write_status unconfigured '请先在「设置」中填写校园网卡号和密码' grey 0 0 30
			sleep_loop 30
			continue
		fi

		if [ -z "$WANIP" ]; then
			reset_fail
			write_status waiting "等待接口 $WAN_INTERFACE 获取 IPv4 地址" grey 0 0 5
			sleep_loop 5
			continue
		fi

		if [ "$_force" = "0" ] && http_probe; then
			reset_fail
			write_status online "校园网在线（WAN $WANIP）" green 1 1 "$NET_CHECK"
			nlog "在线（WAN $WANIP），${NET_CHECK} 秒后再次检测"
			sleep_loop "$NET_CHECK"
			continue
		fi

		portal_reachable
		_campus=$PORTAL_OK
		if [ "$PORTAL_OK" != "1" ]; then
			write_status upstream "WAN $WANIP 尚未认证，且宿舍区认证入口不可达" grey 0 0 15
			sleep_loop 15
			continue
		fi

		_fc=$(read_fail_count)
		[ "$_force" = "1" ] && _fc=0 && reset_fail

		if [ "$_fc" -ge "$RETRY_MAX" ]; then
			reset_fail
			write_status giveup "本轮已尝试 $_fc 次仍未成功，${NET_CHECK} 秒后重新检测" red 1 0 "$NET_CHECK"
			sleep_loop "$NET_CHECK"
			continue
		fi

		_now=$(date +%s)
		_ll=$(cat "$LOGIN_TS_FILE" 2>/dev/null)
		case "$_ll" in ''|*[!0-9]*) _ll=0 ;; esac
		_elapsed=$((_now - _ll))
		if [ "$_elapsed" -lt "$LOGIN_MIN" ]; then
			_wait=$((LOGIN_MIN - _elapsed))
			write_status offline "登录限流：${_wait} 秒后再提交" orange 1 0 "$_wait"
			sleep_loop "$_wait"
			continue
		fi

		_n=$((_fc + 1))
		write_status offline "检测到未认证，正在执行第 ${_n}/${RETRY_MAX} 次登录" orange 1 0 "$RETRY_INTERVAL"
		nlog "检测到离线（WAN $WANIP），执行第 ${_n}/${RETRY_MAX} 次登录"
		login_once

		if [ "$LOGIN_OK" = "1" ]; then
			reset_fail
			write_status online "$LOGIN_MSG（WAN $WANIP）" green 1 1 "$NET_CHECK"
			nlog "登录成功：$LOGIN_MSG"
			plog "登录成功：$LOGIN_MSG"
			sleep_loop "$NET_CHECK"
			continue
		fi

		printf '%s' "$_n" > "$FAIL_FILE"
		nlog "登录失败（${_n}/${RETRY_MAX}）：$LOGIN_MSG"
		plog "登录失败（${_n}/${RETRY_MAX}）：$LOGIN_MSG"
		if [ "$_n" -ge "$RETRY_MAX" ]; then
			reset_fail
			write_status giveup "连续 $_n 次登录失败：$LOGIN_MSG；${NET_CHECK} 秒后重试" red 1 0 "$NET_CHECK"
			sleep_loop "$NET_CHECK"
		else
			write_status fail "第 ${_n}/${RETRY_MAX} 次失败：$LOGIN_MSG；${RETRY_INTERVAL} 秒后重试" red 1 0 "$RETRY_INTERVAL"
			sleep_loop "$RETRY_INTERVAL"
		fi
	done
}

once_main() {
	mkdir -p "$STATE_DIR"
	cfg
	WANIP=$(wan_ip)
	if [ "$ENABLED" != "1" ]; then
		echo '自动认证已停用'
		return 0
	fi
	if [ -z "$CARDID" ] || [ -z "$PASSWORD" ]; then
		echo '尚未配置校园网卡号或密码'
		return 1
	fi
	if [ -z "$WANIP" ]; then
		echo "接口 $WAN_INTERFACE 尚未获取 IPv4 地址"
		return 1
	fi
	portal_reachable
	if http_probe; then
		reset_fail
		echo "在线（$WANIP），无需登录"
		return 0
	fi
	login_once
	[ "$LOGIN_OK" = "1" ] && { echo "成功：$LOGIN_MSG"; return 0; }
	echo "失败：$LOGIN_MSG"
	return 1
}

login_main() {
	mkdir -p "$STATE_DIR"
	cfg
	WANIP=$(wan_ip)
	login_once
	[ "$LOGIN_OK" = "1" ] && { echo "成功：$LOGIN_MSG"; return 0; }
	echo "失败：$LOGIN_MSG"
	return 1
}

check_main() {
	cfg
	WANIP=$(wan_ip)
	echo "接口名称        : $WAN_INTERFACE"
	printf 'WAN IPv4        : %s\n' "${WANIP:-（无）}"
	echo "认证入口        : $EPORTAL_PAGE"
	if portal_reachable; then
		echo '入口可达        : 是'
	else
		echo '入口可达        : 否'
	fi
	if [ -n "$WANIP" ] && http_probe; then
		echo '公网探测        : 已认证在线'
	else
		echo '公网探测        : 未认证或网络不可用'
	fi
	echo "自动认证开关    : $ENABLED"
	if [ -n "$CARDID" ] && [ -n "$PASSWORD" ]; then
		echo '账号配置        : 已设置（内容不显示）'
	else
		echo '账号配置        : 未设置'
	fi
	echo "检测间隔        : ${NET_CHECK}s；失败重试 ${RETRY_INTERVAL}s，最多 ${RETRY_MAX} 次"
}

status_main() {
	if [ -f "$STATUS_FILE" ]; then
		cat "$STATUS_FILE"
		return 0
	fi
	_pid=$(cat "$STATE_DIR/daemon.pid" 2>/dev/null)
	case "$_pid" in ''|*[!0-9]*) _pid=0 ;; esac
	_dr=0
	[ "$_pid" -gt 0 ] && kill -0 "$_pid" 2>/dev/null && _dr=1
	printf '{"ts":%s,"time":"%s","state":"stopped","detail":"守护进程尚未写入状态","color":"grey","enabled":0,"configured":0,"campus":0,"portal":0,"online":0,"wan_interface":"","wan_ip":"","net_check":0,"retry_interval":0,"retry_max":0,"last_check":0,"last_login":0,"last_login_result":"","login_kind":"","fail_count":0,"next_retry":0,"daemon_pid":%s,"daemon_running":%s,"interval":0,"portal_url":""}\n' \
		"$(date +%s)" "$(date '+%Y-%m-%d %H:%M:%S')" "$_pid" "$_dr"
}

tail_main() {
	cfg
	_n=${1:-50}
	case "$_n" in ''|*[!0-9]*) _n=50 ;; esac
	[ "$_n" -gt 500 ] && _n=500
	if [ "$PERSIST_LOG_ON" = "1" ] && [ -f "$PERSIST_LOG" ]; then
		echo "----- 持久日志：$PERSIST_LOG -----"
		tail -n "$_n" "$PERSIST_LOG"
		echo '----- 系统日志 -----'
	fi
	logread -e "$TAG" 2>/dev/null | tail -n "$_n"
}

trigger_main() {
	_what=${1:-check}
	mkdir -p "$STATE_DIR"
	_pid=$(cat "$STATE_DIR/daemon.pid" 2>/dev/null)
	case "$_pid" in ''|*[!0-9]*) _pid=0 ;; esac
	if [ "$_pid" -eq 0 ] || ! kill -0 "$_pid" 2>/dev/null; then
		echo '常驻服务未运行'
		return 1
	fi
	case "$_what" in
		login)
			printf '%s' 0 > "$LOGIN_TS_FILE"
			reset_fail
			printf '%s' login > "$WAKE_FILE"
			echo '已触发立即登录'
			;;
		check|*)
			printf '%s' check > "$WAKE_FILE"
			echo '已触发立即检测'
			;;
	esac
}

mkdir -p "$STATE_DIR"
case "$1" in
	--daemon)      daemon_main ;;
	--once)        once_main ;;
	--login)       login_main ;;
	--check)       check_main ;;
	--status)      status_main ;;
	--tail)        shift; tail_main "$1" ;;
	--trigger)     shift; trigger_main "$1" ;;
	--help|-h|'')
		echo "Usage: $0 --daemon|--once|--login|--check|--status|--tail [N]|--trigger check|login"
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
esac
