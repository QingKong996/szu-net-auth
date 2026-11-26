'use strict';
'require form';
'require view';
'require uci';

var CONF = 'szu-netauth';

return view.extend({
	load: function() {
		return uci.load(CONF);
	},

	render: function() {
		var m, s, o;

		m = new form.Map(CONF, _('校园网认证'),
			_('适用于深圳大学宿舍区有线 DrCOM 门户。路由器在 WAN 上使用一个账号认证，LAN 设备通过 NAT 共享这条已认证连接。'));

		s = m.section(form.NamedSection, 'global', CONF, _('账号与 WAN'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用自动认证'),
			_('关闭后守护进程仍可运行，但只显示状态，不提交登录。'));
		o.rmempty = false;

		o = s.option(form.Value, 'cardid', _('校园网卡号'),
			_('填写校园网认证卡号，不要填写学号。真实凭据只保存在路由器的 /etc/config/szu-netauth，文件权限为 0600。'));
		o.datatype = 'string';
		o.rmempty = false;
		o.placeholder = _('校园网卡号');

		o = s.option(form.Value, 'password', _('校园网密码'),
			_('门户使用明文 HTTP 传输认证参数；请勿复用其他重要账号的密码。'));
		o.datatype = 'string';
		o.password = true;
		o.rmempty = false;

		o = s.option(form.Value, 'wan_interface', _('WAN 逻辑接口'),
			_('默认使用 OpenWrt 网络配置中的 wan。认证和公网探测都绑定此接口获取的 IPv4 地址。'));
		o.datatype = 'string';
		o.rmempty = false;
		o.placeholder = 'wan';

		s = m.section(form.NamedSection, 'global', CONF, _('复检与重试'));
		s.anonymous = true;

		o = s.option(form.Value, 'net_check', _('在线复检间隔'),
			_('秒。默认 300 秒。每隔这段时间从 WAN 检查一次公网是否仍可用。'));
		o.datatype = 'range(60,86400)';
		o.rmempty = false;
		o.placeholder = 300;

		o = s.option(form.Value, 'retry_interval', _('失败重试间隔'),
			_('秒。默认 60 秒。检测到未认证后，每次登录之间的等待时间。'));
		o.datatype = 'range(15,3600)';
		o.rmempty = false;
		o.placeholder = 60;

		o = s.option(form.Value, 'retry_max', _('单轮最多尝试次数'),
			_('默认 5 次。连续失败达到上限后停止本轮重试，等待下一次在线复检。'));
		o.datatype = 'range(1,20)';
		o.rmempty = false;
		o.placeholder = 5;

		o = s.option(form.Value, 'login_min_interval', _('登录提交最小间隔'),
			_('秒。默认 30 秒。防止手动重复点击或 WAN 事件连续触发登录请求。'));
		o.datatype = 'range(10,3600)';
		o.rmempty = false;
		o.placeholder = 30;

		s = m.section(form.NamedSection, 'global', CONF, _('日志'));
		s.anonymous = true;

		o = s.option(form.Flag, 'persist_log', _('把状态变化写入 flash'),
			_('默认关闭。关闭时日志进入 logd 内存缓冲区；开启后写入 /etc/szu-netauth/state.log。'));
		o.rmempty = false;

		return m.render();
	}
});
