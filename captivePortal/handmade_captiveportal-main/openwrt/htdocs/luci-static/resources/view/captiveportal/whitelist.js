'use strict';
// Portal Captivo 3000 — LuCI View: Walled Garden
// /htdocs/luci-static/resources/view/captiveportal/whitelist.js

'require view';
'require form';
'require uci';
'require ui';
'require rpc';

var callServiceReload = rpc.declare({
	object: 'service',
	method: 'reload',
	params: [ 'name' ]
});

return view.extend({
	load: function() {
		return uci.load('captiveportal');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('captiveportal', _('Walled Garden — Domínios Liberados'), _(
			'Domínios acessíveis por clientes <strong>antes</strong> do login. ' +
			'O IP do roteador (<code>192.168.1.1</code>) e o backend de login são sempre liberados implicitamente. ' +
			'Suporte a wildcard: <code>*.exemplo.com</code> libera todos os subdomínios. ' +
			'Ao clicar em <strong>Aplicar</strong>, o dnsmasq é recarregado automaticamente.'
		));

		s = m.section(form.NamedSection, 'walled_garden', 'captiveportal', _('Domínios Permitidos'));
		s.addremove = false;
		s.anonymous = true;

		o = s.option(form.DynamicList, 'domain', _('Domínio'));
		o.placeholder = 'exemplo.com';
		o.datatype = 'string';
		o.description = _(
			'Um domínio por linha. Use <code>*.example.com</code> para wildcard de subdomínios. ' +
			'Exemplos: <code>apidev.conexaopovosdafloresta.org.br</code>, <code>fonts.googleapis.com</code>'
		);

		return m.render().then(function(node) {
			// Adiciona botão "Salvar & Aplicar Walled Garden"
			var applyBtn = E('button', {
				'class': 'btn cbi-button cbi-button-apply',
				'style': 'margin-top: 1rem',
				'click': ui.createHandlerFn(this, function() {
					return m.save().then(function() {
						return callServiceReload('captiveportal');
					}).then(function() {
						ui.addNotification(null,
							E('p', _('Walled Garden atualizado! dnsmasq recarregado.')), 'info');
					}).catch(function(err) {
						ui.addNotification(null,
							E('p', _('Erro ao aplicar: ') + err), 'danger');
					});
				}, this)
			}, _('Salvar & Aplicar Walled Garden'));

			node.querySelector('.cbi-page-actions')?.appendChild(applyBtn) ||
				node.appendChild(applyBtn);

			// Nota informativa sobre como funciona
			var infoBox = E('div', { 'class': 'alert-message info', 'style': 'margin-top: 1.5rem' }, [
				E('h4', {}, _('Como funciona')),
				E('p', {}, _(
					'Quando um cliente resolve um dos domínios listados via DNS, o dnsmasq ' +
					'automaticamente insere os IPs retornados no conjunto <code>captive_whitelist</code> ' +
					'do nftables. O tráfego para esses IPs é liberado antes do login. ' +
					'Funciona com CDNs e servidores com IPs dinâmicos.'
				))
			]);

			node.appendChild(infoBox);
			return node;
		}.bind(this));
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
