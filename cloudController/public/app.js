// Conexão Povos da Floresta — Cloud Controller Frontend (Estilo UniFi)
let ws = null;
let routersMap = new Map();
let pendingMap = new Map();
let termWs = null;
let term = null;
let fitAddon = null;
let activeTermMac = null;

// Conexão WebSocket Principal (Canal de Gestão e Telemetria)
let adminHeartbeatTimer = null;

async function connectAdminWs() {
  // Autenticação: valida a sessão (e renova) antes de abrir o canal; 401 => volta para a tela de login
  try {
    const ok = await refreshSession();
    if (!ok) return;
  } catch (e) {
    setTimeout(connectAdminWs, 2000);
    return;
  }

  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${protocol}//${location.host}/ws/admin`;

  ws = new WebSocket(wsUrl);

  ws.onopen = () => {
    document.getElementById('ws-status-text').textContent = 'Controlador Conectado';
    document.getElementById('ws-badge').style.borderColor = 'rgba(16, 185, 129, 0.3)';

    // Heartbeat bidirecional (15s): Impede que o Google Cloud Run e proxies encerrem a conexão por ociosidade
    if (adminHeartbeatTimer) clearInterval(adminHeartbeatTimer);
    adminHeartbeatTimer = setInterval(() => {
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ action: 'ping' }));
      }
    }, 15000);
  };

  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      handleServerMessage(msg);
    } catch (e) {
      console.error('Erro ao decodificar mensagem do servidor:', e);
    }
  };

  ws.onclose = () => {
    if (adminHeartbeatTimer) {
      clearInterval(adminHeartbeatTimer);
      adminHeartbeatTimer = null;
    }
    document.getElementById('ws-status-text').textContent = 'Reconectando...';
    document.getElementById('ws-badge').style.borderColor = 'rgba(244, 63, 94, 0.3)';
    setTimeout(connectAdminWs, 2000);
  };

  ws.onerror = () => {
    if (adminHeartbeatTimer) {
      clearInterval(adminHeartbeatTimer);
      adminHeartbeatTimer = null;
    }
    ws.close();
  };
}

// Persistência em LocalStorage e Auto-Cura de Adoção (Padrão UniFi)
function getStoredAdoptedMap() {
  try {
    const raw = localStorage.getItem('floresta_adopted_devices');
    return raw ? JSON.parse(raw) : {};
  } catch (e) {
    return {};
  }
}

function saveStoredAdopted(mac, name) {
  if (!mac) return;
  try {
    const map = getStoredAdoptedMap();
    // Não sobrescreve um nome customizado existente com um nome genérico de fábrica
    const existing = map[mac] ? map[mac].name : null;
    const isGeneric = !name || name === 'Archer BE220' || name === 'BE220' || name.startsWith('Archer BE220 - Polo');
    const finalName = (isGeneric && existing && !existing.startsWith('Archer BE220 - Polo')) ? existing : (name || 'Archer BE220');
    map[mac] = { name: finalName, adopted_at: Date.now() };
    localStorage.setItem('floresta_adopted_devices', JSON.stringify(map));
  } catch (e) {}
}

function removeStoredAdopted(mac) {
  if (!mac) return;
  try {
    const map = getStoredAdoptedMap();
    delete map[mac];
    localStorage.setItem('floresta_adopted_devices', JSON.stringify(map));
  } catch (e) {}
}

function isKnownAdopted(mac) {
  if (!mac) return false;
  const map = getStoredAdoptedMap();
  return !!map[mac] || routersMap.has(mac);
}

function handleServerMessage(msg) {
  if (msg.event === 'pong') {
    // Resposta do heartbeat recebida com sucesso
    return;
  }

  if (msg.event === 'forbidden') {
    showToast(msg.error || 'Permissão insuficiente para esta ação.', 'error');
    return;
  }

  if (msg.event === 'init_state') {
    const prevRouters = new Map(routersMap);
    routersMap.clear();
    pendingMap.clear();
    const stored = getStoredAdoptedMap();

    // 1. Catálogo Padrão DNS
    const cachedDef = localStorage.getItem('floresta_default_dns');
    let parsedCachedDef = null;
    try {
      if (cachedDef) parsedCachedDef = JSON.parse(cachedDef);
    } catch (_) {}

    if (msg.default_dns_blocklist && Array.isArray(msg.default_dns_blocklist) && msg.default_dns_blocklist.length > 0) {
      if (Array.isArray(parsedCachedDef) && parsedCachedDef.length > msg.default_dns_blocklist.length) {
        defaultDnsList = Array.from(new Set([...msg.default_dns_blocklist, ...parsedCachedDef]));
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ action: 'save_default_dns_blocklist', domains: defaultDnsList }));
        }
      } else {
        defaultDnsList = msg.default_dns_blocklist;
      }
      try { localStorage.setItem('floresta_default_dns', JSON.stringify(defaultDnsList)); } catch (_) {}
    } else if (Array.isArray(parsedCachedDef) && parsedCachedDef.length > 0) {
      defaultDnsList = parsedCachedDef;
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ action: 'save_default_dns_blocklist', domains: parsedCachedDef }));
      }
    }

    // 2. Processa Roteadores Adotados
    (msg.routers || []).forEach(r => {
      const existing = prevRouters.get(r.mac);

      // Auto-Cura de Nomes Customizados: Se o servidor perdeu o nome após reiniciar
      if (stored[r.mac] && stored[r.mac].name) {
        const savedName = stored[r.mac].name;
        if (savedName !== 'Archer BE220' && savedName !== 'BE220' && !savedName.startsWith('Archer BE220 - Polo')) {
          if (!r.name || r.name === 'Archer BE220' || r.name === 'BE220' || r.name.startsWith('Archer BE220 - Polo')) {
            console.log(`[Auto-Healing] Restaurando nome customizado no servidor: ${r.mac} -> ${savedName}`);
            r.name = savedName;
            if (ws && ws.readyState === WebSocket.OPEN) {
              ws.send(JSON.stringify({ action: 'rename_device', mac: r.mac, name: savedName }));
            }
          }
        }
      }

      // Sincronização de Bloqueio DNS por Roteador (Servidor GCS é a fonte da verdade)
      let blocklist = Array.isArray(r.dns_blocklist) ? r.dns_blocklist : ((existing && existing.dns_blocklist) || []);
      try {
        localStorage.setItem('floresta_dns_' + r.mac, JSON.stringify(blocklist));
      } catch (_) {}
      r.dns_blocklist = blocklist;

      if (!r.telemetry) {
        if (existing && existing.telemetry) {
          r.telemetry = existing.telemetry;
        } else {
          try {
            const cachedTelem = localStorage.getItem('floresta_telem_' + r.mac);
            if (cachedTelem) r.telemetry = JSON.parse(cachedTelem);
          } catch (_) {}
        }
      }
      routersMap.set(r.mac, r);
      saveStoredAdopted(r.mac, r.name);
    });

    (msg.pending || []).forEach(p => {
      // AUTO-HEALING: Se o dispositivo já era adotado (no localStorage ou routersMap),
      // restaura instantaneamente como adotado e auto-cura o servidor Cloud Run
      if (routersMap.has(p.mac) || stored[p.mac]) {
        const savedName = (stored[p.mac] && stored[p.mac].name) || p.name || 'Archer BE220';
        routersMap.set(p.mac, { ...p, name: savedName, adopted: true, online: true });
        saveStoredAdopted(p.mac, savedName);
        if (ws && ws.readyState === WebSocket.OPEN) {
          console.log(`[Auto-Healing] Restaurando dispositivo ${p.mac} na frota...`);
          ws.send(JSON.stringify({
            action: 'adopt_device',
            mac: p.mac,
            name: savedName
          }));
        }
      } else {
        pendingMap.set(p.mac, p);
      }
    });
    renderAll();
  } else if (msg.event === 'router_pending') {
    // Se o dispositivo já está adotado na frota ou no localStorage, NUNCA move para pendente
    if (isKnownAdopted(msg.mac)) {
      const stored = getStoredAdoptedMap();
      const savedName = (stored[msg.mac] && stored[msg.mac].name) || msg.name || 'Archer BE220';
      const existing = routersMap.get(msg.mac) || { mac: msg.mac };
      routersMap.set(msg.mac, { ...existing, mac: msg.mac, name: savedName, online: true, adopted: true });
      pendingMap.delete(msg.mac);
      saveStoredAdopted(msg.mac, savedName);
      if (ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({
          action: 'adopt_device',
          mac: msg.mac,
          name: savedName
        }));
      }
      renderAll();
      return;
    }
    pendingMap.set(msg.mac, {
      mac: msg.mac,
      name: msg.name || 'Archer BE220',
      ip: msg.ip || '192.168.0.1',
      connected_at: msg.connected_at
    });
    renderAll();
  } else if (msg.event === 'router_online') {
    const existing = routersMap.get(msg.mac) || {};
    const stored = getStoredAdoptedMap();
    const finalName = (stored[msg.mac] && stored[msg.mac].name && !stored[msg.mac].name.startsWith('Archer BE220 - Polo')) ? stored[msg.mac].name : (msg.name || existing.name);
    routersMap.set(msg.mac, { ...existing, mac: msg.mac, name: finalName, online: true, connected_at: msg.connected_at });
    pendingMap.delete(msg.mac);
    renderAll();
  } else if (msg.event === 'router_adopted') {
    pendingMap.delete(msg.mac);
    saveStoredAdopted(msg.mac, msg.name);
    const existing = routersMap.get(msg.mac) || {};
    routersMap.set(msg.mac, { ...existing, mac: msg.mac, name: msg.name, online: !!msg.online, adopted: true });
    renderAll();
  } else if (msg.event === 'router_renamed') {
    saveStoredAdopted(msg.mac, msg.name);
    const existing = routersMap.get(msg.mac) || {};
    routersMap.set(msg.mac, { ...existing, mac: msg.mac, name: msg.name });
    renderAll();
  } else if (msg.event === 'router_forgotten') {
    removeStoredAdopted(msg.mac);
    routersMap.delete(msg.mac);
    renderAll();
  } else if (msg.event === 'router_offline') {
    const existing = routersMap.get(msg.mac);
    if (existing) {
      existing.online = false;
      routersMap.set(msg.mac, existing);
      renderAll();
    }
  } else if (msg.event === 'telemetry') {
    // Se o roteador já foi adotado no painel, reporta adopted=true ou está no localStorage
    if (msg.adopted || isKnownAdopted(msg.mac)) {
      pendingMap.delete(msg.mac);
      const existing = routersMap.get(msg.mac) || { mac: msg.mac };
      existing.online = true;
      existing.adopted = true;
      if (msg.name) existing.name = msg.name;
      existing.telemetry = msg.data;
      routersMap.set(msg.mac, existing);
      saveStoredAdopted(msg.mac, existing.name);
      try {
        localStorage.setItem('floresta_telem_' + msg.mac, JSON.stringify(msg.data));
      } catch (_) {}
    } else {
      const pending = pendingMap.get(msg.mac) || { mac: msg.mac };
      if (msg.name) pending.name = msg.name;
      pending.telemetry = msg.data;
      pendingMap.set(msg.mac, pending);
      try {
        localStorage.setItem('floresta_telem_' + msg.mac, JSON.stringify(msg.data));
      } catch (_) {}
    }
    renderAll();
  } else if (msg.event === 'web_tunnel_ready') {
    onTunnelReady(msg.mac, msg.port, msg.url);
  } else if (msg.event === 'web_tunnel_stopped') {
    onTunnelStopped(msg.mac);
  } else if (msg.event === 'web_tunnel_error') {
    onTunnelError(msg.mac, msg.error);
  } else if (msg.event === 'router_dns_blocklist_updated') {
    const existing = routersMap.get(msg.mac);
    if (existing && Array.isArray(msg.domains)) {
      existing.dns_blocklist = msg.domains;
      routersMap.set(msg.mac, existing);
      try { localStorage.setItem('floresta_dns_' + msg.mac, JSON.stringify(msg.domains)); } catch (_) {}
      renderAll();
    }
  } else if (msg.event === 'cmd_result') {
    console.log(`[Cmd Result] ${msg.mac}:`, msg.res);
    const statusBox = document.getElementById('router-dns-status-box');
    if (statusBox && activeRouterDnsMac === msg.mac && msg.res) {
      const ok = msg.res.ok !== false;
      const text = msg.res.message || (ok ? 'Comando aplicado com sucesso no roteador!' : (msg.res.error || 'Falha ao aplicar comando.'));
      statusBox.innerHTML = `
        <div class="dns-alert ${ok ? 'dns-alert-success' : 'dns-alert-error'}" style="background:${ok ? 'rgba(16,185,129,0.12)' : 'rgba(244,63,94,0.12)'}; border:1px solid ${ok ? 'rgba(16,185,129,0.35)' : 'rgba(244,63,94,0.35)'}; color:${ok ? '#34d399' : '#fb7185'}; padding:10px 14px; border-radius:8px; font-size:13px;">
          <span>${ok ? '✅' : '⚠️'} ${text}</span>
        </div>
      `;
      statusBox.style.display = 'block';
    }
  }
}

