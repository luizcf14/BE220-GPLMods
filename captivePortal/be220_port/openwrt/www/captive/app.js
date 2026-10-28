/**
 * Portal Captivo 3000 — Frontend Logic
 *
 * Fluxo:
 * 1. Usuário preenche email + senha
 * 2. Frontend faz POST para a API REST Laravel (apidev.conexaopovosdafloresta.org.br/api/login)
 * 3. Recebe token Sanctum + user.role.name
 * 4. Frontend faz POST para o roteador (192.168.1.1/cgi-bin/portal_auth) com o token
 * 5. Roteador valida o token com o backend, libera o acesso e responde 200 OK
 * 6. Frontend exibe card de sucesso e redireciona
 */

'use strict';

// ---------------------------------------------------------------------------
// Configuração
// ---------------------------------------------------------------------------
const CONFIG = {
    // URL do backend Laravel (mantida para clareza, pode ser alterada)
    API_BASE: 'https://apidev.conexaopovosdafloresta.org.br',
    API_LOGIN: '/api/login',

    // Endpoint de autorização no roteador (sempre local)
    ROUTER_HOST: window.location.hostname || 'roteador.conexaopovosdafloresta.org.br',
    ROUTER_AUTH_PATH: '/cgi-bin/portal_auth',

    // Tempo de countdown antes do redirecionamento (segundos)
    REDIRECT_DELAY: 5,

    // URL padrão de destino após login (pode ser sobrescrita pelo parâmetro ?next=)
    DEFAULT_REDIRECT: 'https://conexaopovosdafloresta.org.br/'
};

// ---------------------------------------------------------------------------
// Elementos DOM
// ---------------------------------------------------------------------------
const $ = (id) => document.getElementById(id);

const loginCard = $('loginCard');
const successCard = $('successCard');
const loginForm = $('loginForm');
const emailInput = $('email');
const passwordInput = $('password');
const submitBtn = $('submitBtn');
const btnText = submitBtn.querySelector('.btn-text');
const btnSpinner = submitBtn.querySelector('.btn-spinner');
const statusMsg = $('statusMessage');
const togglePwd = $('togglePassword');
const eyeIcon = $('eyeIcon');
const successSub = $('successSubtitle');
const countdownEl = $('countdown');
const continueBtn = $('continueBtn');

// ---------------------------------------------------------------------------
// Obtém URL de destino pós-login
// ---------------------------------------------------------------------------
function getRedirectUrl() {
    const params = new URLSearchParams(window.location.search);
    const next = params.get('next');
    if (next) {
        try {
            // Valida que é uma URL de destino externa segura
            const url = decodeURIComponent(next);
            if (url.startsWith('http://') || url.startsWith('https://')) return url;
        } catch (e) { }
    }

    const ua = navigator.userAgent || '';
    // Android: envia para generate_204 para fechar a tela cativa e remover a interrogação ?
    if (/Android/i.test(ua)) {
        return 'http://connectivitycheck.gstatic.com/generate_204';
    }
    // Apple (iOS/macOS): envia para hotspot-detect.html para o CNA exibir "Concluído"
    if (/iPhone|iPad|iPod|Macintosh/i.test(ua)) {
        return 'http://captive.apple.com/hotspot-detect.html';
    }
    // Windows
    if (/Windows/i.test(ua)) {
        return 'http://www.msftconnecttest.com/connecttest.txt';
    }

    return CONFIG.DEFAULT_REDIRECT;
}

// ---------------------------------------------------------------------------
// UI Helpers
// ---------------------------------------------------------------------------
function showStatus(message, type = 'error') {
    statusMsg.textContent = message;
    statusMsg.className = `status-message ${type}`;
    statusMsg.hidden = false;
    if (type !== 'error') {
        setTimeout(() => { statusMsg.hidden = true; }, 4000);
    }
}

function clearStatus() {
    statusMsg.hidden = true;
    statusMsg.textContent = '';
}

function setLoading(loading) {
    submitBtn.disabled = loading;
    btnText.hidden = loading;
    btnSpinner.hidden = !loading;
    emailInput.disabled = loading;
    passwordInput.disabled = loading;
}

