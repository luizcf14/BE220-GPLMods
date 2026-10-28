'use strict';
// Portal Captivo 3000 — LuCI View: Sessões Ativas
// /htdocs/luci-static/resources/view/captiveportal/sessions.js

'require view';
'require poll';
'require fs';
'require ui';
'require rpc';

var callKick = rpc.declare({
	object: 'service',
	method: 'call',
	params: [ 'name', 'action', 'args' ]
});

return view.extend({
	load: function() {
		return this.loadSessions();
	},

	loadSessions: function() {
		return Promise.all([
			fs.read('/tmp/captiveportal_sessions.json').then(function(data) {
				try {
					return JSON.parse(data || '{"sessions":[]}');
				} catch(e) {
					return { sessions: [] };
				}
			}).catch(function() {
				return { sessions: [] };
			}),
			fs.exec('/usr/bin/portal_ctl', ['qos-status']).then(function(res) {
				try {
					return JSON.parse(res.stdout || '{}');
				} catch(e) {
					return {};
				}
			}).catch(function() {
				return {};
			})
		]).then(function(res) {
			return {
				sessions: res[0].sessions || [],
				qos: res[1] || {}
			};
		});
	},

	kickClient: function(ip) {
		return fs.exec('/usr/bin/portal_ctl', ['kick', ip]).then(function(res) {
			if (res.code !== 0) throw new Error(res.stderr);
			return res;
		});
	},

	formatExpiry: function(expires) {
		var now = Math.floor(Date.now() / 1000);
		var remain = expires - now;
		if (remain <= 0) return E('span', { 'class': 'badge label-danger' }, 'Expirada');
		var h = Math.floor(remain / 3600);
		var m = Math.floor((remain % 3600) / 60);
		var s = remain % 60;
		var str = h > 0 ? h + 'h ' + m + 'm' : m + 'm ' + s + 's';
		var pct = Math.min(100, Math.floor((remain / 3600) * 100));
		var color = remain < 300 ? '#dc3545' : remain < 900 ? '#fd7e14' : '#28a745';
		return E('span', { 'style': 'color:' + color + '; font-weight: bold;' }, str);
	},

	renderSessions: function(data) {
		var sessions = (data && data.sessions) ? data.sessions : [];
		var qos = (data && data.qos) ? data.qos : {};

		var qosAlert = null;
		if (qos.qos_enabled && qos.dropped > 0) {
			qosAlert = E('div', {
				'class': 'alert-message danger',
				'style': 'margin-bottom: 1rem; border-left: 5px solid #dc3545; background-color: #fff3f3;'
			}, [
				E('h4', { 'style': 'margin: 0 0 0.5rem 0; color: #721c24;' }, _('⚠️ ALERTA DE SOBRECARGA NO ROTEADOR (QoS Packet Drops)')),
				E('p', { 'style': 'margin: 0; color: #721c24;' }, [
					_('O controle de banda descartou '),
					E('strong', { 'style': 'font-size: 1.1em; color: #dc3545;' }, qos.dropped + _(' pacotes')),
					_(' devido a sobrecarga na capacidade da CPU do roteador.')
				]),
				E('p', { 'style': 'margin: 0.5rem 0 0 0; font-size: 0.9em; color: #721c24;' }, [
					_('Dica: Você pode desativar o QoS na guia '),
					E('a', { 'href': L.url('admin/services/captiveportal/config'), 'style': 'font-weight: bold; text-decoration: underline;' }, _('Configurações Globais')),
					_(' para liberar a CPU do roteador.')
				])
			]);
		}

		var header = E('div', { 'class': 'cbi-section' }, [
			E('div', { 'class': 'cbi-section-descr' }, [
				E('strong', {}, sessions.length + _(' sessão(ões) ativa(s)')),
				' — ',
				E('small', {}, _('Atualiza automaticamente a cada 10 segundos')),
				qos.qos_enabled ? E('span', { 'class': 'badge', 'style': 'margin-left: 10px; background: #28a745; color: white;' }, 'QoS Ativo') :
					E('span', { 'class': 'badge', 'style': 'margin-left: 10px; background: #6c757d; color: white;' }, 'QoS Desativado')
			])
		]);

		if (sessions.length === 0) {
			return E('div', {}, [
				qosAlert,
				header,
				E('div', { 'class': 'alert-message notice', 'style': 'margin-top: 1rem' }, [
					E('p', {}, _('Nenhum cliente autenticado no momento.'))
				])
			]);
		}

		var now = Math.floor(Date.now() / 1000);

		var rows = sessions
			.filter(function(s) { return s.expires > now - 60; }) // mostra por até 1min após expirar
			.map(function(s) {
				var isExpired = s.expires <= now;
				return E('tr', { 'class': isExpired ? 'cbi-rowstyle-2' : 'cbi-rowstyle-1' }, [
					E('td', {}, s.mac || '—'),
					E('td', {}, s.ip || '—'),
					E('td', {}, s.user || s.email || '—'),
					E('td', {}, s.email || '—'),
					E('td', {}, E('span', {
						'class': 'badge',
						'style': 'background: var(--color-primary, #3c8dbc); color: white; padding: 2px 8px; border-radius: 3px;'
					}, s.profile || '—')),
					E('td', {}, isExpired ?
						E('span', { 'class': 'label-danger' }, _('Expirada')) :
						this.formatExpiry(s.expires)),
					E('td', {}, E('button', {
						'class': 'btn cbi-button cbi-button-remove btn-xs',
						'click': ui.createHandlerFn(this, function(ip) {
							if (!confirm(_('Desconectar ') + ip + '?')) return;
							return this.kickClient(ip).then(function() {
								return this.loadSessions().then(function(data) {
									var container = document.querySelector('#captive-sessions-container');
									if (container) {
										var newContent = this.renderSessions(data);
										container.replaceWith(newContent);
										newContent.id = 'captive-sessions-container';
									}
									ui.addNotification(null,
										E('p', _('Cliente ') + ip + _(' desconectado.')), 'info');
								}.bind(this));
							}.bind(this)).catch(function(err) {
								ui.addNotification(null,
									E('p', _('Erro ao desconectar: ') + err), 'danger');
							});
						}, this, s.ip),
						'disabled': isExpired || null
					}, _('Desconectar'))
					)
				]);
			}, this);

		var table = E('div', { 'class': 'table-responsive', 'style': 'margin-top: 1rem;' }, [
			E('table', { 'class': 'table cbi-section-table' }, [
				E('thead', {}, [
					E('tr', {}, [
						E('th', {}, 'MAC'),
						E('th', {}, 'IP'),
						E('th', {}, _('Usuário')),
						E('th', {}, 'E-mail'),
						E('th', {}, _('Perfil')),
						E('th', {}, _('Expira em')),
						E('th', {}, _('Ação'))
					])
				]),
				E('tbody', {}, rows)
			])
		]);

		// Botão Desconectar Todos
		var flushBtn = E('button', {
			'class': 'btn cbi-button cbi-button-remove',
			'style': 'margin-top: 0.5rem',
			'click': ui.createHandlerFn(this, function() {
				if (!confirm(_('Desconectar TODOS os clientes?'))) return;
				return fs.exec('/usr/bin/portal_ctl', ['flush']).then(function() {
					return this.loadSessions().then(function(data) {
						var container = document.querySelector('#captive-sessions-container');
						if (container) {
							var newContent = this.renderSessions(data);
							container.replaceWith(newContent);
							newContent.id = 'captive-sessions-container';
						}
						ui.addNotification(null, E('p', _('Todos os clientes desconectados.')), 'info');
					}.bind(this));
				}.bind(this));
			}, this)
		}, _('⚠ Desconectar Todos'));

		return E('div', {}, [ qosAlert, header, table, flushBtn ].filter(Boolean));
	},

	render: function(data) {
		var self = this;

		var container = this.renderSessions(data);
		container.id = 'captive-sessions-container';

		// Auto-refresh a cada 10 segundos
		poll.add(function() {
			return self.loadSessions().then(function(newData) {
				var old = document.querySelector('#captive-sessions-container');
				if (old) {
					var newEl = self.renderSessions(newData);
					newEl.id = 'captive-sessions-container';
					old.replaceWith(newEl);
				}
			});
		}, 10);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Sessões Ativas — Portal Captivo 3000')),
			container
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