function renderAll() {
  renderPendingSection();
  renderFleetSection();
}

// ---------------------------------------------------------------------------
// RENDERIZAÇÃO DA SEÇÃO DE ADOÇÃO (ESTILO UNIFI)
// ---------------------------------------------------------------------------
function renderPendingSection() {
  const pendingSection = document.getElementById('pending-adoption-section');
  const pendingList = document.getElementById('pending-list');
  const count = pendingMap.size;

  if (count === 0) {
    pendingSection.style.display = 'none';
    return;
  }

  pendingSection.style.display = 'block';
  document.getElementById('pending-count').textContent = `${count} Aguardando Adoção`;

  let html = '';
  pendingMap.forEach(p => {
    let cleanPendingName = p.name || 'Polo Aldeia Yawanawá';
    try { cleanPendingName = decodeURIComponent(cleanPendingName); } catch (e) { }
    html += `
      <div class="router-card" style="border-color: rgba(245, 158, 11, 0.4); background: rgba(30, 25, 15, 0.6); margin-bottom: 12px;">
        <div class="router-card-header" style="background: rgba(245, 158, 11, 0.08);">
          <div class="router-info">
            <div class="router-icon" style="background: rgba(245, 158, 11, 0.15); border-color: rgba(245, 158, 11, 0.4);">🔔</div>
            <div>
              <div class="router-title" style="display:flex; align-items:center; gap:8px;">
                <span>TP-Link Archer BE220 (BCM6764)</span>
                <span class="badge" style="background:rgba(245,158,11,0.2); color:#fbbf24; border:1px solid #f59e0b50;">
                  ● Aguardando Adoção
                </span>
              </div>
              <div class="router-mac">MAC: <strong>${p.mac}</strong> &nbsp;•&nbsp; IP: ${p.ip || '192.168.0.1'}</div>
            </div>
          </div>
          <div class="router-actions" style="gap:10px;">
            <input type="text" id="name-${p.mac.replace(/[:]/g, '')}" value="${cleanPendingName}" placeholder="Nome da Comunidade..." style="background:#111827; border:1px solid rgba(255,255,255,0.15); color:#fff; border-radius:6px; padding:6px 12px; font-size:13px; width:220px;">
            <button class="btn btn-primary" style="background:linear-gradient(135deg, #f59e0b, #d97706); color:#fff;" onclick="adoptDevice('${p.mac}')">
              ✓ Adotar Roteador na Frota
            </button>
          </div>
        </div>
      </div>
    `;
  });

  pendingList.innerHTML = html;
}

function adoptDevice(mac) {
  const inputId = `name-${mac.replace(/[:]/g, '')}`;
  const inputElem = document.getElementById(inputId);
  const name = inputElem ? inputElem.value.trim() : 'Aldeia / Roteador BE220';

  saveStoredAdopted(mac, name);

  if (!ws || ws.readyState !== WebSocket.OPEN) {
    alert('Erro: Conexão com o servidor Cloud está inativa.');
    return;
  }

  ws.send(JSON.stringify({
    action: 'adopt_device',
    mac: mac,
    name: name
  }));
}

function forgetDevice(mac) {
  if (confirm(`Deseja realmente DESADOTAR / ESQUECER o roteador ${mac}?\nEle voltará para a lista de pendentes até ser readotado.`)) {
    removeStoredAdopted(mac);
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        action: 'forget_device',
        mac: mac
      }));
    }
  }
}

// ---------------------------------------------------------------------------
// RENDERIZAÇÃO DA FROTA ATIVA (ROTEADORES ADOTADOS)
// ---------------------------------------------------------------------------
function renderFleetSection() {
  const container = document.getElementById('routers-list');
  const onlineCount = Array.from(routersMap.values()).filter(r => r.online).length;
  const totalCount = routersMap.size;

  document.getElementById('stat-routers-online').textContent = onlineCount;
  document.getElementById('stat-routers-total').textContent = `${totalCount} roteador(es) na frota`;
  document.getElementById('fleet-count').textContent = `${onlineCount}/${totalCount} Online`;

  let totalUsers = 0;

  if (routersMap.size === 0) {
    container.innerHTML = `
      <div class="empty-state">
        <div class="empty-state-icon">📡</div>
        <h3 style="margin-bottom:6px; color:#f8fafc;">Nenhum Roteador Adotado</h3>
        <p>Dispositivos conectados pela primeira vez aparecem na seção "Aguardando Adoção" acima.</p>
      </div>
    `;
    document.getElementById('stat-users-online').textContent = '0';
    return;
  }

  let html = '';
  routersMap.forEach(r => {
    const t = r.telemetry || {};
    const sessionList = Array.isArray(t.sessions) ? t.sessions : (t.sessions && Array.isArray(t.sessions.sessions) ? t.sessions.sessions : []);
    const clientsCount = Number(t.auth_count) || sessionList.length || 0;
    totalUsers += clientsCount;

    const qosActive = t.qos_enabled !== false;
    const cpuLoad = (t.loadavg && t.loadavg[0] !== undefined) ? t.loadavg[0] : (t.cpu || '—');
    const memFree = t.mem_free_mb ? `${t.mem_free_mb} MB` : '—';
    const wanIp = t.wan_ip || '192.168.0.1';
    const uptime = t.uptime || '—';
    const fwVersion = t.fw_version || '2.6.0-floresta';
    const bootSlot = t.boot_slot ? ` (${t.boot_slot})` : '';
    let cleanName = r.name || 'Aldeia / Roteador BE220';
    try { cleanName = decodeURIComponent(cleanName); } catch (e) { }

    html += `
      <div class="router-card" id="card-${r.mac.replace(/[:]/g, '')}">
        <div class="router-card-header">
          <div class="router-info">
            <div class="router-icon">📡</div>
            <div>
              <div class="router-title">
                ${cleanName}
                <span class="badge ${r.online ? 'online' : 'offline'}" style="margin-left:8px;">
                  ${r.online ? '● Online' : '○ Offline'}
                </span>
                <span class="badge ${qosActive ? 'qos-on' : 'qos-off'}" style="margin-left:4px;">
                  ${qosActive ? '⚡ QoS Ativo' : '⚡ QoS Livre'}
                </span>
                <span class="badge" style="margin-left:4px; background:rgba(56, 189, 248, 0.12); color:#38bdf8; border:1px solid rgba(56, 189, 248, 0.3); font-family:var(--font-mono); font-size:11px;">
                  📦 ${fwVersion}${bootSlot}
                </span>
              </div>
              <div class="router-mac">MAC: ${r.mac} &nbsp;•&nbsp; IP WAN: ${wanIp} &nbsp;•&nbsp; Firmware: <strong style="color:#e2e8f0;">${fwVersion}${bootSlot}</strong> &nbsp;•&nbsp; Modelo: Archer BE220</div>
            </div>
          </div>
          <div class="router-actions">
            <button class="btn btn-terminal" onclick="openTerminal('${r.mac}', '${cleanName}')">
              >_ Terminal Web
            </button>
            <button class="btn" style="background:linear-gradient(135deg, #0284c7, #0369a1); color:#fff; border:none; display:inline-flex; align-items:center; gap:5px;" onclick="openWebTunnelModal('${r.mac}', '${cleanName}')">
              🌐 WebUI Remota
            </button>
            <button class="btn" style="background:linear-gradient(135deg, #7c3aed, #6d28d9); color:#fff; border:none; display:inline-flex; align-items:center; gap:5px;" onclick="openRouterDnsModal('${r.mac}', '${cleanName}')">
              🛡️ Bloqueio DNS (${(r.dns_blocklist || []).length})
            </button>
            <button class="btn" onclick="toggleQoSRemote('${r.mac}', ${qosActive ? 0 : 1})">
              ${qosActive ? '⏹ Desligar QoS' : '⚡ Ligar QoS'}
            </button>
            <button class="btn" onclick="openClientsModal('${r.mac}')">
              👥 Clientes (${clientsCount})
            </button>
            <button class="btn" style="background:rgba(16, 185, 129, 0.15); border:1px solid rgba(16, 185, 129, 0.4); color:#34d399; display:inline-flex; align-items:center; gap:5px;" onclick="openHistoryModal('${r.mac}', '${cleanName}')">
              📊 Histórico
            </button>
            <button class="btn" onclick="forgetDevice('${r.mac}')" title="Esquecer Dispositivo">
              ✕ Desadotar
            </button>
            <button class="btn btn-danger" onclick="rebootRemote('${r.mac}')">
              🔄 Reiniciar
            </button>
          </div>
        </div>
        <div class="router-body">
          <div class="metric-item">
            <div class="metric-title">Clientes Online</div>
            <div class="metric-value" style="color:var(--accent-emerald); font-size:18px;">
              ${clientsCount} dispositivos
            </div>
          </div>
          <div class="metric-item">
            <div class="metric-title">Bloqueio DNS</div>
            <div class="metric-value" style="color:#c4b5fd; font-size:18px;">
              ${(r.dns_blocklist || []).length} URLs
            </div>
          </div>
          <div class="metric-item">
            <div class="metric-title">Carga da CPU</div>
            <div class="metric-value">${cpuLoad}</div>
          </div>
          <div class="metric-item">
            <div class="metric-title">Memória RAM Livre</div>
            <div class="metric-value">${memFree}</div>
          </div>
          <div class="metric-item">
            <div class="metric-title">Tempo de Atividade</div>
            <div class="metric-value">${uptime}</div>
          </div>
          <div class="metric-item">
            <div class="metric-title">Versão do Firmware</div>
            <div class="metric-value" style="color:#38bdf8; font-size:14px; font-family:var(--font-mono);">${fwVersion}${bootSlot}</div>
          </div>
        </div>
      </div>
    `;
  });

  container.innerHTML = html;
  document.getElementById('stat-users-online').textContent = totalUsers;
}