function markFieldError(field, hasError) {
    field.classList.toggle('error', hasError);
}

// ---------------------------------------------------------------------------
// Toggle visibilidade de senha
// ---------------------------------------------------------------------------
togglePwd.addEventListener('click', () => {
    const isPassword = passwordInput.type === 'password';
    passwordInput.type = isPassword ? 'text' : 'password';
    eyeIcon.innerHTML = isPassword
        ? /* olho fechado */ `<path fill-rule="evenodd" d="M3.707 2.293a1 1 0 00-1.414 1.414l14 14a1 1 0 001.414-1.414l-1.473-1.473A10.014 10.014 0 0019.542 10C18.268 5.943 14.478 3 10 3a9.958 9.958 0 00-4.512 1.074l-1.78-1.781zm4.261 4.26l1.514 1.515a2.003 2.003 0 012.45 2.45l1.514 1.514a4 4 0 00-5.478-5.478z" clip-rule="evenodd"/><path d="M12.454 16.697L9.75 13.992a4 4 0 01-3.742-3.741L2.335 6.578A9.98 9.98 0 00.458 10c1.274 4.057 5.065 7 9.542 7 .847 0 1.669-.105 2.454-.303z"/>`
        : /* olho aberto  */ `<path d="M10 12a2 2 0 100-4 2 2 0 000 4z"/><path fill-rule="evenodd" d="M.458 10C1.732 5.943 5.522 3 10 3s8.268 2.943 9.542 7c-1.274 4.057-5.064 7-9.542 7S1.732 14.057.458 10zM14 10a4 4 0 11-8 0 4 4 0 018 0z" clip-rule="evenodd"/>`;
    togglePwd.setAttribute('aria-label', isPassword ? 'Ocultar senha' : 'Mostrar senha');
});

// ---------------------------------------------------------------------------
// Validação local básica
// ---------------------------------------------------------------------------
function validate() {
    let valid = true;

    const email = emailInput.value.trim();
    const password = passwordInput.value;

    markFieldError(emailInput, false);
    markFieldError(passwordInput, false);

    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        markFieldError(emailInput, true);
        valid = false;
    }

    if (!password || password.length < 8) {
        markFieldError(passwordInput, true);
        valid = false;
    }

    if (!valid) {
        showStatus('Verifique os campos destacados e tente novamente.', 'error');
    }

    return valid;
}

// ---------------------------------------------------------------------------
// Passo 1: Login no backend Laravel
// ---------------------------------------------------------------------------
async function doLogin(email, password) {
    const response = await fetch(`${CONFIG.API_BASE}${CONFIG.API_LOGIN}`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json'
        },
        body: JSON.stringify({ email, password })
    });

    const data = await response.json();

    if (!response.ok) {
        // Extrai a primeira mensagem de erro de validação
        if (data.errors) {
            const firstError = Object.values(data.errors)[0];
            throw new Error(Array.isArray(firstError) ? firstError[0] : firstError);
        }
        throw new Error(data.message || `Erro ${response.status}`);
    }

    if (!data.token) {
        throw new Error('Resposta inválida do servidor de autenticação.');
    }

    return {
        token: data.token,
        user: data.user,
        profile: data.user?.role?.name || 'Visitante'
    };
}

// ---------------------------------------------------------------------------
// Passo 2: Autorizar acesso no roteador
// ---------------------------------------------------------------------------
async function doAuthorize(token, profile) {
    const routerUrl = `http://${CONFIG.ROUTER_HOST}${CONFIG.ROUTER_AUTH_PATH}`;

    const body = new URLSearchParams({ token, profile });

    const response = await fetch(routerUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body.toString(),
        // Sem credentials — é uma chamada local ao roteador
        mode: 'cors'
    });

    if (!response.ok) {
        const text = await response.text().catch(() => '');
        throw new Error(`Falha na autorização do roteador (${response.status}): ${text}`);
    }

    const data = await response.json();

    if (data.status !== 'ok') {
        throw new Error(data.message || 'Roteador recusou a autorização.');
    }

    return data;
}

