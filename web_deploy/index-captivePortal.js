import { d as defineComponent, r as ref, a as onMounted, aj as onUnmounted, h } from "./vendor-D1pHNSFl.js";

const API_BASE = "/cgi-bin/captive_admin_api";

export default defineComponent({
  name: "CaptivePortalView",
  setup() {
    const getTabFromHash = () => {
      const h = window.location.hash || "";
      if (h.includes("cloudController")) return "cloud";
      if (h.includes("qos")) return "qos";
      return "portal";
    };
    const activeTab = ref(getTabFromHash()); // "portal", "qos", "cloud"
    const service = ref({ running: false, uptime: "---", auth_count: 0, qos_enabled: false, router_ip: "192.168.0.1" });
    const sessions = ref([]);
    const whitelist = ref([]);
    const profiles = ref([]);
    const cloudConfig = ref({
      server_url: "https://<CONTROLLER_HOST>/ws/router",
      server_host: "<CONTROLLER_HOST>",
      server_port: 443,
      device_name: "Archer BE220 - Polo 1",
      running: false
    });
    const loading = ref(false);
    const actionMsg = ref("");
    const actionType = ref("info");
    const newDomain = ref("");
    let pollTimer = null;

    const setNotice = (msg, type = "info") => {
      actionMsg.value = msg;
      actionType.value = type;
      setTimeout(() => { if (actionMsg.value === msg) actionMsg.value = ""; }, 4000);
    };

    const fetchStatus = async () => {
      try {
        const res = await fetch(`${API_BASE}?action=status`, { cache: "no-store" });
        if (res.ok) {
          const text = await res.text();
          if (text && text.trim().startsWith("{")) {
            const data = JSON.parse(text);
            if (data && data.ok) {
              service.value = data.service || {};
              sessions.value = data.sessions || [];
            }
          }
        }
      } catch (e) {
        console.warn("Aviso ao obter status do captive portal:", e);
      }
    };

    const fetchWhitelist = async () => {
      try {
        const res = await fetch(`${API_BASE}?action=whitelist`, { cache: "no-store" });
        if (res.ok) {
          const text = await res.text();
          if (text && text.trim().startsWith("{")) {
            const data = JSON.parse(text);
            if (data && data.ok && Array.isArray(data.domains)) {
              whitelist.value = data.domains;
            }
          }
        }
      } catch (e) {
        console.warn("Aviso ao obter whitelist:", e);
      }
    };

    const fetchProfiles = async () => {
      try {
        const res = await fetch(`${API_BASE}?action=profiles`, { cache: "no-store" });
        if (res.ok) {
          const text = await res.text();
          if (text && text.trim().startsWith("{")) {
            const data = JSON.parse(text);
            if (data && data.ok && Array.isArray(data.profiles)) {
              profiles.value = data.profiles.map(p => ({
                ...p,
                dl_mbps: p.dl_kbit ? (p.dl_kbit / 1024).toFixed(1) : "0",
                ul_mbps: p.ul_kbit ? (p.ul_kbit / 1024).toFixed(1) : "0"
              }));
            }
          }
        }
      } catch (e) {
        console.warn("Aviso ao carregar perfis QoS:", e);
      }
    };

    const fetchCloudConfig = async () => {
      try {
        const res = await fetch(`${API_BASE}?action=get_cloud_config`, { cache: "no-store" });
        if (res.ok) {
          const text = await res.text();
          if (text && text.trim().startsWith("{")) {
            const data = JSON.parse(text);
            if (data && data.ok) {
              const cleanUrl = (data.server_url || "https://<CONTROLLER_HOST>/ws/router")
                .replace(/^wss:\/\//i, "https://")
                .replace(/^ws:\/\//i, "http://");
              cloudConfig.value = {
                server_url: cleanUrl,
                server_host: data.server_host || "<CONTROLLER_HOST>",
                server_port: data.server_port || 443,
                device_name: data.device_name || "Archer BE220 - Polo 1",
                running: !!data.running
              };
              const urlInput = document.getElementById("cp-cloud-url");
              const nameInput = document.getElementById("cp-cloud-name");
              if (urlInput && document.activeElement !== urlInput) {
                urlInput.value = cleanUrl;
              }
              if (nameInput && document.activeElement !== nameInput) {
                nameInput.value = cloudConfig.value.device_name;
              }
            }
          }
        }
      } catch (e) {
        console.warn("Aviso ao carregar configuracoes de cloud:", e);
      }
    };

    const saveCloudConfig = async () => {
      const urlInput = document.getElementById("cp-cloud-url");
      const nameInput = document.getElementById("cp-cloud-name");
      let newUrl = urlInput ? urlInput.value.trim() : cloudConfig.value.server_url;
      // NUNCA force wss://: Converte automaticamente se digitado ou colado com wss://
      newUrl = newUrl.replace(/^wss:\/\//i, "https://").replace(/^ws:\/\//i, "http://");
      const newName = nameInput ? nameInput.value.trim() : cloudConfig.value.device_name;

      if (!newUrl) {
        setNotice("A URL do Cloud Controller é obrigatória!", "error");
        return;
      }

      try {
        setNotice("Salvando e conectando ao Cloud Controller...", "info");
        const res = await fetch(`${API_BASE}?action=set_cloud_config&server_url=${encodeURIComponent(newUrl)}&device_name=${encodeURIComponent(newName)}`, {
          method: "POST"
        });
        const data = await res.json();
        if (data.ok) {
          setNotice("Configuração salva com sucesso! Agente reconectado.", "success");
          cloudConfig.value.server_url = newUrl;
          cloudConfig.value.device_name = newName;
          cloudConfig.value.running = true;
          if (urlInput) urlInput.value = newUrl;
          if (nameInput) nameInput.value = newName;
          await fetchCloudConfig();
        } else {
          setNotice(data.error || "Erro ao salvar", "error");
        }
      } catch (e) {
        setNotice("Falha ao salvar configuração na nuvem", "error");
      }
    };

    const saveProfile = async (p) => {
      const dlInput = document.getElementById(`cp-prof-dl-${p.id}`);
      const ulInput = document.getElementById(`cp-prof-ul-${p.id}`);
      const dlKbit = dlInput ? Math.round(parseFloat(dlInput.value || 0) * 1024) : p.dl_kbit;
      const ulKbit = ulInput ? Math.round(parseFloat(ulInput.value || 0) * 1024) : p.ul_kbit;

      try {
        setNotice(`Salvando perfil '${p.name}'...`, "info");
        const res = await fetch(`${API_BASE}?action=profile_update&id=${encodeURIComponent(p.id)}&dl_kbit=${dlKbit}&ul_kbit=${ulKbit}`, {
          method: "POST"
        });
        const data = await res.json();
        if (data.ok) {
          setNotice(`Perfil '${p.name}' atualizado com sucesso!`, "success");
          fetchProfiles();
        } else {
          setNotice(data.error || "Erro ao salvar perfil", "error");
        }
      } catch (e) {
        setNotice("Falha ao salvar perfil", "error");
      }
    };

    const toggleQoS = async () => {
      const targetState = service.value.qos_enabled ? "0" : "1";
      try {
        setNotice(service.value.qos_enabled ? "Desativando QoS..." : "Ativando QoS...", "info");
        const res = await fetch(`${API_BASE}?action=qos_toggle&enabled=${targetState}`, { method: "POST" });
        const data = await res.json();
        if (data.ok) {
          setNotice(data.message || (targetState === "1" ? "QoS ativado!" : "QoS desativado!"), "success");
          fetchStatus();
        } else {
          setNotice(data.error || "Erro ao alterar QoS", "error");
        }
      } catch (e) {
        setNotice("Falha na comunicação com o roteador", "error");
      }
    };

    const refreshAll = async () => {
      loading.value = true;
      await Promise.all([fetchStatus(), fetchWhitelist(), fetchProfiles(), fetchCloudConfig()]);
      loading.value = false;
    };

    const kickClient = async (ip) => {
      if (!confirm(`Deseja realmente desconectar o cliente ${ip}?`)) return;
      try {
        const res = await fetch(`${API_BASE}?action=kick&ip=${encodeURIComponent(ip)}`, { method: "POST" });
        const data = await res.json();
        if (data.ok) {
          setNotice(`Cliente ${ip} desconectado com sucesso!`, "success");
          fetchStatus();
        } else {
          setNotice(data.error || "Erro ao desconectar cliente", "error");
        }
      } catch (e) {
        setNotice("Falha na comunicação com o roteador", "error");
      }
    };

    const flushClients = async () => {
      if (!confirm("ATENÇÃO: Deseja desconectar TODOS os clientes autenticados? Eles precisarão fazer login novamente.")) return;
      try {
        const res = await fetch(`${API_BASE}?action=flush`, { method: "POST" });
        const data = await res.json();
        if (data.ok) {
          setNotice("Todos os clientes foram desconectados!", "success");
          fetchStatus();
        } else {
          setNotice(data.error || "Erro ao desconectar clientes", "error");
        }
      } catch (e) {
        setNotice("Falha na comunicação com o roteador", "error");
      }
    };

    const restartService = async () => {
      try {
        setNotice("Reiniciando serviço do portal captivo...", "info");
        const res = await fetch(`${API_BASE}?action=service_restart`, { method: "POST" });
        const data = await res.json();
        if (data.ok) {
          setNotice("Serviço reiniciado com sucesso!", "success");
          setTimeout(refreshAll, 1500);
        } else {
          setNotice(data.error || "Erro ao reiniciar serviço", "error");
        }
      } catch (e) {
        setNotice("Falha ao solicitar reinício do serviço", "error");
      }
    };

    const addDomain = async () => {
      const inputEl = document.getElementById("cp-new-domain-input");
      const d = (inputEl && inputEl.value ? inputEl.value : newDomain.value || "").trim().toLowerCase();
      if (!d) {
        setNotice("Por favor, digite um domínio válido (ex: www.site.com.br)", "info");
        return;
      }
      try {
        const res = await fetch(`${API_BASE}?action=whitelist_add&domain=${encodeURIComponent(d)}`, { method: "POST" });
        const data = await res.json();
        if (data.ok) {
          newDomain.value = "";
          if (inputEl) inputEl.value = "";
          setNotice(`Domínio '${d}' liberado no Walled Garden!`, "success");
          fetchWhitelist();
        } else {
          setNotice(data.error || "Erro ao adicionar domínio", "error");
        }
      } catch (e) {
        setNotice("Falha ao salvar domínio", "error");
      }
    };

    const removeDomain = async (d) => {
      if (!confirm(`Remover '${d}' do Walled Garden?`)) return;
      try {
        const res = await fetch(`${API_BASE}?action=whitelist_del&domain=${encodeURIComponent(d)}`, { method: "POST" });
        const data = await res.json();
        if (data.ok) {
          setNotice(`Domínio '${d}' removido.`, "info");
          fetchWhitelist();
        } else {
          setNotice(data.error || "Erro ao remover domínio", "error");
        }
      } catch (e) {
        setNotice("Falha ao remover domínio", "error");
      }
    };

    const onHashChange = () => {
      activeTab.value = getTabFromHash();
      if (activeTab.value === "cloud") fetchCloudConfig();
    };

    onMounted(() => {
      refreshAll();
      pollTimer = setInterval(fetchStatus, 5000);
      window.addEventListener("hashchange", onHashChange);
    });

    onUnmounted(() => {
      if (pollTimer) clearInterval(pollTimer);
      window.removeEventListener("hashchange", onHashChange);
    });

    return () => h("div", { class: "cp-container", style: "padding:20px; font-family:-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif;" }, [
      h("style", null, `
        .cp-card { background:#fff; border-radius:8px; box-shadow:0 1px 3px rgba(0,0,0,0.06); margin-bottom:20px; padding:20px; border:1px solid #e2e8f0; }
        .cp-card-head { display:flex; justify-content:space-between; align-items:center; margin-bottom:16px; }
        .cp-card-title { font-size:16px; font-weight:600; color:#1e293b; display:flex; align-items:center; gap:8px; }
        .cp-btn { padding:6px 14px; font-size:13px; font-weight:500; border-radius:6px; cursor:pointer; border:1px solid transparent; transition:all .15s; }
        .cp-btn-primary { background:#0284c7; color:#fff; border-color:#0284c7; }
        .cp-btn-primary:hover { background:#0369a1; }
        .cp-btn-danger { background:#ef4444; color:#fff; }
        .cp-btn-danger:hover { background:#dc2626; }
        .cp-btn-default { background:#f8fafc; color:#334155; border-color:#cbd5e1; }
        .cp-btn-default:hover { background:#f1f5f9; }
        .cp-btn-sm { padding:4px 10px; font-size:12px; }
        .cp-badge-online { display:inline-flex; align-items:center; gap:5px; background:#e6fcf5; color:#0ca678; padding:3px 8px; border-radius:12px; font-size:12px; font-weight:600; }
        .cp-badge-offline { display:inline-flex; align-items:center; gap:5px; background:#fff5f5; color:#fa5252; padding:3px 8px; border-radius:12px; font-size:12px; font-weight:600; }
        .cp-dot { width:8px; height:8px; border-radius:50%; background:currentColor; }
        .cp-grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(200px, 1fr)); gap:16px; margin-top:14px; }
        .cp-stat { background:#f8fafc; border:1px solid #edf2f7; border-radius:8px; padding:12px 16px; }
        .cp-stat-lbl { font-size:12px; color:#64748b; margin-bottom:4px; font-weight:500; }
        .cp-stat-val { font-size:18px; font-weight:700; color:#0f172a; }
        .cp-table { width:100%; border-collapse:collapse; text-align:left; font-size:13px; }
        .cp-table th { background:#f8fafc; color:#475569; font-weight:600; padding:10px 14px; border-bottom:1px solid #e2e8f0; }
        .cp-table td { padding:10px 14px; border-bottom:1px solid #f1f5f9; vertical-align:middle; }
        .cp-chip { display:inline-flex; align-items:center; gap:6px; background:#f1f5f9; color:#334155; border:1px solid #cbd5e1; border-radius:14px; padding:3px 10px; font-size:12px; }
        .cp-chip-del { cursor:pointer; color:#94a3b8; font-weight:bold; }
        .cp-chip-del:hover { color:#ef4444; }
        .cp-notice { padding:10px 14px; border-radius:6px; margin-bottom:16px; font-size:13px; font-weight:500; }
        .cp-notice-success { background:#e6fcf5; color:#0ca678; border:1px solid #c3fae8; }
        .cp-notice-error { background:#fff5f5; color:#fa5252; border:1px solid #ffe3e3; }
        .cp-notice-info { background:#f0f9ff; color:#0284c7; border:1px solid #e0f2fe; }
        .cp-empty { text-align:center; padding:30px; color:#94a3b8; font-size:13px; }
        .cp-input { width:100%; padding:9px 12px; border:1px solid #cbd5e1; border-radius:6px; font-size:13px; outline:none; transition:border .15s; }
        .cp-input:focus { border-color:#0284c7; box-shadow:0 0 0 2px rgba(2,132,199,0.15); }
      `),

      // Mensagem de notificação flutuante
      actionMsg.value ? h("div", { class: `cp-notice cp-notice-${actionType.value}` }, actionMsg.value) : null,

      // BARRA DE SUB-ABAS (NAVEGADOR SUPERIOR)
      h("div", { style: "display:flex; gap:10px; margin-bottom:20px; border-bottom:1px solid #e2e8f0; padding-bottom:12px;" }, [
        h("button", {
          class: `cp-btn ${activeTab.value === 'portal' ? 'cp-btn-primary' : 'cp-btn-default'}`,
          onClick: () => { activeTab.value = 'portal'; }
        }, "📋 Portal Captivo & Clientes"),
        h("button", {
          class: `cp-btn ${activeTab.value === 'qos' ? 'cp-btn-primary' : 'cp-btn-default'}`,
          onClick: () => { activeTab.value = 'qos'; }
        }, "⚡ Controle de QoS (Banda)"),
        h("button", {
          class: `cp-btn ${activeTab.value === 'cloud' ? 'cp-btn-primary' : 'cp-btn-default'}`,
          onClick: () => { activeTab.value = 'cloud'; fetchCloudConfig(); },
          style: "display:inline-flex; align-items:center; gap:8px;"
        }, [
          h("span", null, "☁️ Cloud Controller (Frota UniFi)"),
          cloudConfig.value.running
            ? h("span", { style: "display:inline-block; width:8px; height:8px; border-radius:50%; background:#0ca678;" })
            : h("span", { style: "display:inline-block; width:8px; height:8px; border-radius:50%; background:#ef4444;" })
        ])
      ]),

      // =====================================================================
      // ABA 1: PORTAL CAPTIVO & CLIENTES
      // =====================================================================
      activeTab.value === 'portal' ? [
        // CARD 1: Status do Serviço
        h("div", { class: "cp-card" }, [
          h("div", { class: "cp-card-head" }, [
            h("div", { class: "cp-card-title" }, [
              h("span", null, "Status do Serviço"),
              service.value.running
                ? h("span", { class: "cp-badge-online" }, [h("span", { class: "cp-dot" }), "Ativo / Em Execução"])
                : h("span", { class: "cp-badge-offline" }, [h("span", { class: "cp-dot" }), "Inativo"])
            ]),
            h("div", { style: "display:flex; gap:8px;" }, [
              h("button", { class: "cp-btn cp-btn-default", onClick: refreshAll, disabled: loading.value }, [
                loading.value ? "Atualizando..." : "🔄 Atualizar"
              ]),
              h("button", { class: "cp-btn cp-btn-default", onClick: restartService }, "⚡ Reiniciar Serviço")
            ])
          ]),

          // Estatísticas Rápidas
          h("div", { class: "cp-grid" }, [
            h("div", { class: "cp-stat" }, [
              h("div", { class: "cp-stat-lbl" }, "Clientes Conectados"),
              h("div", { class: "cp-stat-val", style: "color:#0284c7;" }, sessions.value.length)
            ]),
            h("div", { class: "cp-stat" }, [
              h("div", { class: "cp-stat-lbl" }, "Tempo de Atividade (Uptime)"),
              h("div", { class: "cp-stat-val" }, service.value.uptime || "---")
            ]),
            h("div", { class: "cp-stat", style: "cursor:pointer; transition:background .15s;", onClick: toggleQoS, title: "Clique para alternar QoS" }, [
              h("div", { class: "cp-stat-lbl", style: "display:flex; justify-content:space-between; align-items:center;" }, [
                h("span", null, "Controle de Banda (QoS)"),
                h("span", { style: "color:#0284c7; font-size:11px; font-weight:600; text-decoration:underline;" }, "Alternar")
              ]),
              h("div", { class: "cp-stat-val", style: service.value.qos_enabled ? "color:#0ca678;" : "color:#f59e0b;" },
                service.value.qos_enabled ? "Habilitado" : "Desabilitado"
              )
            ]),
            h("div", { class: "cp-stat", style: "cursor:pointer;", onClick: () => { activeTab.value = 'cloud'; fetchCloudConfig(); } }, [
              h("div", { class: "cp-stat-lbl", style: "display:flex; justify-content:space-between;" }, [
                h("span", null, "Gestão de Frota Cloud"),
                h("span", { style: "color:#0284c7; font-size:11px; font-weight:600; text-decoration:underline;" }, "Configurar")
              ]),
              h("div", { class: "cp-stat-val", style: cloudConfig.value.running ? "color:#0ca678; font-size:15px;" : "color:#ef4444; font-size:15px;" },
                cloudConfig.value.running ? "🟢 Nuvem Conectada" : "🔴 Nuvem Desconectada"
              )
            ])
          ])
        ]),

        // CARD 2: Clientes Conectados (Sessões Ativas)
        h("div", { class: "cp-card" }, [
          h("div", { class: "cp-card-head" }, [
            h("div", { class: "cp-card-title" }, `Clientes Conectados Agora (${sessions.value.length})`),
            sessions.value.length > 0 ? h("button", { class: "cp-btn cp-btn-danger cp-btn-sm", onClick: flushClients }, "⚠️ Desconectar Todos") : null
          ]),

          sessions.value.length === 0
            ? h("div", { class: "cp-empty" }, "Nenhum cliente conectado ou autenticado no momento.")
            : h("table", { class: "cp-table" }, [
              h("thead", null, [
                h("tr", null, [
                  h("th", null, "Dispositivo (IP / MAC)"),
                  h("th", null, "Usuário Autenticado"),
                  h("th", null, "Perfil & QoS"),
                  h("th", null, "Tempo Restante"),
                  h("th", { style: "text-align:right;" }, "Ação")
                ])
              ]),
              h("tbody", null, sessions.value.map(s => h("tr", { key: s.ip || s.mac }, [
                h("td", null, [
                  h("div", { style: "font-weight:600; color:#0f172a;" }, s.ip || "---"),
                  h("div", { style: "font-family:monospace; font-size:11px; color:#64748b;" }, s.mac || "---")
                ]),
                h("td", null, [
                  h("div", { style: "font-weight:500;" }, s.user || "Visitante"),
                  s.email && s.email !== s.user ? h("div", { style: "font-size:11px; color:#64748b;" }, s.email) : null
                ]),
                h("td", null, [
                  h("span", { class: "cp-chip", style: "background:#e0f2fe; color:#0369a1; border-color:#bae6fd; font-weight:600;" }, s.profile || "Visitante"),
                  h("div", { style: "font-size:11px; color:#64748b; margin-top:2px;" },
                    s.dl_kbit && s.dl_kbit > 0
                      ? `⬇ ${(s.dl_kbit / 1024).toFixed(1)}M / ⬆ ${(s.ul_kbit / 1024).toFixed(1)}M`
                      : "⬇ ⬆ Ilimitado"
                  )
                ]),
                h("td", null, [
                  h("div", { style: "font-weight:500;" }, s.remaining_str || (s.remaining ? `${Math.round(s.remaining / 60)} min` : "Ativo")),
                  h("div", { style: "font-size:11px; color:#0ca678;" }, "Auto-renovável")
                ]),
                h("td", { style: "text-align:right;" }, [
                  h("button", { class: "cp-btn cp-btn-danger cp-btn-sm", onClick: () => kickClient(s.ip) }, "Desconectar")
                ])
              ])))
            ])
        ]),

        // CARD 4: Walled Garden (Lista de Permissões sem Login)
        h("div", { class: "cp-card" }, [
          h("div", { class: "cp-card-head" }, [
            h("div", { class: "cp-card-title" }, "Walled Garden (Acesso sem Autenticação)"),
            h("span", { style: "font-size:12px; color:#64748b;" }, `${whitelist.value.length} domínios autorizados`)
          ]),
          h("p", { style: "font-size:13px; color:#64748b; margin-bottom:14px;" },
            "Dispositivos não autenticados podem acessar livremente os domínios listados abaixo (ex: WhatsApp, bancos, portais governamentais)."
          ),

          // Campo para adicionar novo domínio
          h("div", { style: "display:flex; gap:8px; margin-bottom:16px;" }, [
            h("input", {
              id: "cp-new-domain-input",
              type: "text",
              placeholder: "Ex: www.meusite.com.br ou .whatsapp.net",
              value: newDomain.value,
              onInput: (e) => { newDomain.value = e.target.value; },
              onKeydown: (e) => { if (e.key === "Enter") addDomain(); },
              style: "flex:1; padding:8px 12px; border:1px solid #cbd5e1; border-radius:6px; font-size:13px;"
            }),
            h("button", { class: "cp-btn cp-btn-primary", onClick: addDomain }, "➕ Adicionar Domínio")
          ]),

          // Lista de chips de domínios
          h("div", { style: "display:flex; flex-wrap:wrap; gap:4px; max-height:220px; overflow-y:auto; padding:6px 0;" },
            whitelist.value.map(d => h("span", { class: "cp-chip", key: d }, [
              h("span", null, d),
              h("span", { class: "cp-chip-del", title: "Remover domínio", onClick: () => removeDomain(d) }, "✕")
            ]))
          )
        ]),

        // CARD 5: Atalhos Úteis
        h("div", { class: "cp-card" }, [
          h("div", { class: "cp-card-head" }, [
            h("div", { class: "cp-card-title" }, "Atalhos & Informações do Sistema")
          ]),
          h("div", { style: "display:flex; flex-direction:column; gap:10px; font-size:13px; color:#475569;" }, [
            h("div", null, [
              h("strong", null, "Visualizar Tela de Login do Usuário: "),
              h("a", {
                href: "https://roteador.conexaopovosdafloresta.org.br/captive/",
                target: "_blank",
                style: "color:#0284c7; text-decoration:underline;"
              }, "Abrir Tela de Login do Portal Captivo ↗")
            ]),
            h("div", null, [
              h("strong", null, "Tempo Limite de Sessão: "),
              h("span", null, "60 minutos (renovável automaticamente conforme atividade)")
            ])
          ])
        ])
      ] : null,

      // =====================================================================
      // ABA 2: CONTROLE DE QOS (BANDA)
      // =====================================================================
      activeTab.value === 'qos' ? [
        h("div", { class: "cp-card" }, [
          h("div", { class: "cp-card-head" }, [
            h("div", { class: "cp-card-title" }, [
              h("span", null, "Perfis de Velocidade & Limites de Banda (QoS)"),
              service.value.qos_enabled
                ? h("span", { class: "cp-badge-online", style: "font-size:11px;" }, "Ativo")
                : h("span", { class: "cp-badge-offline", style: "font-size:11px;" }, "Desativado (Livre)")
            ]),
            h("div", { style: "display:flex; gap:8px;" }, [
              h("button", {
                class: service.value.qos_enabled ? "cp-btn cp-btn-danger cp-btn-sm" : "cp-btn cp-btn-primary cp-btn-sm",
                onClick: toggleQoS
              }, service.value.qos_enabled ? "⏹ Desligar QoS" : "⚡ Ligar QoS"),
              h("button", { class: "cp-btn cp-btn-default cp-btn-sm", onClick: fetchProfiles }, "🔄 Atualizar Perfis")
            ])
          ]),
          h("p", { style: "font-size:13px; color:#64748b; margin-bottom:14px;" },
            "Ajuste os limites máximos de Download e Upload para cada categoria de usuário. Digite 0 para largura de banda total (sem limite)."
          ),
          h("table", { class: "cp-table" }, [
            h("thead", null, [
              h("tr", null, [
                h("th", null, "Perfil"),
                h("th", null, "Download Máx (Mbps)"),
                h("th", null, "Upload Máx (Mbps)"),
                h("th", null, "Marcação"),
                h("th", { style: "text-align:right;" }, "Ação")
              ])
            ]),
            h("tbody", null, profiles.value.map(p => h("tr", { key: p.id }, [
              h("td", null, [
                h("div", { style: "font-weight:600; color:#0f172a;" }, p.name),
                h("div", { style: "font-size:11px; color:#64748b;" }, `ID: ${p.id}`)
              ]),
              h("td", null, h("div", { style: "display:flex; align-items:center; gap:4px;" }, [
                h("input", {
                  id: `cp-prof-dl-${p.id}`,
                  type: "number",
                  step: "0.5",
                  min: "0",
                  defaultValue: p.dl_mbps,
                  style: "width:80px; padding:4px 8px; border:1px solid #cbd5e1; border-radius:4px; font-size:13px;"
                }),
                h("span", { style: "font-size:12px; color:#64748b;" }, "Mbps")
              ])),
              h("td", null, h("div", { style: "display:flex; align-items:center; gap:4px;" }, [
                h("input", {
                  id: `cp-prof-ul-${p.id}`,
                  type: "number",
                  step: "0.5",
                  min: "0",
                  defaultValue: p.ul_mbps,
                  style: "width:80px; padding:4px 8px; border:1px solid #cbd5e1; border-radius:4px; font-size:13px;"
                }),
                h("span", { style: "font-size:12px; color:#64748b;" }, "Mbps")
              ])),
              h("td", null, h("span", { style: "font-family:monospace; font-size:12px; background:#f1f5f9; padding:2px 6px; border-radius:4px;" }, `fwmark ${p.fwmark}`)),
              h("td", { style: "text-align:right;" }, [
                h("button", { class: "cp-btn cp-btn-primary cp-btn-sm", onClick: () => saveProfile(p) }, "💾 Salvar")
              ])
            ])))
          ])
        ])
      ] : null,

      // =====================================================================
      // ABA 3: CLOUD CONTROLLER (GESTÃO DE FROTA ESTILO UNIFI)
      // =====================================================================
      activeTab.value === 'cloud' ? [
        h("div", { class: "cp-card" }, [
          h("div", { class: "cp-card-head" }, [
            h("div", { class: "cp-card-title" }, [
              h("span", null, "☁️ Conexão com o Cloud Controller (Gestão de Frota)"),
              cloudConfig.value.running
                ? h("span", { class: "cp-badge-online" }, [h("span", { class: "cp-dot" }), "Conectado / Em Execução"])
                : h("span", { class: "cp-badge-offline" }, [h("span", { class: "cp-dot" }), "Desconectado"])
            ]),
            h("div", { style: "display:flex; gap:8px;" }, [
              h("button", { class: "cp-btn cp-btn-default cp-btn-sm", onClick: fetchCloudConfig }, "🔄 Atualizar Status")
            ])
          ]),

          h("p", { style: "font-size:13px; color:#64748b; line-height:1.5; margin-bottom:18px;" },
            "Configure a URL do servidor central de gerenciamento de frota. O roteador fará uma conexão de saída segura (Outbound WebSocket), permitindo controle remoto, telemetria em tempo real e Web SSH mesmo atrás de Starlink, CGNAT ou 4G, sem precisar de VPN."
          ),

          // Formulário de Configuração
          h("div", { style: "display:flex; flex-direction:column; gap:16px; max-width:650px;" }, [
            h("div", null, [
              h("label", { style: "display:block; font-size:13px; font-weight:600; color:#334155; margin-bottom:6px;" }, [
                "URL do Servidor Cloud Controller (WebSocket):"
              ]),
              h("input", {
                id: "cp-cloud-url",
                type: "text",
                class: "cp-input",
                value: cloudConfig.value.server_url,
                defaultValue: cloudConfig.value.server_url,
                onInput: (e) => { cloudConfig.value.server_url = e.target.value; },
                placeholder: "Ex: http://192.168.0.2:8088/ws/router ou https://painel.conexaopovosdafloresta.org.br/ws/router"
              }),
              h("div", { style: "font-size:11.5px; color:#64748b; margin-top:4px;" },
                "Equivalente ao comando set-inform do UniFi. O roteador conectará neste endereço automaticamente."
              )
            ]),

            h("div", null, [
              h("label", { style: "display:block; font-size:13px; font-weight:600; color:#334155; margin-bottom:6px;" }, [
                "Nome do Roteador "
              ]),
              h("input", {
                id: "cp-cloud-name",
                type: "text",
                class: "cp-input",
                value: cloudConfig.value.device_name,
                defaultValue: cloudConfig.value.device_name,
                onInput: (e) => { cloudConfig.value.device_name = e.target.value; },
                placeholder: "Ex: Aldeia Yawanawá - Polo 1"
              }),
              h("div", { style: "font-size:11.5px; color:#64748b; margin-top:4px;" },
                "Identificação amigável para exibição no painel de controle da nuvem."
              )
            ]),

            h("div", { style: "display:flex; gap:10px; margin-top:8px;" }, [
              h("button", {
                class: "cp-btn cp-btn-primary",
                style: "padding:8px 18px; font-size:14px;",
                onClick: saveCloudConfig
              }, "💾 Salvar e Conectar ao Cloud Controller"),
              h("a", {
                href: cloudConfig.value.server_url.replace('/ws/router', ''),
                target: "_blank",
                class: "cp-btn cp-btn-default",
                style: "padding:8px 14px; text-decoration:none; display:inline-flex; align-items:center; gap:6px;"
              }, "↗️ Abrir Painel Cloud")
            ])
          ]),

          // Card Explicativo do Fluxo de Adoção
          h("div", { style: "background:#f8fafc; border:1px solid #e2e8f0; border-radius:6px; padding:16px; margin-top:24px;" }, [
            h("div", { style: "font-weight:600; font-size:13px; color:#1e293b; margin-bottom:8px; display:flex; align-items:center; gap:6px;" }, [
              "🔔 Como funciona o Fluxo de Adoção (Estilo UniFi):"
            ]),
            h("ol", { style: "font-size:12.5px; color:#475569; padding-left:18px; margin:0; line-height:1.6;" }, [
              h("li", null, "Insira a URL do Cloud Controller acima e clique em 'Salvar e Conectar'."),
              h("li", null, "O roteador estabelecerá a conexão de saída com a sua plataforma."),
              h("li", null, "No painel da nuvem, este roteador aparecerá na seção '🔔 Novos Roteadores Aguardando Adoção'."),
              h("li", null, "Clique em '✓ Adotar Roteador' no painel central para liberar o Terminal Web SSH e o gerenciamento remoto.")
            ])
          ])
        ])
      ] : null
    ]);
  }
});