// ---------------------------------------------------------------------------
// AÇÕES REMOTAS
// ---------------------------------------------------------------------------
function sendCommand(mac, action, params = {}) {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    alert('Erro: Conexão com o servidor Cloud está inativa.');
    return;
  }
  ws.send(JSON.stringify({
    mac: mac,
    action: action,
    params: params
  }));
}

function toggleQoSRemote(mac, state) {
  sendCommand(mac, 'qos_toggle', { enabled: state });
}

function rebootRemote(mac) {
  if (confirm(`Deseja realmente REINICIAR o roteador ${mac} remotamente?`)) {
    sendCommand(mac, 'reboot');
  }
}

function openClientsModal(mac) {
  const router = routersMap.get(mac);
  if (!router) return;

  const t = router.telemetry || {};
  const sessions = Array.isArray(t.sessions) ? t.sessions : (t.sessions && Array.isArray(t.sessions.sessions) ? t.sessions.sessions : []);

  document.getElementById('clients-router-name').textContent = `${router.name || 'Roteador'} (${mac})`;
  const container = document.getElementById('clients-table-container');

  if (sessions.length === 0) {
    container.innerHTML = '<p style="color:var(--text-muted); text-align:center; padding:20px;">Nenhum cliente conectado no momento.</p>';
  } else {
    let tableHtml = `
      <table style="width:100%; text-align:left; border-collapse:collapse; font-size:13px;">
        <thead>
          <tr style="border-bottom:1px solid var(--border-color); color:var(--text-muted);">
            <th style="padding:8px;">IP / MAC</th>
            <th style="padding:8px;">Usuário</th>
            <th style="padding:8px;">Perfil</th>
            <th style="padding:8px; text-align:right;">Ação</th>
          </tr>
        </thead>
        <tbody>
    `;
    sessions.forEach(s => {
      tableHtml += `
        <tr style="border-bottom:1px solid var(--border-color);">
          <td style="padding:8px;"><strong>${s.ip}</strong><br><span style="font-family:var(--font-mono); font-size:11px; color:var(--text-muted);">${s.mac || '—'}</span></td>
          <td style="padding:8px;">${s.user || s.email || 'Visitante'}</td>
          <td style="padding:8px;"><span class="badge online">${s.profile || 'Visitante'}</span></td>
          <td style="padding:8px; text-align:right;">
            <button class="btn btn-danger" style="padding:4px 8px; font-size:11px;" onclick="kickClientRemote('${mac}', '${s.ip}')">Desconectar</button>
          </td>
        </tr>
      `;
    });
    tableHtml += '</tbody></table>';
    container.innerHTML = tableHtml;
  }

  document.getElementById('modal-clients').classList.add('open');
}

function closeClientsModal() {
  document.getElementById('modal-clients').classList.remove('open');
}

function kickClientRemote(mac, ip) {
  if (confirm(`Desconectar cliente ${ip} remotamente?`)) {
    sendCommand(mac, 'kick', { ip: ip });
    setTimeout(() => openClientsModal(mac), 1000);
  }
}

// ---------------------------------------------------------------------------
// TERMINAL WEB INTERATIVO (Web SSH)
// ---------------------------------------------------------------------------
function openTerminal(mac, name) {
  let cleanName = name || 'Archer BE220';
  try { cleanName = decodeURIComponent(cleanName); } catch (e) { }
  activeTermMac = mac;
  cancelFileUpload(false);
  document.getElementById('term-device-name').textContent = `root@${mac} (${cleanName})`;
  document.getElementById('modal-terminal').classList.add('open');

  const termElem = document.getElementById('terminal-view');
  termElem.innerHTML = '';

  // Configura suporte a arrastar e soltar arquivos sobre o terminal
  termElem.ondragover = (e) => {
    e.preventDefault();
    termElem.classList.add('drag-over');
  };
  termElem.ondragleave = (e) => {
    e.preventDefault();
    termElem.classList.remove('drag-over');
  };
  termElem.ondrop = (e) => {
    e.preventDefault();
    termElem.classList.remove('drag-over');
    if (e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files.length > 0) {
      startFileUpload(e.dataTransfer.files[0]);
    }
  };

  const TermClass = window.Terminal;

  if (TermClass) {
    if (term) term.dispose();

    term = new TermClass({
      cursorBlink: true,
      convertEol: true,
      fontFamily: 'JetBrains Mono, monospace',
      fontSize: 14,
      theme: {
        background: '#0a0d14',
        foreground: '#f8fafc',
        cursor: '#00d2ff'
      }
    });

    if (window.FitAddon && window.FitAddon.FitAddon) {
      fitAddon = new window.FitAddon.FitAddon();
      term.loadAddon(fitAddon);
    }

    term.open(termElem);
    if (fitAddon) fitAddon.fit();

    term.writeln('\x1b[1;36mConectando ao Console Remoto do Archer BE220...\x1b[0m\r\n');

    term.attachCustomKeyEventHandler((e) => {
      if (e.type !== 'keydown') return true;

      if (e.ctrlKey) {
        const k = e.key.toLowerCase();
        if (k === 'c') {
          if (term.hasSelection()) return true; // Permite copiar texto selecionado
          e.preventDefault();
          e.stopPropagation();
          sendTerminalKey('^C');
          return false;
        } else if (k === 'd') {
          e.preventDefault();
          e.stopPropagation();
          sendTerminalKey('^D');
          return false;
        } else if (k === 'a') {
          e.preventDefault();
          e.stopPropagation();
          sendTerminalKey('^A');
          return false;
        } else if (k === 'w') {
          e.preventDefault();
          e.stopPropagation();
          sendTerminalKey('^W');
          return false;
        } else if (k === 'l') {
          e.preventDefault();
          e.stopPropagation();
          sendTerminalKey('^L');
          return false;
        } else if (k === 'u') {
          e.preventDefault();
          e.stopPropagation();
          sendTerminalKey('^U');
          return false;
        } else if (k === 'z') {
          e.preventDefault();
          e.stopPropagation();
          sendTerminalRaw('\x1a');
          return false;
        }
      }

      if (e.key === 'Tab') {
        e.preventDefault();
        e.stopPropagation();
        sendTerminalKey('TAB');
        return false;
      }

      return true;
    });

    term.onData((data) => {
      if (termWs && termWs.readyState === WebSocket.OPEN) {
        if (data === '\r') {
          term.write('\r\n');
          termWs.send('\n');
        } else if (data === '\x7f' || data === '\b') {
          term.write('\b \b');
          termWs.send('\b');
        } else {
          term.write(data);
          termWs.send(data);
        }
      }
    });
  } else {
    // Fallback: Console HTML caso a biblioteca xterm não tenha sido carregada
    termElem.innerHTML = `
      <pre id="fallback-term-output" style="color:#f8fafc; font-family:var(--font-mono); font-size:13px; height:100%; overflow-y:auto; white-space:pre-wrap;">Conectando ao Console Remoto do Archer BE220...\n</pre>
    `;
  }

  const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const termUrl = `${protocol}//${location.host}/ws/terminal?mac=${encodeURIComponent(mac)}`;

  if (termWs) {
    termWs.close();
  }

  termWs = new WebSocket(termUrl);
  // Receber frames binários como ArrayBuffer (bytes PTY raw do roteador)
  termWs.binaryType = 'arraybuffer';

  termWs.onopen = () => {
    appendTerminalOutput('\x1b[1;32m[OK] Sessao de Terminal PTY (/bin/ash) Estabelecida!\x1b[0m\r\n');
  };

  termWs.onmessage = (e) => {
    if (e.data instanceof ArrayBuffer) {
      // Frame binário: bytes PTY raw → Uint8Array para o xterm.js
      const bytes = new Uint8Array(e.data);
      if (term) {
        term.write(bytes);
      } else {
        // Fallback: decodificar como texto
        const text = new TextDecoder().decode(bytes);
        appendTerminalOutput(text);
      }
    } else {
      // Frame texto: verifica se é mensagem de controle de upload ou eco de terminal
      try {
        const msg = JSON.parse(e.data);
        if (msg && msg.type && handleFileUploadMessage(msg)) {
          return;
        }
      } catch (err) {}
      appendTerminalOutput(e.data);
    }
  };

  termWs.onclose = () => {
    appendTerminalOutput('\r\n\x1b[1;31m[!] Sessao de terminal encerrada.\x1b[0m\r\n');
  };

  // Foco no campo de texto
  setTimeout(() => {
    const inputF = document.getElementById('term-input-field');
    if (inputF) inputF.focus();
  }, 100);
}

function appendTerminalOutput(text) {
  if (term) {
    term.write(text);
  } else {
    const fallback = document.getElementById('fallback-term-output');
    if (fallback) {
      fallback.textContent += text;
      fallback.scrollTop = fallback.scrollHeight;
    }
  }
}

function sendTerminalRaw(bytes) {
  if (termWs && termWs.readyState === WebSocket.OPEN) {
    termWs.send(bytes);
  }
}

function sendTerminalKey(keyType) {
  if (!termWs || termWs.readyState !== WebSocket.OPEN) return;
  switch (keyType) {
    case '^C':
      if (term) term.write('^C\r\n');
      sendTerminalRaw('\x03');
      break;
    case '^D':
      sendTerminalRaw('\x04');
      break;
    case '^A':
      sendTerminalRaw('\x01');
      break;
    case '^W':
      sendTerminalRaw('\x17');
      break;
    case '^L':
      if (term) term.clear();
      sendTerminalRaw('\x0c');
      break;
    case '^U':
      sendTerminalRaw('\x15');
      break;
    case 'TAB':
      sendTerminalRaw('\t');
      break;
    case 'ESC':
      sendTerminalRaw('\x1b');
      break;
  }
}

function handleTerminalKey(e) {
  if (e.key === 'Enter') {
    e.preventDefault();
    sendTerminalLine();
    return;
  }
  if (e.ctrlKey) {
    const k = e.key.toLowerCase();
    if (k === 'c') {
      const inputElem = document.getElementById('term-input-field');
      if (inputElem && inputElem.selectionStart === inputElem.selectionEnd) {
        e.preventDefault();
        inputElem.value = '';
        sendTerminalKey('^C');
      }
    } else if (k === 'w') {
      e.preventDefault(); // Evita que o browser feche a aba!
      const inputElem = document.getElementById('term-input-field');
      if (inputElem) {
        inputElem.value = inputElem.value.replace(/\s*\S+\s*$/, '');
      }
      sendTerminalKey('^W');
    } else if (k === 'u') {
      e.preventDefault();
      const inputElem = document.getElementById('term-input-field');
      if (inputElem) inputElem.value = '';
      sendTerminalKey('^U');
    } else if (k === 'd') {
      e.preventDefault();
      sendTerminalKey('^D');
    } else if (k === 'l') {
      e.preventDefault();
      sendTerminalKey('^L');
    }
  }
}

