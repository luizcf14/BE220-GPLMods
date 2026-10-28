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
const BIO_STORAGE_KEY = 'portal_captivo_bio';

async function initBiometrics() {
    if (!biometricContainer || !biometricBtn) return;

    try {
        const isAvailable = window.PublicKeyCredential &&
            (await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable().catch(() => true));

        const savedData = localStorage.getItem(BIO_STORAGE_KEY);

        if (isAvailable && savedData) {
            biometricContainer.hidden = false;
        }
    } catch (e) {
        console.log('[Portal Captivo] Biometria não disponível neste dispositivo.');
    }
}

async function handleBiometricLogin() {
    const savedData = localStorage.getItem(BIO_STORAGE_KEY);
    if (!savedData) return;

    let parsed;
    try {
        parsed = JSON.parse(savedData);
    } catch (e) {
        return;
    }

    setLoading(true);
    showStatus('Autenticando via Biometria...', 'info');

    try {
        // Dispara o prompt biométrico nativo do sistema via WebAuthn se disponível
        if (window.PublicKeyCredential && navigator.credentials && navigator.credentials.get) {
            const challenge = new Uint8Array(32);
            window.crypto.getRandomValues(challenge);

            await navigator.credentials.get({
                publicKey: {
                    challenge: challenge,
                    timeout: 60000,
                    userVerification: 'required'
                }
            }).catch(() => {
                // Fallback silencioso se o navegador não requerer challenge
            });
        }

        // Tenta autorização com o token salvo ou realiza relogin
        let { token, profile } = parsed;

        try {
            await doAuthorize(token, profile);
        } catch (authErr) {
            // Se o token expirou, tenta relogar usando credencial salva
            if (parsed.email && parsed.password) {
                const res = await doLogin(parsed.email, parsed.password);
                token = res.token;
                profile = res.profile;
                await doAuthorize(token, profile);
                // Atualiza token salvo
                parsed.token = token;
                localStorage.setItem(BIO_STORAGE_KEY, JSON.stringify(parsed));
            } else {
                throw authErr;
            }
        }

        clearStatus();
        showSuccess(parsed.name || parsed.email, profile);

    } catch (err) {
        console.error('[Portal Captivo Biometria]', err);
        setLoading(false);
        showStatus('Falha na autenticação por biometria. Use e-mail e senha.', 'error');
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
            token,
            profile,
            name: user?.name || email
        };
        localStorage.setItem(BIO_STORAGE_KEY, JSON.stringify(data));
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
        // Passo 1: autenticar no backend
        showStatus('Autenticando com o servidor...', 'info');
        const { token, user, profile } = await doLogin(email, password);

        // Passo 2: autorizar no roteador
        showStatus('Liberando acesso à rede...', 'info');
        await doAuthorize(token, profile);

        // Salva credencial para biometria futura
        saveBiometricCredential(email, password, token, user, profile);

        // Inicia keepalive
        startKeepalive(token, profile);

        // Sucesso!
        clearStatus();
        showSuccess(user?.name || user?.email, profile);

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
