'use strict';
'require view';
'require poll';
'require fs';
'require ui';
'require rpc';

var AUTH = '/etc/szu-netauth/auth.sh';
var SVC = 'szu-netauth';

var callRcList = rpc.declare({
	object: 'rc', method: 'list', expect: { '': {} }
});

var callRcInit = rpc.declare({
	object: 'rc', method: 'init', params: [ 'name', 'action' ], expect: { result: false }
});

var STATE_LABEL = {
	online: '在线（已认证）',
	offline: '离线，正在认证',
	fail: '登录失败，等待重试',
	giveup: '本轮重试已结束',
	waiting: '等待 WAN 地址',
	upstream: '认证入口或上游不可达',
	disabled: '自动认证已停用',
	unconfigured: '尚未配置账号',
	stopped: '服务未运行'
};

var COLOR_HEX = {
	green: '#2e7d32',
	orange: '#ef6c00',
	red: '#c62828',
	grey: '#757575'
};

function pad2(n) {
	return (n < 10 ? '0' : '') + n;
}

function fmtTs(ts) {
	ts = +ts;
	if (!ts || ts <= 0)
		return '—';
	var d = new Date(ts * 1000);
	return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) +
		' ' + pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

function fmtDur(sec) {
	sec = +sec;
	if (!sec || sec <= 0)
		return '—';
	if (sec % 3600 === 0)
		return (sec / 3600) + ' 小时';
	if (sec % 60 === 0)
		return (sec / 60) + ' 分钟';
	return sec + ' 秒';
}

function delay(ms) {
	return new Promise(function(resolve) {
		window.setTimeout(resolve, ms);
	});
}

function byId(id) {
	return document.getElementById(id);
}

function setText(id, value) {
	var node = byId(id);
	if (node)
		node.textContent = (value == null || value === '') ? '—' : String(value);
}

function notify(message, level) {
	ui.addNotification(null, E('p', {}, message), level || 'info');
}

function valueRow(title, node) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, node)
	]);
}

function button(label, handler, className) {
	return E('button', {
		'class': 'btn cbi-button ' + (className || 'cbi-button-neutral'),
		'style': 'margin:0 6px 6px 0',
		'click': function(ev) {
			if (ev)
				ev.preventDefault();
			return handler();
		}
	}, [ label ]);
}

function readStatus() {
	return fs.exec(AUTH, [ '--status' ]).then(function(res) {
		var output = res && res.stdout ? res.stdout.trim() : '';
		if (!output)
			return null;
		try {
			return JSON.parse(output);
		}
		catch (e) {
			return null;
		}
	});
}

function readLog() {
	return fs.exec(AUTH, [ '--tail', '50' ]).then(function(res) {
		return res && res.stdout ? res.stdout.replace(/\s+$/, '') : '';
	});
}

function readService() {
	return callRcList().then(function(res) {
		var rc = res && res[SVC] ? res[SVC] : {};
		return {
			running: typeof rc.running === 'boolean' ? rc.running : null,
			enabled: typeof rc.enabled === 'boolean' ? rc.enabled : null
		};
	}).catch(function() {
		return { running: null, enabled: null };
	});
}

function paint(status, log, service) {
	status = status || {};
	service = service || {};

	var badge = byId('szu-badge');
	if (badge) {
		badge.textContent = STATE_LABEL[status.state] || status.state || '未知';
		badge.style.cssText = 'display:inline-block;padding:2px 10px;border-radius:10px;' +
			'color:#fff;font-weight:bold;background:' +
			(COLOR_HEX[status.color] || COLOR_HEX.grey);
	}

	setText('szu-detail', status.detail);
	setText('szu-check', fmtTs(status.ts));
	setText('szu-wan-iface', status.wan_interface);
	setText('szu-wan-ip', status.wan_ip);
	setText('szu-portal', status.portal ? '可达' : '不可达');
	setText('szu-configured', status.configured ? '已设置' : '未设置，请前往「设置」');
	setText('szu-online', status.online ? '是（公网探测通过）' : '否');
	setText('szu-last-login',
		(status.last_login ? fmtTs(status.last_login) : '尚无登录记录') +
		(status.last_login_result ? '　·　' + status.last_login_result : ''));

	var failures = +status.fail_count || 0;
	var retryMax = +status.retry_max || 0;
	setText('szu-retry', failures > 0
		? failures + '/' + (retryMax || '?') + ' 次失败'
		: '本轮无失败');
	setText('szu-interval', '在线复检 ' + fmtDur(status.net_check) +
		'，失败重试 ' + fmtDur(status.retry_interval));
	setText('szu-portal-url', status.portal_url);

	var running = typeof service.running === 'boolean'
		? service.running : !!status.daemon_running;
	setText('szu-service', running ? '运行中' : '已停止');
	setText('szu-autostart', typeof service.enabled === 'boolean'
		? (service.enabled ? '已启用' : '未启用') : '—');

	var logNode = byId('szu-log');
	if (logNode)
		logNode.textContent = log && log.trim()
			? log
			: '暂无日志。运行日志默认保存在内存缓冲区，不写 flash。';
}