function sendTerminalLine() {
  const inputElem = document.getElementById('term-input-field');
  if (!inputElem) return;
  const val = inputElem.value;
  if (!val.trim()) return;
  inputElem.value = '';

  // Eco local visual do comando para retorno imediato na tela
  appendTerminalOutput(val + '\r\n');

  if (termWs && termWs.readyState === WebSocket.OPEN) {
    termWs.send(val + '\n');
  }
}

function closeTerminal() {
  cancelFileUpload(false);
  if (termWs) {
    termWs.close();
    termWs = null;
  }
  document.getElementById('modal-terminal').classList.remove('open');
}

// ---------------------------------------------------------------------------
// GERENCIADOR DE UPLOAD DE ARQUIVOS VIA TERMINAL (DIRETO PARA /tmp)
// ---------------------------------------------------------------------------
let currentUpload = null;
const UPLOAD_CHUNK_SIZE = 32 * 1024; // 32 KB por pedaço (mantém os frames sempre abaixo de 64KB no WebSocket)
const UPLOAD_WINDOW_SIZE = 16;       // 16 chunks em trânsito contínuo (512 KB pipeline para saturação máxima da banda)

function formatBytes(bytes, decimals = 1) {
  if (!bytes || bytes <= 0) return '0 B';
  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + ' ' + sizes[i];
}

function triggerFileUpload() {
  const input = document.getElementById('term-file-input');
  if (input) {
    input.value = '';
    input.click();
  }
}

function handleFileSelected(event) {
  const file = event.target.files && event.target.files[0];
  if (file) {
    startFileUpload(file);
  }
}

function startFileUpload(file) {
  if (!file) return;
  if (!termWs || termWs.readyState !== WebSocket.OPEN) {
    alert('Terminal desconectado. Conecte ao console antes de enviar arquivos.');
    return;
  }

  if (currentUpload && (currentUpload.status === 'uploading' || currentUpload.status === 'starting')) {
    if (!confirm(`Já existe um envio em andamento (${currentUpload.filename}). Deseja cancelar e enviar "${file.name}"?`)) {
      return;
    }
    cancelFileUpload(false);
  }

  const uploadId = 'up_' + Date.now() + '_' + Math.random().toString(36).substring(2, 7);

  currentUpload = {
    id: uploadId,
    file: file,
    filename: file.name,
    totalSize: file.size,
    status: 'starting',
    startTime: Date.now()
  };

  const panel = document.getElementById('term-upload-panel');
  const nameEl = document.getElementById('term-upload-name');
  const percentEl = document.getElementById('term-upload-percent');
  const statsEl = document.getElementById('term-upload-stats');
  const barEl = document.getElementById('term-upload-bar');

  if (panel) panel.style.display = 'block';
  if (nameEl) nameEl.textContent = file.name;
  if (percentEl) percentEl.textContent = '0%';
  if (statsEl) statsEl.textContent = `Enviando para o Cloud Controller (0 / ${formatBytes(file.size)})...`;
  if (barEl) barEl.style.width = '0%';

  if (term) {
    term.writeln(`\r\n\x1b[1;36m[Turbo Upload] Enviando "${file.name}" (${formatBytes(file.size)}) diretamente para /tmp...\x1b[0m`);
  }

  // Turbo Upload via HTTP para Cloud Run seguido de download direto com curl no roteador
  const xhr = new XMLHttpRequest();
  xhr.open('POST', `/api/upload?filename=${encodeURIComponent(file.name)}&upload_id=${uploadId}`);

  xhr.upload.onprogress = (e) => {
    if (!currentUpload || currentUpload.id !== uploadId) return;
    if (e.lengthComputable) {
      const pct = Math.min(90, Math.round((e.loaded / e.total) * 90));
      if (barEl) barEl.style.width = pct + '%';
      if (percentEl) percentEl.textContent = pct + '%';
      const elapsed = (Date.now() - currentUpload.startTime) / 1000;
      const speed = elapsed > 0 ? e.loaded / elapsed : 0;
      const remaining = speed > 0 ? (e.total - e.loaded) / speed : 0;
      if (statsEl) {
        statsEl.textContent = `Enviando para Nuvem: ${formatBytes(e.loaded)} / ${formatBytes(e.total)} • ${formatBytes(speed)}/s • restam ${Math.ceil(remaining)}s`;
      }
    }
  };

  xhr.onload = () => {
    if (!currentUpload || currentUpload.id !== uploadId) return;
    if (xhr.status >= 200 && xhr.status < 300) {
      try {
        const resp = JSON.parse(xhr.responseText);
        if (resp && resp.ok && resp.download_url) {
          if (statsEl) statsEl.textContent = 'Roteador gravando em /tmp via curl...';
          if (percentEl) percentEl.textContent = '95%';
          if (barEl) barEl.style.width = '95%';

          termWs.send(JSON.stringify({
            type: 'fast_file_download',
            upload_id: uploadId,
            url: resp.download_url,
            filename: file.name,
            total_size: file.size
          }));
          return;
        }
      } catch (err) {}
    }
    console.warn('[Turbo Upload] Falha na rota HTTP, iniciando fallback via WebSocket...');
    startFileUploadFallbackWs(file, uploadId);
  };

  xhr.onerror = () => {
    if (!currentUpload || currentUpload.id !== uploadId) return;
    console.warn('[Turbo Upload] Erro de rede HTTP, iniciando fallback via WebSocket...');
    startFileUploadFallbackWs(file, uploadId);
  };

  xhr.send(file);
}

function startFileUploadFallbackWs(file, uploadId) {
  const totalChunks = Math.ceil(file.size / UPLOAD_CHUNK_SIZE);
  currentUpload = {
    id: uploadId || ('up_' + Date.now() + '_' + Math.random().toString(36).substring(2, 7)),
    file: file,
    filename: file.name,
    totalSize: file.size,
    totalChunks: totalChunks,
    nextChunkToSend: 0,
    chunksInFlight: 0,
    ackedChunks: 0,
    status: 'starting',
    startTime: Date.now()
  };

  const statsEl = document.getElementById('term-upload-stats');
  if (statsEl) statsEl.textContent = `Preparando envio WebSocket (0 / ${formatBytes(file.size)})...`;

  termWs.send(JSON.stringify({
    type: 'file_upload_start',
    upload_id: currentUpload.id,
    filename: file.name,
    total_size: file.size
  }));

  currentUpload.readyTimeout = setTimeout(() => {
    if (currentUpload && currentUpload.status === 'starting') {
      alert(`O roteador não respondeu à solicitação de upload para "${file.name}".\n\nCertifique-se de que o roteador está conectado e com o floresta_agent atualizado.`);
      cancelFileUpload(true);
    }
  }, 10000);
}

function pumpUploadWindow() {
  if (!currentUpload || currentUpload.status !== 'uploading') return;
  if (!termWs || termWs.readyState !== WebSocket.OPEN) return;

  while (
    currentUpload.chunksInFlight < UPLOAD_WINDOW_SIZE &&
    currentUpload.nextChunkToSend < currentUpload.totalChunks
  ) {
    const chunkIdx = currentUpload.nextChunkToSend;
    currentUpload.nextChunkToSend++;
    currentUpload.chunksInFlight++;
    sendSpecificChunk(chunkIdx);
  }
}

function sendSpecificChunk(chunkIndex) {
  if (!currentUpload || currentUpload.status !== 'uploading') return;

  const start = chunkIndex * UPLOAD_CHUNK_SIZE;
  const end = Math.min(start + UPLOAD_CHUNK_SIZE, currentUpload.totalSize);
  const blob = currentUpload.file.slice(start, end);

  blob.arrayBuffer().then(arrayBuffer => {
    if (!currentUpload || currentUpload.status !== 'uploading') return;
    if (!termWs || termWs.readyState !== WebSocket.OPEN) return;

    const bytes = new Uint8Array(arrayBuffer);
    const len = bytes.byteLength;
    let binary = '';
    const chunkSub = 8192;
    for (let i = 0; i < len; i += chunkSub) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, Math.min(i + chunkSub, len)));
    }
    const b64Data = btoa(binary);

    termWs.send(JSON.stringify({
      type: 'file_upload_chunk',
      upload_id: currentUpload.id,
      chunk: chunkIndex,
      data: b64Data
    }));
  }).catch(err => {
    console.error('[Upload] Erro ao ler fatia do arquivo local:', err);
    alert('Erro ao ler arquivo: ' + err.message);
    cancelFileUpload(true);
  });
}

function handleFileUploadMessage(msg) {
  if (!currentUpload || currentUpload.id !== msg.upload_id) {
    return false;
  }

  if (msg.type === 'file_upload_ready') {
    if (currentUpload.readyTimeout) {
      clearTimeout(currentUpload.readyTimeout);
      currentUpload.readyTimeout = null;
    }
    if (!msg.success) {
      alert('Erro ao iniciar gravação no roteador: ' + (msg.error || 'Falha desconhecida'));
      cancelFileUpload(true);
      return true;
    }
    currentUpload.status = 'uploading';
    currentUpload.nextChunkToSend = 0;
    currentUpload.chunksInFlight = 0;
    currentUpload.ackedChunks = 0;
    pumpUploadWindow();
    return true;
  } else if (msg.type === 'file_upload_ack') {
    if (!msg.success) {
      alert('Erro durante a transmissão do arquivo: ' + (msg.error || 'Erro desconhecido'));
      cancelFileUpload(true);
      return true;
    }
    currentUpload.chunksInFlight = Math.max(0, currentUpload.chunksInFlight - 1);
    currentUpload.ackedChunks++;
    updateUploadProgress(msg.received || (currentUpload.ackedChunks * UPLOAD_CHUNK_SIZE), currentUpload.totalSize);

    if (currentUpload.ackedChunks >= currentUpload.totalChunks) {
      currentUpload.status = 'finalizing';
      const statsEl = document.getElementById('term-upload-stats');
      if (statsEl) statsEl.textContent = 'Gravando na memória e calculando MD5...';
      termWs.send(JSON.stringify({
        type: 'file_upload_end',
        upload_id: currentUpload.id
      }));
    } else {
      pumpUploadWindow();
    }
    return true;
  } else if (msg.type === 'file_upload_done') {
    currentUpload.status = 'done';
    const panel = document.getElementById('term-upload-panel');
    const percentEl = document.getElementById('term-upload-percent');
    const statsEl = document.getElementById('term-upload-stats');
    const barEl = document.getElementById('term-upload-bar');

    if (percentEl) percentEl.textContent = '100%';
    if (barEl) barEl.style.width = '100%';
    const duration = ((Date.now() - currentUpload.startTime) / 1000).toFixed(1);
    if (statsEl) statsEl.textContent = `Concluído em ${duration}s! Salvo em ${msg.target_path || '/tmp'}`;

    if (term) {
      term.writeln(`\x1b[1;32m[✓ Sucesso] Arquivo gravado em ${msg.target_path || '/tmp/' + currentUpload.filename} (${formatBytes(msg.size || currentUpload.totalSize)})\x1b[0m`);
      if (msg.md5) {
        term.writeln(`\x1b[1;33m[Checksum MD5] ${msg.md5}\x1b[0m`);
      }
    }

    setTimeout(() => {
      if (panel && currentUpload && currentUpload.status === 'done') {
        panel.style.display = 'none';
        currentUpload = null;
      }
    }, 4500);
    return true;
  }

  return false;
}

