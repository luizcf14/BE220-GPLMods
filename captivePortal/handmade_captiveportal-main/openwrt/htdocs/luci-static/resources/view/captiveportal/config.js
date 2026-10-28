'use strict';
// Portal Captivo 3000 — LuCI View: Configuração Global
// /htdocs/luci-static/resources/view/captiveportal/config.js

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

		m = new form.Map('captiveportal', _('Portal Captivo 3000'), _(
			'Configure os parâmetros globais e os perfis de velocidade por usuário. ' +
			'As alterações só entram em vigor após clicar em <strong>Salvar &amp; Aplicar</strong> ou no botão de reiniciar abaixo.'
		));

		// ----------------------------------------------------------------
		// Seção: Configuração Global
		// ----------------------------------------------------------------
		s = m.section(form.NamedSection, 'global', 'captiveportal', _('Configuração Global'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.Flag, 'enable_qos', _('Habilitar Controle de Banda (QoS / tc)'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('Ativa ou desativa o limite de velocidade por perfil no roteador. Desativar o QoS economiza processamento da CPU.');

		o = s.option(form.Value, 'api_url', _('URL do Backend Laravel'));
		o.placeholder = 'https://apidev.conexaopovosdafloresta.org.br';
		o.datatype = 'string';
		o.rmempty = false;

		o = s.option(form.Value, 'api_user_path', _('Endpoint de Validação do Token'));
		o.placeholder = '/api/user/me';
		o.description = _('Endpoint GET que valida o Sanctum token. Retorna user.role.name.');

		o = s.option(form.Value, 'session_time', _('Duração da Sessão (segundos)'));
		o.placeholder = '3600';
		o.datatype = 'uinteger';
		o.description = _('Após este tempo, o cliente é desconectado automaticamente. Ex: 3600 = 1h, 86400 = 24h');

		o = s.option(form.Value, 'wan_interface', _('Interface WAN'));
		o.placeholder = 'eth0';
		o.description = _('Interface física da WAN (ex: eth0, eth0.2, wan). Se a interface configurada não existir, o sistema auto-detecta a WAN ativa.');

		o = s.option(form.Value, 'lan_interface', _('Interface LAN'));
		o.placeholder = 'br-lan';

		o = s.option(form.Value, 'router_ip', _('IP do Roteador'));
		o.placeholder = '192.168.1.1';
		o.description = _('Sempre liberado antes do login (walled garden implícito).');

		o = s.option(form.Value, 'router_domain', _('Domínio Local do Roteador'));
		o.placeholder = 'roteador.conexaopovosdafloresta.org.br';
		o.description = _('Nome de domínio para o portal captivo e prevenção de erros CORS.');

		// ----------------------------------------------------------------
		// Seção: Perfis de Velocidade
		// ----------------------------------------------------------------
		s = m.section(form.GridSection, 'profile', _('Perfis de Velocidade'),
			_('Cada perfil corresponde a um valor de <code>user.role.name</code> retornado pelo backend. ' +
			  'O <strong>fwmark</strong> deve ser único e não deve ser alterado após a criação.')
		);
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescription = true;

		o = s.option(form.Value, 'name', _('Nome do Perfil (role)'));
		o.rmempty = false;
		o.placeholder = 'Visitante';

		o = s.option(form.Value, 'fwmark', _('fwmark'));
		o.datatype = 'range(1, 255)';
		o.rmempty = false;
		o.width = '80px';

		o = s.option(form.Value, 'dl_kbit', _('Download (Kbps)'));
		o.datatype = 'uinteger';
		o.placeholder = '5120';
		o.description = _('0 = ilimitado');

		o = s.option(form.Value, 'ul_kbit', _('Upload (Kbps)'));
		o.datatype = 'uinteger';
		o.placeholder = '2048';
		o.description = _('0 = ilimitado');

		// ----------------------------------------------------------------
		// Botão de Salvar & Aplicar
		// ----------------------------------------------------------------
		return m.render().then(function(node) {
			var applyBtn = E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'style': 'margin-top: 1rem',
				'click': ui.createHandlerFn(this, function() {
					return m.save().then(function() {
						return fs.exec('/usr/bin/portal_ctl', ['restart']).catch(function() {
							return fs.exec('/etc/init.d/captiveportal', ['restart']);
						});
					}).then(function() {
						ui.addNotification(null, E('p', _('Configuração salva e serviço captiveportal reiniciado com sucesso!')), 'info');
					}).catch(function(err) {
						ui.addNotification(null, E('p', _('Erro ao reiniciar o serviço: ') + err), 'danger');
					});
				}, this)
			}, _('Salvar & Reiniciar Portal'));

			var actions = node.querySelector('.cbi-page-actions');
			if (actions) {
				actions.appendChild(applyBtn);
			} else {
				node.appendChild(applyBtn);
			}

			return node;
		}.bind(this));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