// ---------------------------------------------------------------------------
// Exibe card de sucesso e inicia countdown
// ---------------------------------------------------------------------------
function showSuccess(userName, profileName) {
    loginCard.hidden = true;
    successCard.hidden = false;

    successSub.textContent = `Bem-vindo, ${userName || 'usuário'}! Perfil: ${profileName}`;

    const redirectUrl = getRedirectUrl();
    continueBtn.href = redirectUrl;

    let remaining = CONFIG.REDIRECT_DELAY;
    countdownEl.textContent = remaining;

    const timer = setInterval(() => {
        remaining--;
        countdownEl.textContent = remaining;
        if (remaining <= 0) {
            clearInterval(timer);
            window.location.href = redirectUrl;
        }
    }, 1000);
}

// ---------------------------------------------------------------------------
// Suporte a Biometria (Fingerprint / FaceID / WebAuthn)
// ---------------------------------------------------------------------------
const biometricContainer = $('biometricContainer');
const biometricBtn = $('biometricBtn');
// ---------------------------------------------------------------------------
// Biometria / Credenciais Salvas (Acesso Rápido com 1 Toque)
// ---------------------------------------------------------------------------
const BIO_STORAGE_KEY = 'portal_captivo_bio';

async function initBiometrics() {
    if (!biometricContainer || !biometricBtn) return;

    try {
        const savedData = localStorage.getItem(BIO_STORAGE_KEY);
        if (!savedData) return;

        const parsed = JSON.parse(savedData);
        if (!parsed.email || !parsed.password) return;

        // Se há credenciais salvas, exibe o container
        biometricContainer.hidden = false;

        const bioText = biometricBtn.querySelector('span');
        if (bioText) {
            const displayName = parsed.name || parsed.email.split('@')[0];
            bioText.textContent = `Entrar como ${displayName}`;
        }
    } catch (e) {
        console.warn('[Portal Captivo] Erro ao inicializar biometria:', e);
    }
}

async function handleBiometricLogin() {
    const savedData = localStorage.getItem(BIO_STORAGE_KEY);
    if (!savedData) {
        showStatus('Nenhuma credencial salva. Digite seu e-mail e senha primeiro.', 'error');
        return;
    }

    let parsed;
    try {
        parsed = JSON.parse(savedData);
    } catch (e) {
        showStatus('Erro ao ler credenciais salvas. Faça login manualmente.', 'error');
        return;
    }

    if (!parsed.email || !parsed.password) {
        showStatus('Credenciais incompletas. Faça login manualmente.', 'error');
        return;
    }

    setLoading(true);
    showStatus('Validando com biometria...', 'info');

    try {
        // Dispara o prompt biométrico nativo do sistema via WebAuthn se disponível
        if (window.isSecureContext && window.PublicKeyCredential && navigator.credentials && navigator.credentials.get) {
            try {
                const challenge = new Uint8Array(32);
                window.crypto.getRandomValues(challenge);

                await navigator.credentials.get({
                    publicKey: {
                        challenge: challenge,
                        timeout: 60000,
                        userVerification: 'preferred'
                    }
                });
            } catch (bioPromptErr) {
                if (bioPromptErr.name === 'NotAllowedError') {
                    throw new Error('Autenticação biométrica cancelada.');
                }
                console.warn('[Portal Captivo] Prompt biométrico pulado:', bioPromptErr);
            }
        }

        showStatus('Conectando e liberando acesso...', 'info');

        // Chama diretamente o endpoint de autorização local do roteador usando as credenciais salvas
        const body = new URLSearchParams({
            email: parsed.email,
            password: parsed.password
        });
        const res = await fetch('/cgi-bin/portal_auth', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body.toString()
        });

        if (!res.ok) {
            throw new Error(`Erro na comunicação com o roteador (${res.status})`);
        }

        const data = await res.json();
        if (data.status !== 'ok') {
            throw new Error(data.message || 'Credenciais salvas inválidas ou expiradas.');
        }

        // Atualiza os dados salvos com o perfil retornado
        saveBiometricCredential(parsed.email, parsed.password, '', { name: data.user }, data.profile);

        // Sucesso!
        clearStatus();
        showSuccess(data.user || parsed.name || parsed.email, data.profile || 'Visitante');

    } catch (err) {
        console.error('[Portal Captivo Biometria]', err);
        setLoading(false);
        const msg = err.message || 'Falha na autenticação por biometria.';
        showStatus(msg, 'error');
    }
}