function updateUploadProgress(receivedBytes, totalBytes) {
  if (!currentUpload) return;
  const percent = Math.min(100, Math.round((receivedBytes / totalBytes) * 100));
  const barEl = document.getElementById('term-upload-bar');
  const percentEl = document.getElementById('term-upload-percent');
  const statsEl = document.getElementById('term-upload-stats');

  if (barEl) barEl.style.width = percent + '%';
  if (percentEl) percentEl.textContent = percent + '%';

  const elapsed = (Date.now() - currentUpload.startTime) / 1000;
  const speed = elapsed > 0 ? receivedBytes / elapsed : 0;
  const remaining = speed > 0 ? (totalBytes - receivedBytes) / speed : 0;

  if (statsEl) {
    statsEl.textContent = `${formatBytes(receivedBytes)} / ${formatBytes(totalBytes)} • ${formatBytes(speed)}/s • restam ${Math.ceil(remaining)}s`;
  }
}

function cancelFileUpload(notify = true) {
  if (currentUpload) {
    if (currentUpload.readyTimeout) {
      clearTimeout(currentUpload.readyTimeout);
    }
    currentUpload.status = 'cancelled';
    currentUpload = null;
  }
  const panel = document.getElementById('term-upload-panel');
  if (panel) panel.style.display = 'none';
  if (notify && term) {
    term.writeln(`\r\n\x1b[1;31m[Upload] Transferência cancelada pelo usuário.\x1b[0m\r\n`);
  }
}

// ---------------------------------------------------------------------------
// TÚNEL TCP REVERSO (MODELO A - WEBSOCKET REVERSE PROXY)
// ---------------------------------------------------------------------------
let activeTunnelMac = null;
let activeTunnelPort = null;

function openWebTunnelModal(mac, name) {
  activeTunnelMac = mac;
  document.getElementById('tunnel-router-name').textContent = `${name || 'Roteador'} (${mac})`;
  document.getElementById('tunnel-status-loading').style.display = 'block';
  document.getElementById('tunnel-status-ready').style.display = 'none';
  document.getElementById('tunnel-status-error').style.display = 'none';
  document.getElementById('modal-tunnel').classList.add('open');

  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      action: 'start_web_tunnel',
      mac: mac
    }));
  } else {
    onTunnelError(mac, 'Conexão com o servidor Cloud está inativa.');
  }
}

function onTunnelReady(mac, port, url) {
  if (activeTunnelMac !== mac) return;
  activeTunnelPort = port;
  
  const cleanMac = mac.replace(/[^0-9A-Fa-f]/g, '').toUpperCase();
  const tunnelUrl = `/select-router?mac=${cleanMac}`;

  document.getElementById('tunnel-status-loading').style.display = 'none';
  document.getElementById('tunnel-status-ready').style.display = 'block';
  
  const badge = document.getElementById('tunnel-port-badge');
  if (badge) {
    badge.textContent = 'HTTPS (Sessão Direta na Raiz)';
  }

  const openBtn = document.getElementById('tunnel-open-btn');
  openBtn.href = tunnelUrl;
}

function onTunnelStopped(mac) {
  if (activeTunnelMac === mac) {
    activeTunnelPort = null;
    closeTunnelModal();
  }
}

function onTunnelError(mac, error) {
  if (activeTunnelMac !== mac) return;
  document.getElementById('tunnel-status-loading').style.display = 'none';
  document.getElementById('tunnel-status-ready').style.display = 'none';
  document.getElementById('tunnel-status-error').style.display = 'block';
  document.getElementById('tunnel-error-msg').textContent = error || 'Erro ao iniciar túnel.';
}

function terminateCurrentTunnel() {
  if (activeTunnelMac && ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({
      action: 'stop_web_tunnel',
      mac: activeTunnelMac
    }));
  }
  closeTunnelModal();
}

function closeTunnelModal() {
  document.getElementById('modal-tunnel').classList.remove('open');
}

// ===========================================================================
// GESTÃO DE BLOQUEIO DNS (DNS SINKHOLE)
// ===========================================================================
let defaultDnsList = [];
let activeRouterDnsMac = null;
let activeRouterDnsList = [];
let defaultDnsFilter = '';
let routerDnsFilter = '';

function cleanDomain(raw) {
  if (!raw || typeof raw !== 'string') return '';
  let d = raw.trim().toLowerCase();
  d = d.replace(/^https?:\/\//i, '');
  d = d.replace(/^www\./i, '');
  d = d.replace(/\/.*$/, '');
  d = d.replace(/:.*$/, '');
  d = d.trim();
  if (d.length > 2 && d.includes('.')) {
    return d;
  }
  return '';
}

// --- MODAL DA LISTA PADRÃO GLOBAL ---
function openDefaultDnsModal() {
  if (defaultDnsList.length === 0 && ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ action: 'get_default_dns_blocklist' }));
  }
  renderDefaultDnsTags();
  document.getElementById('modal-default-dns').classList.add('open');
  setTimeout(() => {
    const inp = document.getElementById('default-dns-input');
    if (inp) inp.focus();
  }, 100);
}

function closeDefaultDnsModal() {
  document.getElementById('modal-default-dns').classList.remove('open');
}

function renderDefaultDnsTags() {
  const container = document.getElementById('default-dns-tags');
  const countBadge = document.getElementById('default-dns-count');
  const filterCount = document.getElementById('default-dns-filter-count');
  if (!container) return;

  const total = defaultDnsList.length;
  if (countBadge) countBadge.textContent = `${total} domínios`;

  const query = defaultDnsFilter.trim().toLowerCase();
  const visibleList = query ? defaultDnsList.filter(d => d.toLowerCase().includes(query)) : defaultDnsList;

  if (filterCount) {
    filterCount.textContent = query ? `(Exibindo ${visibleList.length} de ${total})` : '';
  }

  if (visibleList.length === 0) {
    container.innerHTML = `<div style="color:var(--text-muted); font-size:13px; padding:10px; width:100%; text-align:center;">${query ? 'Nenhum domínio coincide com o filtro.' : 'Nenhum domínio configurado na lista padrão.'}</div>`;
    return;
  }

  let html = '';
  visibleList.forEach(d => {
    html += `
      <span class="dns-domain-tag">
        <span>${d}</span>
        <span class="tag-del" onclick="removeDefaultDnsDomain('${d}')" title="Remover domínio">&times;</span>
      </span>
    `;
  });
  container.innerHTML = html;
}

function filterDefaultDnsList(val) {
  defaultDnsFilter = val || '';
  renderDefaultDnsTags();
}

function handleDefaultDnsInput(e) {
  if (e.key === 'Enter') {
    e.preventDefault();
    addDefaultDnsDomain();
  }
}

function addDefaultDnsDomain() {
  const inp = document.getElementById('default-dns-input');
  if (!inp) return;
  const cleaned = cleanDomain(inp.value);
  if (!cleaned) {
    alert('Por favor, informe um formato de domínio válido (ex: bet365.com).');
    return;
  }
  if (defaultDnsList.includes(cleaned)) {
    alert(`O domínio '${cleaned}' já está na lista.`);
    return;
  }
  defaultDnsList.unshift(cleaned);
  inp.value = '';
  renderDefaultDnsTags();
}

function removeDefaultDnsDomain(domain) {
  defaultDnsList = defaultDnsList.filter(d => d !== domain);
  renderDefaultDnsTags();
}

function clearAllDefaultDns() {
  if (confirm('Deseja realmente limpar todos os domínios da lista padrão?')) {
    defaultDnsList = [];
    renderDefaultDnsTags();
  }
}

function resetDefaultDnsToRecommended() {
  const recommended = [
    'bet365.com', 'betano.com', 'betfair.com', 'sportingbet.com', 'pixbet.com',
    'blaze.com', 'kto.com', 'estrelabet.com', 'apostaganha.bet', 'novibet.com',
    'vaidebet.com', 'superbet.com', 'parimatch.com', '1xbet.com', 'bodog.com',
    'rivalo.com', 'casasdeapostas.com', 'f12.bet', 'jogodobicho.com',
    'xvideos.com', 'pornhub.com', 'xnxx.com', 'redtube.com', 'erome.com'
  ];
  const merged = Array.from(new Set([...defaultDnsList, ...recommended]));
  defaultDnsList = merged;
  renderDefaultDnsTags();
}

function saveDefaultDnsList() {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    alert('Erro: Servidor WebSocket desconectado.');
    return;
  }
  ws.send(JSON.stringify({
    action: 'save_default_dns_blocklist',
    domains: defaultDnsList
  }));
  try {
    localStorage.setItem('floresta_default_dns', JSON.stringify(defaultDnsList));
  } catch (_) {}
  alert('Lista padrão de bloqueio DNS salva com sucesso na nuvem!');
}

function applyDefaultDnsToAllRouters() {
  if (!confirm(`Deseja aplicar esta Lista Padrão (${defaultDnsList.length} domínios) a TODOS os roteadores adotados na frota?\n\nRoteadores online aplicarão as regras imediatamente.`)) {
    return;
  }
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    alert('Erro: Servidor WebSocket desconectado.');
    return;
  }
  ws.send(JSON.stringify({
    action: 'apply_default_to_all_routers'
  }));
}

// --- MODAL DE BLOQUEIO DNS POR ROTEADOR ---
function openRouterDnsModal(mac, name) {
  activeRouterDnsMac = mac;
  let cleanName = name || 'Archer BE220';
  try { cleanName = decodeURIComponent(cleanName); } catch (e) { }

  document.getElementById('router-dns-device-name').textContent = `${cleanName} (${mac})`;

  const router = routersMap.get(mac);
  activeRouterDnsList = router && Array.isArray(router.dns_blocklist) ? [...router.dns_blocklist] : [];

  const statusBox = document.getElementById('router-dns-status-box');
  if (statusBox) statusBox.style.display = 'none';

  routerDnsFilter = '';
  const searchInp = document.getElementById('router-dns-search');
  if (searchInp) searchInp.value = '';

  renderRouterDnsTags();
  document.getElementById('modal-router-dns').classList.add('open');

  setTimeout(() => {
    const inp = document.getElementById('router-dns-input');
    if (inp) inp.focus();
  }, 100);
}

function closeRouterDnsModal() {
  activeRouterDnsMac = null;
  document.getElementById('modal-router-dns').classList.remove('open');
}

function renderRouterDnsTags() {
  const container = document.getElementById('router-dns-tags');
  const countBadge = document.getElementById('router-dns-count');
  const filterCount = document.getElementById('router-dns-filter-count');
  if (!container) return;

  const total = activeRouterDnsList.length;
  if (countBadge) countBadge.textContent = `${total} domínios`;

  const query = routerDnsFilter.trim().toLowerCase();
  const visibleList = query ? activeRouterDnsList.filter(d => d.toLowerCase().includes(query)) : activeRouterDnsList;

  if (filterCount) {
    filterCount.textContent = query ? `(Exibindo ${visibleList.length} de ${total})` : '';
  }

  if (visibleList.length === 0) {
    container.innerHTML = `<div style="color:var(--text-muted); font-size:13px; padding:10px; width:100%; text-align:center;">${query ? 'Nenhum domínio coincide com o filtro.' : 'Nenhum bloqueio configurado para este roteador. Clique em "Importar da Lista Padrão" ou adicione domínios acima.'}</div>`;
    return;
  }

  let html = '';
  visibleList.forEach(d => {
    html += `
      <span class="dns-domain-tag">
        <span>${d}</span>
        <span class="tag-del" onclick="removeRouterDnsDomain('${d}')" title="Remover domínio">&times;</span>
      </span>
    `;
  });
  container.innerHTML = html;
}