function refresh() {
	return Promise.all([
		readStatus().catch(function() { return null; }),
		readLog().catch(function() { return null; }),
		readService().catch(function() { return {}; })
	]).then(function(results) {
		paint(results[0], results[1], results[2]);
	});
}

function trigger(action) {
	return fs.exec(AUTH, [ '--trigger', action ]).then(function(res) {
		var output = res && res.stdout ? res.stdout.trim() : '';
		var error = res && res.stderr ? res.stderr.trim() : '';
		if (res && res.code === 0)
			notify(output || '已触发');
		else
			notify(error || output || '触发失败', 'warning');
		return delay(2000);
	}).then(refresh).catch(function(err) {
		notify('执行失败：' + (err.message || err), 'error');
	});
}

function runRc(actions) {
	var promise = Promise.resolve();
	actions.forEach(function(action) {
		promise = promise.then(function() {
			return callRcInit(SVC, action);
		});
	});
	return promise.then(function() {
		notify('已执行：' + actions.join(' → '));
		return delay(1000);
	}).then(refresh).catch(function(err) {
		notify('执行失败：' + (err.message || err), 'error');
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			readStatus().catch(function() { return null; }),
			readLog().catch(function() { return null; }),
			readService().catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var container = E('div', {}, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '运行状态'),
				E('div', { 'class': 'cbi-section-node' }, [
					valueRow('总体状态', E('div', {}, [
						E('span', { 'id': 'szu-badge' }, '读取中…'),
						E('div', { 'style': 'margin-top:6px;color:#666' },
							E('span', { 'id': 'szu-detail' }, '—'))
					])),
					valueRow('最近检测', E('span', { 'id': 'szu-check' })),
					valueRow('WAN 接口', E('span', { 'id': 'szu-wan-iface' })),
					valueRow('WAN IPv4', E('span', { 'id': 'szu-wan-ip' })),
					valueRow('认证入口', E('span', { 'id': 'szu-portal' })),
					valueRow('账号配置', E('span', { 'id': 'szu-configured' })),
					valueRow('联网状态', E('span', { 'id': 'szu-online' })),
					valueRow('上次登录', E('span', { 'id': 'szu-last-login' })),
					valueRow('本轮重试', E('span', { 'id': 'szu-retry' })),
					valueRow('运行节奏', E('span', { 'id': 'szu-interval' })),
					valueRow('门户地址', E('span', { 'id': 'szu-portal-url' }))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '服务与自启'),
				E('div', { 'class': 'cbi-section-node' }, [
					valueRow('常驻服务', E('span', { 'id': 'szu-service' })),
					valueRow('开机自启', E('span', { 'id': 'szu-autostart' })),
					valueRow('服务操作', E('div', {}, [
						button('启动服务', function() { return runRc([ 'start' ]); }, 'cbi-button-apply'),
						button('停止服务', function() { return runRc([ 'stop' ]); }),
						button('启用开机自启', function() { return runRc([ 'enable' ]); }),
						button('关闭开机自启', function() { return runRc([ 'disable' ]); })
					]))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '手动操作'),
				E('div', { 'class': 'cbi-section-node' }, [
					valueRow('立即执行', E('div', {}, [
						button('检测连接', function() { return trigger('check'); }, 'cbi-button-action'),
						button('重新认证', function() { return trigger('login'); }, 'cbi-button-action'),
						button('刷新状态', refresh)
					])),
					valueRow('', E('div', { 'style': 'color:#666' },
						'「重新认证」会立即从 WAN 提交一次登录；请勿连续点击，避免触发门户限流。'))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '运行日志（最近 50 行）'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('pre', {
						'id': 'szu-log',
						'style': 'max-height:340px;overflow:auto;white-space:pre-wrap;word-break:break-all;' +
							'font-size:12px;line-height:1.45;margin:0;padding:8px;' +
							'background:rgba(127,127,127,.08);border-radius:4px'
					}, '加载中…'),
					E('div', { 'style': 'margin-top:8px;color:#666' },
						'日志不会显示校园网卡号或密码。')
				])
			])
		]);

		paint(data[0], data[1], data[2]);
		poll.add(refresh, 5);
		return container;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