if (biometricBtn) {
    biometricBtn.addEventListener('click', handleBiometricLogin);
}

function saveBiometricCredential(email, password, token, user, profile) {
    try {
        const data = {
            email,
            password,
            profile: profile || 'Visitante',
            name: user?.name || email.split('@')[0]
        };
        localStorage.setItem(BIO_STORAGE_KEY, JSON.stringify(data));

        if (biometricContainer) {
            biometricContainer.hidden = false;
            const bioText = biometricBtn?.querySelector('span');
            if (bioText) {
                bioText.textContent = `Entrar como ${data.name}`;
            }
        }
    } catch (e) { }
}

// ---------------------------------------------------------------------------
// Keepalive em segundo plano (renova a sessão a cada 10 min enquanto a aba estiver aberta)
// ---------------------------------------------------------------------------
function startKeepalive(token, profile) {
    const KEEPALIVE_INTERVAL = 10 * 60 * 1000; // 10 minutos

    setInterval(async () => {
        try {
            await doAuthorize(token, profile);
            console.log('[Portal Captivo] Keepalive enviado com sucesso.');
        } catch (e) {
            console.warn('[Portal Captivo] Erro no keepalive:', e);
        }
    }, KEEPALIVE_INTERVAL);
}

// Inicializa checagem de biometria ao carregar a página
document.addEventListener('DOMContentLoaded', initBiometrics);

// ---------------------------------------------------------------------------
// Handler principal do formulário
// ---------------------------------------------------------------------------
loginForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    clearStatus();

    if (!validate()) return;

    const email = emailInput.value.trim();
    const password = passwordInput.value;

    setLoading(true);

    try {
        showStatus('Validando credenciais com a Floresta...', 'info');

        // Chama diretamente o endpoint de autorização local do roteador.
        // O roteador valida as credenciais contra a API oficial da Floresta e libera o firewall no iptables.
        const body = new URLSearchParams({ email, password });
        const res = await fetch('/cgi-bin/portal_auth', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: body.toString()
        });

        if (!res.ok) {
            throw new Error(`Erro na comunicação com o roteador (${res.status})`);
        }

        const data = await res.json();
        if (data.status !== 'ok') {
            throw new Error(data.message || 'Credenciais inválidas.');
        }

        // Salva credencial para biometria futura
        saveBiometricCredential(email, password, '', { name: data.user }, data.profile);

        // Sucesso!
        clearStatus();
        showSuccess(data.user || email, data.profile || 'Visitante');

    } catch (err) {
        console.error('[Portal Captivo]', err);
        setLoading(false);

        // Mensagem amigável baseada no tipo de erro
        const msg = err.message || 'Erro desconhecido';

        if (msg.includes('Failed to fetch') || msg.includes('NetworkError') || msg.includes('roteador')) {
            showStatus(
                '⚠ Não foi possível conectar ao roteador. Verifique se você está na rede local.',
                'error'
            );
        } else if (msg.toLowerCase().includes('senha') || msg.toLowerCase().includes('password') ||
            msg.toLowerCase().includes('credencial') || msg.toLowerCase().includes('unauthenticated')) {
            markFieldError(passwordInput, true);
            showStatus('E-mail ou senha incorretos. Tente novamente.', 'error');
        } else {
            showStatus(msg, 'error');
        }
    }
});

// ---------------------------------------------------------------------------
// Remove erro visual ao digitar
// ---------------------------------------------------------------------------
[emailInput, passwordInput].forEach(field => {
    field.addEventListener('input', () => {
        markFieldError(field, false);
        if (statusMsg.classList.contains('error')) {
            statusMsg.hidden = true;
        }
    });
});