function filterRouterDnsList(val) {
  routerDnsFilter = val || '';
  renderRouterDnsTags();
}

function handleRouterDnsInput(e) {
  if (e.key === 'Enter') {
    e.preventDefault();
    addRouterDnsDomain();
  }
}

function addRouterDnsDomain() {
  const inp = document.getElementById('router-dns-input');
  if (!inp) return;
  const cleaned = cleanDomain(inp.value);
  if (!cleaned) {
    alert('Por favor, informe um formato de domínio válido (ex: bet365.com).');
    return;
  }
  if (activeRouterDnsList.includes(cleaned)) {
    alert(`O domínio '${cleaned}' já está na lista deste roteador.`);
    return;
  }
  activeRouterDnsList.unshift(cleaned);
  inp.value = '';
  renderRouterDnsTags();
}

function removeRouterDnsDomain(domain) {
  activeRouterDnsList = activeRouterDnsList.filter(d => d !== domain);
  renderRouterDnsTags();
}

function clearAllRouterDns() {
  if (confirm('Deseja realmente remover todos os domínios de bloqueio deste roteador?')) {
    activeRouterDnsList = [];
    renderRouterDnsTags();
  }
}

function importFromDefaultDns() {
  if (defaultDnsList.length === 0) {
    alert('A Lista Padrão Global está vazia no momento.');
    return;
  }
  const beforeCount = activeRouterDnsList.length;
  const merged = Array.from(new Set([...activeRouterDnsList, ...defaultDnsList]));
  activeRouterDnsList = merged;
  renderRouterDnsTags();
  const added = activeRouterDnsList.length - beforeCount;
  alert(`${added} novos domínios foram importados da lista padrão! Clique em "Atualizar Bloqueios no Roteador" para aplicar.`);
}

function saveRouterDnsList(syncNow = false) {
  if (!activeRouterDnsMac) return;
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    alert('Erro: Conexão com o servidor Cloud está inativa.');
    return;
  }

  const statusBox = document.getElementById('router-dns-status-box');
  if (statusBox && syncNow) {
    statusBox.innerHTML = `
      <div class="dns-alert dns-alert-info">
        <span>⏳ Enviando comando de atualização DNS para o roteador...</span>
      </div>
    `;
    statusBox.style.display = 'block';
  }

  ws.send(JSON.stringify({
    action: 'save_router_dns_blocklist',
    mac: activeRouterDnsMac,
    domains: activeRouterDnsList,
    sync_now: syncNow
  }));

  const r = routersMap.get(activeRouterDnsMac);
  if (r) {
    r.dns_blocklist = [...activeRouterDnsList];
    renderAll();
  }

  // Persiste imediatamente no localStorage do navegador para auto-cura resiliente
  try {
    localStorage.setItem('floresta_dns_' + activeRouterDnsMac, JSON.stringify(activeRouterDnsList));
  } catch (_) {}
}

// ===========================================================================
// HISTÓRICO DE TELEMETRIA E DISPONIBILIDADE (ATÉ 365 DIAS / 10 EM 10 MIN)
// ===========================================================================
let activeHistoryMac = null;
let activeHistoryName = '';
let activeHistoryDays = 7;
let currentHistoryPoints = [];

function openHistoryModal(mac, name) {
  activeHistoryMac = mac;
  let cleanName = name || 'Archer BE220';
  try { cleanName = decodeURIComponent(cleanName); } catch (e) {}
  activeHistoryName = cleanName;

  document.getElementById('history-router-name').textContent = `${cleanName} (${mac})`;
  document.getElementById('modal-history').classList.add('open');
  changeHistoryPeriod(activeHistoryDays);
}

function closeHistoryModal() {
  clearHistoryHover();
  activeHistoryMac = null;
  document.getElementById('modal-history').classList.remove('open');
}

function changeHistoryPeriod(days) {
  activeHistoryDays = days;
  const btnContainer = document.getElementById('history-period-btns');
  if (btnContainer) {
    btnContainer.querySelectorAll('button[data-days]').forEach(btn => {
      if (Number(btn.getAttribute('data-days')) === days) {
        btn.classList.add('btn-primary');
      } else {
        btn.classList.remove('btn-primary');
      }
    });
  }
  refreshHistoryData();
}

async function refreshHistoryData() {
  if (!activeHistoryMac) return;
  const tableContainer = document.getElementById('history-table-container');
  if (tableContainer) {
    tableContainer.innerHTML = '<div style="padding:18px; text-align:center; color:var(--text-muted);">⏳ Carregando histórico de 10 em 10 minutos...</div>';
  }
  try {
    const resp = await fetch(`/api/router/history?mac=${encodeURIComponent(activeHistoryMac)}&days=${activeHistoryDays}`);
    const data = await resp.json();
    if (data && data.ok) {
      currentHistoryPoints = Array.isArray(data.points) ? data.points : [];
      renderHistoryView(currentHistoryPoints);
    } else {
      if (tableContainer) {
        tableContainer.innerHTML = `<div style="padding:18px; text-align:center; color:#f43f5e;">Erro ao carregar histórico: ${(data && data.error) || 'Desconhecido'}</div>`;
      }
    }
  } catch (err) {
    if (tableContainer) {
      tableContainer.innerHTML = `<div style="padding:18px; text-align:center; color:#f43f5e;">Falha na comunicação com o servidor: ${err.message}</div>`;
    }
  }
}

