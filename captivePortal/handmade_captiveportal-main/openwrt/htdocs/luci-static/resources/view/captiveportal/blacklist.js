'use strict';
// Portal Captivo 3000 — LuCI View: Blacklist DNS
// /htdocs/luci-static/resources/view/captiveportal/blacklist.js

'require view';
'require form';
'require uci';
'require ui';
'require fs';

return view.extend({
	load: function() {
		return uci.load('captiveportal');
	},

	handleSaveApply: function(ev, mode) {
		return this.super('handleSaveApply', [ev, mode]).then(function() {
			return fs.exec('/usr/bin/portal_ctl', ['restart']).catch(function() {
				return fs.exec('/etc/init.d/captiveportal', ['restart']);
			});
		});
	},

	render: function() {
		var m, s, o;

		m = new form.Map('captiveportal', _('Blacklist DNS — Bloqueio de Conteúdo Indesejado'), _(
			'Bloqueie domínios indesejados (conteúdo adulto, apostas, malware). ' +
			'Ao tentar acessar um site bloqueado por DNS, o usuário será redirecionado para a página de aviso informando para contatar o facilitador.'
		));

		// ----------------------------------------------------------------
		// Seção 1: Configuração e Download de Lista da Comunidade
		// ----------------------------------------------------------------
		s = m.section(form.NamedSection, 'blacklist', 'captiveportal', _('Configuração da Blacklist'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Ativar Blacklist por DNS'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Habilita o filtro DNS de domínios indesejados no roteador.');

		o = s.option(form.Value, 'community_url', _('URL da Lista da Comunidade (Hosts)'));
		o.placeholder = 'https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn/hosts';
		o.description = _('URL de lista em formato hosts/dnsmasq para baixar automaticamente. Padrão: StevenBlack Porn/Adult Blocklist.');

		// ----------------------------------------------------------------
		// Seção 2: Domínios Bloqueados Manuais
		// ----------------------------------------------------------------
		s = m.section(form.TableSection, 'blacklist', _('Domínios Bloqueados Manualmente'), _(
			'Adicione domínios específicos para bloquear. Ex: <code>siteindesejado.com</code>, <code>jogos-bet.com</code>.'
		));
		s.addremove = true;
		s.anonymous = true;

		o = s.option(form.DynamicList, 'domain', _('Domínio Bloqueado'));
		o.datatype = 'hostname';
		o.placeholder = 'exemplo-bloqueado.com';

		return m.render().then(function(node) {
			var updateBtn = E('button', {
				'class': 'btn cbi-button cbi-button-action',
				'style': 'margin-top: 1rem; margin-right: 0.5rem; background-color: #0284c7; color: white;',
				'click': ui.createHandlerFn(this, function() {
					ui.addNotification(null, E('p', _('Baixando lista de bloqueio da comunidade... Por favor aguarde.')), 'info');
					return fs.exec('/usr/bin/portal_ctl', ['blacklist', 'update-community']).then(function(res) {
						if (res.code === 0) {
							ui.addNotification(null, E('p', _('Lista da comunidade baixada e aplicada com sucesso!\n') + res.stdout), 'info');
						} else {
							ui.addNotification(null, E('p', _('Erro ao baixar lista: ') + (res.stderr || res.stdout)), 'danger');
						}
					}).catch(function(err) {
						ui.addNotification(null, E('p', _('Erro ao executar download: ') + err), 'danger');
					});
				}, this)
			}, _('📥 Baixar / Atualizar Lista da Comunidade Agora'));

			var actions = node.querySelector('.cbi-page-actions');
			if (actions) {
				actions.insertBefore(updateBtn, actions.firstChild);
			} else {
				node.appendChild(updateBtn);
			}

			return node;
		}.bind(this));
	}
});