function formatHistoryDate(ts, short = false) {
  const d = new Date(ts * 1000);
  const pad = n => String(n).padStart(2, '0');
  if (short) {
    return `${pad(d.getDate())}/${pad(d.getMonth() + 1)} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function renderHistoryView(points) {
  const totalSlots = points.length;
  const onlinePoints = points.filter(p => Number(p[1]) === 1);
  const onlineCount = onlinePoints.length;
  const uptimePct = totalSlots > 0 ? ((onlineCount / totalSlots) * 100).toFixed(1) : '0.0';

  document.getElementById('hist-kpi-uptime').textContent = totalSlots > 0 ? `${uptimePct}%` : '—';
  document.getElementById('hist-kpi-uptime-sub').textContent = `${onlineCount} de ${totalSlots} janelas (10 min)`;

  if (onlineCount > 0) {
    const clientsArr = onlinePoints.map(p => Number(p[2]) || 0);
    const maxClients = Math.max(...clientsArr);
    const avgClients = (clientsArr.reduce((a, b) => a + b, 0) / onlineCount).toFixed(1);
    document.getElementById('hist-kpi-clients').textContent = `Pico: ${maxClients}`;
    document.getElementById('hist-kpi-clients-sub').textContent = `Média online: ${avgClients} clientes`;

    const cpuArr = onlinePoints.map(p => Number(p[4]) || 0);
    const maxCpu = Math.max(...cpuArr).toFixed(2);
    const avgCpu = (cpuArr.reduce((a, b) => a + b, 0) / onlineCount).toFixed(2);
    document.getElementById('hist-kpi-cpu').textContent = `${avgCpu}`;
    document.getElementById('hist-kpi-cpu-sub').textContent = `Pico no período: ${maxCpu}`;

    const memArr = onlinePoints.map(p => Number(p[3]) || 0).filter(m => m > 0);
    if (memArr.length > 0) {
      const minMem = Math.min(...memArr);
      const avgMem = Math.round(memArr.reduce((a, b) => a + b, 0) / memArr.length);
      document.getElementById('hist-kpi-mem').textContent = `${avgMem} MB`;
      document.getElementById('hist-kpi-mem-sub').textContent = `Mínima livre: ${minMem} MB`;
    } else {
      document.getElementById('hist-kpi-mem').textContent = '—';
      document.getElementById('hist-kpi-mem-sub').textContent = 'Sem leitura de RAM';
    }
  } else {
    document.getElementById('hist-kpi-clients').textContent = '0';
    document.getElementById('hist-kpi-clients-sub').textContent = 'Sem sessões no período';
    document.getElementById('hist-kpi-cpu').textContent = '—';
    document.getElementById('hist-kpi-cpu-sub').textContent = 'Roteador offline';
    document.getElementById('hist-kpi-mem').textContent = '—';
    document.getElementById('hist-kpi-mem-sub').textContent = 'Roteador offline';
  }

  redrawHistoryCharts(-1);
  setupHistoryCanvasInteractions();

  const countEl = document.getElementById('history-records-count');
  if (countEl) countEl.textContent = `${totalSlots} janela(s) de 10 min registradas`;

  const tableContainer = document.getElementById('history-table-container');
  if (!tableContainer) return;

  if (totalSlots === 0) {
    tableContainer.innerHTML = '<div style="padding:18px; text-align:center; color:var(--text-muted);">Nenhum ponto histórico registrado ainda para este período.</div>';
    return;
  }

  const recent = [...points].reverse().slice(0, 300);
  let html = `
    <table style="width:100%; text-align:left; border-collapse:collapse; font-size:12px;">
      <thead>
        <tr style="border-bottom:1px solid var(--border-color); color:var(--text-muted);">
          <th style="padding:6px 8px;">Janela (10 min)</th>
          <th style="padding:6px 8px;">Status</th>
          <th style="padding:6px 8px;">Clientes</th>
          <th style="padding:6px 8px;">Carga CPU (1m)</th>
          <th style="padding:6px 8px;">Memória Livre</th>
        </tr>
      </thead>
      <tbody>
  `;
  recent.forEach(p => {
    const isOn = Number(p[1]) === 1;
    html += `
      <tr style="border-bottom:1px solid rgba(255,255,255,0.04);">
        <td style="padding:6px 8px; font-family:var(--font-mono);">${formatHistoryDate(p[0])}</td>
        <td style="padding:6px 8px;">
          <span class="badge ${isOn ? 'online' : 'offline'}" style="font-size:11px; padding:2px 8px;">
            ${isOn ? '● Conectado' : '○ Offline'}
          </span>
        </td>
        <td style="padding:6px 8px; font-weight:600; color:${isOn ? '#34d399' : 'var(--text-muted)'};">${isOn ? p[2] : '—'}</td>
        <td style="padding:6px 8px; font-family:var(--font-mono);">${isOn ? Number(p[4]).toFixed(2) : '—'}</td>
        <td style="padding:6px 8px; font-family:var(--font-mono);">${isOn && p[3] ? p[3] + ' MB' : '—'}</td>
      </tr>
    `;
  });
  html += '</tbody></table>';
  tableContainer.innerHTML = html;
}

function redrawHistoryCharts(highlightIndex = -1) {
  if (!currentHistoryPoints || currentHistoryPoints.length === 0) return;
  drawHistoryOnlineTimeline('chart-history-online', currentHistoryPoints, highlightIndex);
  drawHistoryMetricChart('chart-history-clients', currentHistoryPoints, 2, '#10b981', 'rgba(16, 185, 129, 0.18)', '', highlightIndex);
  drawHistoryMetricChart('chart-history-cpu', currentHistoryPoints, 4, '#f59e0b', 'rgba(245, 158, 11, 0.18)', '', highlightIndex);
  drawHistoryMetricChart('chart-history-mem', currentHistoryPoints, 3, '#38bdf8', 'rgba(56, 189, 248, 0.18)', ' MB', highlightIndex);
}

function drawHistoryOnlineTimeline(canvasId, points, highlightIndex = -1) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const w = canvas.width;
  const h = canvas.height;
  ctx.clearRect(0, 0, w, h);

  if (!points || points.length === 0) {
    ctx.fillStyle = '#64748b';
    ctx.font = '12px Inter, sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('Sem dados no período', w / 2, h / 2 + 4);
    return;
  }

  const n = points.length;
  const barW = Math.max(2, w / n);
  for (let i = 0; i < n; i++) {
    const isOn = Number(points[i][1]) === 1;
    const x = (i / n) * w;
    ctx.fillStyle = isOn ? '#10b981' : '#f43f5e';
    ctx.fillRect(x, 4, Math.ceil(barW), h - 20);
  }

  // Destaque do momento selecionado pelo hover
  if (highlightIndex >= 0 && highlightIndex < n) {
    const hx = (highlightIndex / n) * w;
    ctx.save();
    ctx.strokeStyle = '#ffffff';
    ctx.lineWidth = 2;
    ctx.shadowColor = '#00d2ff';
    ctx.shadowBlur = 8;
    ctx.strokeRect(hx - 1, 2, Math.max(4, barW + 2), h - 16);
    ctx.restore();
  }

  ctx.fillStyle = '#94a3b8';
  ctx.font = '10px JetBrains Mono, monospace';
  ctx.textAlign = 'left';
  ctx.fillText(formatHistoryDate(points[0][0], true), 4, h - 4);
  ctx.textAlign = 'right';
  ctx.fillText(formatHistoryDate(points[n - 1][0], true), w - 4, h - 4);
}

function drawHistoryMetricChart(canvasId, points, idx, strokeColor, fillColor, unitSuffix, highlightIndex = -1) {
  const canvas = document.getElementById(canvasId);
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const w = canvas.width;
  const h = canvas.height;
  ctx.clearRect(0, 0, w, h);

  const padLeft = 44;
  const padRight = 14;
  const padTop = 14;
  const padBottom = 22;
  const plotW = w - padLeft - padRight;
  const plotH = h - padTop - padBottom;

  if (!points || points.length === 0) {
    ctx.fillStyle = '#64748b';
    ctx.font = '12px Inter, sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText('Sem dados registrados no período', w / 2, h / 2);
    return;
  }

  const vals = points.map(p => (Number(p[1]) === 1 ? Number(p[idx]) || 0 : 0));
  let maxVal = Math.max(...vals, 1);
  if (idx === 2 && maxVal < 5) maxVal = 5;
  if (idx === 4 && maxVal < 2) maxVal = 2.0;

  // Linhas de grade horizontais
  ctx.strokeStyle = 'rgba(255, 255, 255, 0.06)';
  ctx.lineWidth = 1;
  ctx.fillStyle = '#64748b';
  ctx.font = '10px JetBrains Mono, monospace';
  ctx.textAlign = 'right';

  for (let g = 0; g <= 2; g++) {
    const gy = padTop + (g / 2) * plotH;
    const labelVal = maxVal * (1 - g / 2);
    ctx.beginPath();
    ctx.moveTo(padLeft, gy);
    ctx.lineTo(w - padRight, gy);
    ctx.stroke();
    const formatted = idx === 4 ? labelVal.toFixed(1) : Math.round(labelVal);
    ctx.fillText(`${formatted}${unitSuffix}`, padLeft - 6, gy + 3);
  }

  const n = points.length;
  const getX = i => padLeft + (n === 1 ? plotW / 2 : (i / (n - 1)) * plotW);
  const getY = v => padTop + plotH - Math.min(1, Math.max(0, v / maxVal)) * plotH;

  // Área preenchida
  ctx.beginPath();
  ctx.moveTo(getX(0), padTop + plotH);
  for (let i = 0; i < n; i++) {
    ctx.lineTo(getX(i), getY(vals[i]));
  }
  ctx.lineTo(getX(n - 1), padTop + plotH);
  ctx.closePath();
  ctx.fillStyle = fillColor;
  ctx.fill();

  // Linha principal
  ctx.beginPath();
  for (let i = 0; i < n; i++) {
    const x = getX(i);
    const y = getY(vals[i]);
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.strokeStyle = strokeColor;
  ctx.lineWidth = 2;
  ctx.stroke();

  // Destaque do momento selecionado com crosshair e marcador circular
  if (highlightIndex >= 0 && highlightIndex < n) {
    const hx = getX(highlightIndex);
    const hy = getY(vals[highlightIndex]);

    ctx.save();
    // Linha vertical pontilhada (crosshair)
    ctx.setLineDash([4, 4]);
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.45)';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(hx, padTop);
    ctx.lineTo(hx, padTop + plotH);
    ctx.stroke();

    // Halo externo do ponto
    ctx.setLineDash([]);
    ctx.beginPath();
    ctx.arc(hx, hy, 7, 0, Math.PI * 2);
    ctx.fillStyle = 'rgba(255, 255, 255, 0.25)';
    ctx.fill();

    // Ponto central brilhante
    ctx.beginPath();
    ctx.arc(hx, hy, 4.5, 0, Math.PI * 2);
    ctx.fillStyle = strokeColor;
    ctx.fill();
    ctx.strokeStyle = '#ffffff';
    ctx.lineWidth = 2;
    ctx.shadowColor = strokeColor;
    ctx.shadowBlur = 8;
    ctx.stroke();
    ctx.restore();
  } else if (n === 1) {
    // Ponto único se n === 1
    ctx.beginPath();
    ctx.arc(getX(0), getY(vals[0]), 4, 0, Math.PI * 2);
    ctx.fillStyle = strokeColor;
    ctx.fill();
  }

  // Rótulos de data no eixo X
  ctx.fillStyle = '#94a3b8';
  ctx.font = '10px JetBrains Mono, monospace';
  ctx.textAlign = 'left';
  ctx.fillText(formatHistoryDate(points[0][0], true), padLeft, h - 5);
  ctx.textAlign = 'right';
  ctx.fillText(formatHistoryDate(points[n - 1][0], true), w - padRight, h - 5);
}

// ---------------------------------------------------------------------------
// INTERAÇÃO E TOOLTIP FLUTUANTE AO PASSAR O MOUSE SOBRE OS GRÁFICOS
// ---------------------------------------------------------------------------
let historyHoverListenersAttached = false;

function setupHistoryCanvasInteractions() {
  if (historyHoverListenersAttached) return;
  historyHoverListenersAttached = true;

  const canvasIds = ['chart-history-online', 'chart-history-clients', 'chart-history-cpu', 'chart-history-mem'];
  canvasIds.forEach(id => {
    const el = document.getElementById(id);
    if (!el) return;
    el.style.cursor = 'crosshair';

    el.addEventListener('mousemove', (e) => {
      handleHistoryChartHover(e, id);
    });
    el.addEventListener('mouseleave', () => {
      clearHistoryHover();
    });
    el.addEventListener('touchmove', (e) => {
      if (e.touches && e.touches.length > 0) {
        handleHistoryChartHover(e, id);
      }
    }, { passive: true });
    el.addEventListener('touchend', () => {
      clearHistoryHover();
    });
  });
}

function handleHistoryChartHover(e, canvasId) {
  const canvas = document.getElementById(canvasId);
  if (!canvas || !currentHistoryPoints || currentHistoryPoints.length === 0) return;

  const rect = canvas.getBoundingClientRect();
  const clientX = e.clientX !== undefined ? e.clientX : (e.touches && e.touches[0] ? e.touches[0].clientX : 0);
  const clientY = e.clientY !== undefined ? e.clientY : (e.touches && e.touches[0] ? e.touches[0].clientY : 0);
  const canvasX = (clientX - rect.left) * (canvas.width / rect.width);

  let normX = 0;
  if (canvasId === 'chart-history-online') {
    normX = canvasX / canvas.width;
  } else {
    const padLeft = 44;
    const padRight = 14;
    const plotW = canvas.width - padLeft - padRight;
    normX = (canvasX - padLeft) / plotW;
  }

  const n = currentHistoryPoints.length;
  const clampedNorm = Math.max(0, Math.min(1, normX));
  const idx = n <= 1 ? 0 : Math.round(clampedNorm * (n - 1));

  updateHistoryHoverTooltip(idx, clientX, clientY);
  redrawHistoryCharts(idx);
}

function updateHistoryHoverTooltip(idx, clientX, clientY) {
  if (!currentHistoryPoints || !currentHistoryPoints[idx]) return;
  const pt = currentHistoryPoints[idx];
  const isOn = Number(pt[1]) === 1;
  const clients = pt[2];
  const mem = pt[3];
  const cpu = Number(pt[4]).toFixed(2);
  const dateStr = formatHistoryDate(pt[0]);

  const tooltip = document.getElementById('history-hover-tooltip');
  if (tooltip) {
    tooltip.innerHTML = `
      <div class="history-tooltip-title">
        <span>🕒 ${dateStr}</span>
        <span class="badge ${isOn ? 'online' : 'offline'}" style="font-size:10px; padding:2px 6px;">
          ${isOn ? '● Online' : '○ Offline'}
        </span>
      </div>
      <div class="history-tooltip-grid">
        <div class="history-tooltip-row">
          <span class="history-tooltip-label">👥 Clientes:</span>
          <span class="history-tooltip-val" style="color:#34d399;">${isOn ? clients + ' disp.' : '—'}</span>
        </div>
        <div class="history-tooltip-row">
          <span class="history-tooltip-label">⚡ Carga CPU (1m):</span>
          <span class="history-tooltip-val" style="color:#fbbf24;">${isOn ? cpu : '—'}</span>
        </div>
        <div class="history-tooltip-row">
          <span class="history-tooltip-label">🧠 RAM Livre:</span>
          <span class="history-tooltip-val" style="color:#38bdf8;">${isOn && mem ? mem + ' MB' : '—'}</span>
        </div>
      </div>
    `;
    tooltip.style.display = 'block';

    const tipW = 230;
    const tipH = 110;
    let posX = clientX;
    let posY = clientY - 18;

    if (posX - tipW / 2 < 12) posX = tipW / 2 + 12;
    if (posX + tipW / 2 > window.innerWidth - 12) posX = window.innerWidth - tipW / 2 - 12;
    if (posY - tipH < 12) {
      posY = clientY + tipH + 24;
      tooltip.style.transform = 'translate(-50%, 0)';
    } else {
      tooltip.style.transform = 'translate(-50%, -100%)';
    }

    tooltip.style.left = posX + 'px';
    tooltip.style.top = posY + 'px';
  }
}

function clearHistoryHover() {
  const tooltip = document.getElementById('history-hover-tooltip');
  if (tooltip) {
    tooltip.style.display = 'none';
  }
  redrawHistoryCharts(-1);
}

function exportHistoryCsv() {
  if (!currentHistoryPoints || currentHistoryPoints.length === 0) {
    alert('Não há dados no período selecionado para exportar.');
    return;
  }
  const lines = ['timestamp_unix,data_hora,conectado,clientes_conectados,memoria_livre_mb,carga_cpu_1m'];
  currentHistoryPoints.forEach(p => {
    lines.push(`${p[0]},"${formatHistoryDate(p[0])}",${p[1]},${p[2]},${p[3]},${p[4]}`);
  });
  const blob = new Blob([lines.join('\n')], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  const cleanMac = (activeHistoryMac || 'router').replace(/[^0-9A-Fa-f]/g, '');
  a.download = `historico_${cleanMac}_${activeHistoryDays}d.csv`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}

// Inicia conexão WebSocket
window.addEventListener('DOMContentLoaded', connectAdminWs);


// ============================================================================
// AUTENTICAÇÃO, PERFIL E GESTÃO DE USUÁRIOS (RBAC)
// ============================================================================
let currentUser = null;
let sessionHeartbeatTimer = null;
const ROLE_LABELS = { admin: 'Administrador', operator: 'Operador', viewer: 'Visualizador' };

function escUserHtml(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function showToast(text, kind) {
  let box = document.getElementById('toast-box');
  if (!box) {
    box = document.createElement('div');
    box.id = 'toast-box';
    document.body.appendChild(box);
  }
  const el = document.createElement('div');
  el.className = 'toast toast-' + (kind || 'info');
  el.textContent = text;
  box.appendChild(el);
  setTimeout(() => { el.classList.add('toast-out'); setTimeout(() => el.remove(), 350); }, 4200);
}

async function authApi(path, method, body) {
  const resp = await fetch(path, {
    method: method || 'GET',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined
  });
  let data = {};
  try { data = await resp.json(); } catch (_) {}
  if (resp.status === 401) {
    // Sessão expirada/revogada: volta para a tela de login
    location.href = '/dashboard';
    throw new Error('unauthorized');
  }
  return { status: resp.status, data };
}

/** Valida (e renova) a sessão. Retorna false quando o fluxo foi interrompido (login / troca de senha obrigatória). */
async function refreshSession() {
  const resp = await fetch('/api/auth/me', { credentials: 'same-origin' });
  if (resp.status === 401) {
    location.href = '/dashboard';
    return false;
  }
  const data = await resp.json();
  if (!data.ok) throw new Error('me_failed');
  currentUser = data.user;
  applyUserUi();
  if (!sessionHeartbeatTimer) {
    sessionHeartbeatTimer = setInterval(() => { refreshSession().catch(() => {}); }, 10 * 60 * 1000);
  }
  if (currentUser.must_change) {
    openChangePasswordModal(true);
    return false;
  }
  return true;
}

function applyUserUi() {
  if (!currentUser) return;
  document.body.classList.remove('role-viewer', 'role-operator', 'role-admin');
  document.body.classList.add('role-' + currentUser.role);
  const nameEl = document.getElementById('user-name');
  const roleEl = document.getElementById('user-role');
  const avatar = document.getElementById('user-avatar');
  if (nameEl) nameEl.textContent = currentUser.name || currentUser.username;
  if (roleEl) roleEl.textContent = ROLE_LABELS[currentUser.role] || currentUser.role;
  if (avatar) avatar.textContent = (currentUser.name || currentUser.username || '?').trim().charAt(0).toUpperCase();
  const menuUsers = document.getElementById('menu-users');
  if (menuUsers) menuUsers.style.display = currentUser.role === 'admin' ? 'flex' : 'none';
}

function toggleUserMenu(ev) {
  if (ev) ev.stopPropagation();
  document.getElementById('user-dropdown').classList.toggle('open');
}
document.addEventListener('click', () => {
  const dd = document.getElementById('user-dropdown');
  if (dd) dd.classList.remove('open');
});

async function logout() {
  try { await fetch('/api/auth/logout', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json' }, body: '{}' }); } catch (_) {}
  try {
    Object.keys(localStorage).filter(k => k.startsWith('floresta_')).forEach(k => localStorage.removeItem(k));
  } catch (_) {}
  location.href = '/dashboard';
}

// ---------------- Alterar senha ----------------
let passwordModalForced = false;

function openChangePasswordModal(forced) {
  passwordModalForced = !!forced;
  document.getElementById('pw-current').value = '';
  document.getElementById('pw-new').value = '';
  document.getElementById('pw-confirm').value = '';
  document.getElementById('pw-error').textContent = '';
  document.getElementById('pw-forced-note').style.display = forced ? 'block' : 'none';
  document.getElementById('pw-close-btn').style.display = forced ? 'none' : '';
  document.getElementById('pw-cancel-btn').style.display = forced ? 'none' : '';
  document.getElementById('modal-password').classList.add('open');
  setTimeout(() => document.getElementById('pw-current').focus(), 50);
}

function closeChangePasswordModal() {
  if (passwordModalForced) return;
  document.getElementById('modal-password').classList.remove('open');
}

async function submitChangePassword(ev) {
  ev.preventDefault();
  const errEl = document.getElementById('pw-error');
  errEl.textContent = '';
  const cur = document.getElementById('pw-current').value;
  const nw = document.getElementById('pw-new').value;
  const cf = document.getElementById('pw-confirm').value;
  if (nw !== cf) { errEl.textContent = 'A confirmação não confere com a nova senha.'; return; }
  const { data } = await authApi('/api/auth/change-password', 'POST', { current_password: cur, new_password: nw });
  if (!data.ok) { errEl.textContent = data.error || 'Falha ao alterar a senha.'; return; }
  showToast('Senha alterada com sucesso.', 'success');
  passwordModalForced = false;
  document.getElementById('modal-password').classList.remove('open');
  if (currentUser && currentUser.must_change) { location.reload(); }
}

// ---------------- CRUD de usuários (administrador) ----------------
let usersCache = [];
let editingUser = null;

async function openUsersModal() {
  document.getElementById('modal-users').classList.add('open');
  resetUserForm();
  await loadUsers();
}

function closeUsersModal() {
  document.getElementById('modal-users').classList.remove('open');
}

async function loadUsers() {
  const wrap = document.getElementById('users-table-wrap');
  wrap.textContent = 'Carregando...';
  const { status, data } = await authApi('/api/users', 'GET');
  if (!data.ok) { wrap.textContent = data.error || ('Erro ' + status); return; }
  usersCache = data.users || [];
  renderUsersTable();
}

function fmtUserDate(ts) {
  if (!ts) return '—';
  return new Date(ts * 1000).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' });
}

function renderUsersTable() {
  const wrap = document.getElementById('users-table-wrap');
  const rows = usersCache.map(u => {
    const self = currentUser && u.username === currentUser.username;
    const status = u.active ? '<span class="u-status on">Ativo</span>' : '<span class="u-status off">Inativo</span>';
    const flag = u.must_change ? ' <span class="u-flag" title="Precisa trocar a senha no próximo login">🔑 troca pendente</span>' : '';
    return `<tr>
      <td><strong>${escUserHtml(u.username)}</strong>${self ? ' <span class="u-flag">você</span>' : ''}<div class="u-sub">${escUserHtml(u.name)}</div></td>
      <td><span class="role-badge role-badge-${escUserHtml(u.role)}">${escUserHtml(ROLE_LABELS[u.role] || u.role)}</span></td>
      <td>${status}${flag}</td>
      <td class="u-sub">${fmtUserDate(u.last_login)}</td>
      <td class="u-actions">
        <button class="btn" onclick="editUser('${escUserHtml(u.username)}')">✏️ Editar</button>
        ${self ? '' : `<button class="btn btn-danger" onclick="deleteUser('${escUserHtml(u.username)}')">🗑️</button>`}
      </td>
    </tr>`;
  }).join('');
  wrap.innerHTML = `<table class="u-table"><thead><tr><th>Usuário</th><th>Perfil</th><th>Situação</th><th>Último acesso</th><th></th></tr></thead><tbody>${rows}</tbody></table>`;
}

function resetUserForm() {
  editingUser = null;
  const f = document.getElementById('user-form');
  f.reset();
  document.getElementById('uf-username').disabled = false;
  document.getElementById('uf-title').textContent = '➕ Novo usuário';
  document.getElementById('uf-pw-label').textContent = 'Senha temporária';
  document.getElementById('uf-active-row').style.display = 'none';
  document.getElementById('uf-must-row').style.display = 'flex';
  document.getElementById('uf-must').checked = true;
  document.getElementById('uf-cancel').style.display = 'none';
  document.getElementById('uf-error').textContent = '';
  document.getElementById('uf-submit').textContent = 'Criar usuário';
}

function editUser(username) {
  const u = usersCache.find(x => x.username === username);
  if (!u) return;
  editingUser = username;
  document.getElementById('uf-username').value = u.username;
  document.getElementById('uf-username').disabled = true;
  document.getElementById('uf-name').value = u.name || '';
  document.getElementById('uf-role').value = u.role;
  document.getElementById('uf-password').value = '';
  document.getElementById('uf-title').textContent = '✏️ Editar: ' + u.username;
  document.getElementById('uf-pw-label').textContent = 'Nova senha (deixe em branco para manter)';
  document.getElementById('uf-active-row').style.display = 'flex';
  document.getElementById('uf-active').checked = !!u.active;
  document.getElementById('uf-must-row').style.display = 'none';
  document.getElementById('uf-cancel').style.display = '';
  document.getElementById('uf-error').textContent = '';
  document.getElementById('uf-submit').textContent = 'Salvar alterações';
  const self = currentUser && currentUser.username === u.username;
  document.getElementById('uf-role').disabled = !!self;
  document.getElementById('uf-active').disabled = !!self;
}

async function submitUserForm(ev) {
  ev.preventDefault();
  const errEl = document.getElementById('uf-error');
  errEl.textContent = '';
  const payload = {
    name: document.getElementById('uf-name').value.trim(),
    role: document.getElementById('uf-role').value
  };
  const pw = document.getElementById('uf-password').value;
  let res;
  if (editingUser) {
    payload.active = document.getElementById('uf-active').checked;
    if (pw) payload.password = pw;
    res = await authApi('/api/users/' + encodeURIComponent(editingUser), 'PUT', payload);
  } else {
    payload.username = document.getElementById('uf-username').value.trim().toLowerCase();
    payload.password = pw;
    payload.must_change = document.getElementById('uf-must').checked;
    res = await authApi('/api/users', 'POST', payload);
  }
  if (!res.data.ok) { errEl.textContent = res.data.error || 'Falha ao salvar.'; return; }
  showToast(editingUser ? 'Usuário atualizado.' : 'Usuário criado.', 'success');
  document.getElementById('uf-role').disabled = false;
  document.getElementById('uf-active').disabled = false;
  resetUserForm();
  await loadUsers();
}

function cancelUserEdit() {
  document.getElementById('uf-role').disabled = false;
  document.getElementById('uf-active').disabled = false;
  resetUserForm();
}

async function deleteUser(username) {
  if (!confirm(`Excluir o usuário "${username}"? Esta ação não pode ser desfeita.`)) return;
  const { data } = await authApi('/api/users/' + encodeURIComponent(username), 'DELETE');
  if (!data.ok) { showToast(data.error || 'Falha ao excluir.', 'error'); return; }
  showToast('Usuário excluído.', 'success');
  if (editingUser === username) resetUserForm();
  await loadUsers();
}
