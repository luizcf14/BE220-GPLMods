<?php
/**
 * Conexão Povos da Floresta — Cloud Controller Server (Estilo UniFi)
 *
 * Servidor assíncrono HTTP e WebSocket em PHP puro (zero dependências externas).
 * - Suporte a Fluxo de Adoção de Roteadores (Adoption Workflow)
 * - Canal Web Terminal / SSH interativo tunelado via WebSocket
 * - Gestão remota de QoS, sessões e reboot
 */

declare(strict_types=1);

error_reporting(E_ALL);
ini_set('display_errors', '1');

$HOST = '0.0.0.0';
$PORT = (int)(getenv('PORT') ?: 8088);
$PUBLIC_DIR = __DIR__ . '/public';
$DATA_DIR = getenv('DATA_DIR') ?: (__DIR__ . '/data');
$ADOPTED_FILE = $DATA_DIR . '/adopted_devices.json';

if (!is_dir($DATA_DIR)) {
    @mkdir($DATA_DIR, 0777, true);
}

function normalizeMac(string $mac): string {
    $clean = strtoupper((string)preg_replace('/[^0-9A-F]/i', '', $mac));
    if (strlen($clean) === 12) {
        return implode(':', str_split($clean, 2));
    }
    return strtoupper(trim($mac));
}

function cleanMac(string $mac): string {
    return strtoupper((string)preg_replace('/[^0-9A-F]/i', '', $mac));
}

function safeUtf8(mixed $data): mixed {
    if (is_string($data)) {
        if (!mb_check_encoding($data, 'UTF-8')) {
            $converted = @mb_convert_encoding($data, 'UTF-8', 'ISO-8859-1, Windows-1252, ASCII');
            if ($converted !== false && mb_check_encoding($converted, 'UTF-8')) {
                return $converted;
            }
            return @iconv('UTF-8', 'UTF-8//IGNORE', $data) ?: (preg_replace('/[^\x20-\x7E]/', '', $data) ?? '');
        }
        return $data;
    }
    if (is_array($data)) {
        $clean = [];
        foreach ($data as $k => $v) {
            $cleanKey = is_string($k) ? safeUtf8($k) : $k;
            $clean[$cleanKey] = safeUtf8($v);
        }
        return $clean;
    }
    return $data;
}

function safeJsonEncode(mixed $data, int $flags = 0): string {
    $clean = safeUtf8($data);
    $json = json_encode($clean, $flags | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    if ($json !== false) {
        return $json;
    }
    return '{}';
}

function loadAdoptedDevices(): array {
    global $ADOPTED_FILE;
    if (file_exists($ADOPTED_FILE)) {
        $raw = file_get_contents($ADOPTED_FILE);
        $data = @json_decode($raw, true);
        if (!is_array($data)) {
            $cleanRaw = safeUtf8($raw);
            $data = @json_decode($cleanRaw, true);
        }
        if (is_array($data)) {
            $normalized = [];
            foreach ($data as $k => $v) {
                $normalized[normalizeMac((string)$k)] = safeUtf8($v);
            }
            return $normalized;
        }
    }
    return [];
}

function saveAdoptedDevices(array $devices): void {
    global $ADOPTED_FILE;
    @file_put_contents($ADOPTED_FILE, safeJsonEncode($devices, JSON_PRETTY_PRINT));
}

$adoptedDevices = loadAdoptedDevices();

// ============================================================================
// AUTENTICAÇÃO, USUÁRIOS E CONTROLE DE ACESSO (RBAC)
// Papéis: viewer (somente leitura) < operator (comandos/terminal/DNS) < admin (tudo + usuários)
// Sessão: cookie assinado (HMAC-SHA256) 'fl_session', HttpOnly, validado a cada requisição.
// ============================================================================
const AUTH_COOKIE = 'fl_session';
const AUTH_TTL_DEFAULT = 43200;    // 12h de inatividade
const AUTH_TTL_REMEMBER = 2592000; // 30 dias ("Manter conectado")

$USERS_FILE = $DATA_DIR . '/users.json';
$AUTH_SECRET_FILE = $DATA_DIR . '/auth_secret.key';
$SETUP_CODE_FILE = $DATA_DIR . '/setup_code.txt';
$AUTH_ROLE_RANK = ['viewer' => 1, 'operator' => 2, 'admin' => 3];
$authFailures = [];

function atomicWriteFile(string $path, string $content): bool {
    $tmp = $path . '.tmp' . getmypid();
    if (@file_put_contents($tmp, $content) !== false && @rename($tmp, $path)) {
        return true;
    }
    @unlink($tmp);
    return @file_put_contents($path, $content) !== false;
}

function b64uEncode(string $s): string {
    return rtrim(strtr(base64_encode($s), '+/', '-_'), '=');
}

function b64uDecode(string $s): string {
    return (string)base64_decode(strtr($s, '-_', '+/'));
}

function authSecret(): string {
    static $secret = null;
    if ($secret !== null) return $secret;
    global $AUTH_SECRET_FILE;
    $env = getenv('AUTH_SECRET');
    if ($env && strlen($env) >= 16) {
        return $secret = $env;
    }
    if (is_file($AUTH_SECRET_FILE)) {
        $raw = trim((string)@file_get_contents($AUTH_SECRET_FILE));
        if (strlen($raw) >= 32) {
            return $secret = $raw;
        }
    }
    $secret = bin2hex(random_bytes(32));
    atomicWriteFile($AUTH_SECRET_FILE, $secret);
    @chmod($AUTH_SECRET_FILE, 0600);
    return $secret;
}

function loadUsers(): array {
    global $USERS_FILE;
    if (!is_file($USERS_FILE)) return [];
    $data = @json_decode((string)@file_get_contents($USERS_FILE), true);
    if (!is_array($data)) return [];
    $out = [];
    foreach ($data as $u) {
        if (is_array($u) && !empty($u['username'])) {
            $out[(string)$u['username']] = $u;
        }
    }
    return $out;
}

$users = loadUsers();

function saveUsers(): bool {
    global $users, $USERS_FILE;
    $ok = atomicWriteFile($USERS_FILE, safeJsonEncode(array_values($users), JSON_PRETTY_PRINT));
    if ($ok) @chmod($USERS_FILE, 0600);
    return $ok;
}

function auditLog(string $user, string $event, string $detail = ''): void {
    $detail = preg_replace('/[\r\n]+/', ' ', $detail);
    echo "[AUDIT] user={$user} event={$event}" . ($detail !== '' ? " {$detail}" : '') . "\n";
}

function parseCookies(string $cookieHeader): array {
    $cookies = [];
    if ($cookieHeader !== '') {
        foreach (explode(';', $cookieHeader) as $part) {
            $kv = explode('=', trim($part), 2);
            if (count($kv) === 2) {
                $cookies[trim($kv[0])] = trim($kv[1]);
            }
        }
    }
    return $cookies;
}

function makeAuthToken(string $username, int $tv, bool $remember): array {
    $ttl = $remember ? AUTH_TTL_REMEMBER : AUTH_TTL_DEFAULT;
    $payload = ['u' => $username, 'tv' => $tv, 'rem' => $remember ? 1 : 0, 'exp' => time() + $ttl];
    $p = b64uEncode(json_encode($payload));
    $sig = b64uEncode(hash_hmac('sha256', $p, authSecret(), true));
    return ['token' => $p . '.' . $sig, 'ttl' => $ttl, 'exp' => $payload['exp']];
}

function verifyAuthToken(string $token): ?array {
    if ($token === '' || strpos($token, '.') === false) return null;
    [$p, $sig] = explode('.', $token, 2);
    $expect = b64uEncode(hash_hmac('sha256', $p, authSecret(), true));
    if (!hash_equals($expect, $sig)) return null;
    $payload = @json_decode(b64uDecode($p), true);
    if (!is_array($payload) || empty($payload['u']) || !isset($payload['exp'], $payload['tv'])) return null;
    if ((int)$payload['exp'] < time()) return null;
    return $payload;
}

/** Valida o cookie de sessão contra a base de usuários. Retorna null se inválido. */
function authenticate(array $cookies): ?array {
    global $users;
    $p = verifyAuthToken((string)($cookies[AUTH_COOKIE] ?? ''));
    if (!$p) return null;
    $u = $users[(string)$p['u']] ?? null;
    if (!$u || empty($u['active']) || (int)($u['tv'] ?? 0) !== (int)$p['tv']) return null;
    return [
        'user' => $u,
        'username' => (string)$u['username'],
        'role' => (string)($u['role'] ?? 'viewer'),
        'exp' => (int)$p['exp'],
        'rem' => !empty($p['rem']),
        'must_change' => !empty($u['must_change'])
    ];
}

function roleRank(string $role): int {
    global $AUTH_ROLE_RANK;
    return $AUTH_ROLE_RANK[$role] ?? 0;
}

function hasRole(?array $sess, string $min): bool {
    return $sess !== null && empty($sess['must_change']) && roleRank($sess['role']) >= roleRank($min);
}

function isSecureRequest(array $headers): bool {
    return strtolower($headers['x-forwarded-proto'] ?? '') === 'https';
}

function sessionCookieHeader(string $token, int $ttl, bool $secure): string {
    return 'Set-Cookie: ' . AUTH_COOKIE . '=' . $token . "; Path=/; Max-Age={$ttl}; HttpOnly; SameSite=Lax" . ($secure ? '; Secure' : '');
}

function clearCookieHeader(bool $secure): string {
    return 'Set-Cookie: ' . AUTH_COOKIE . '=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax' . ($secure ? '; Secure' : '');
}

/** Se o cabeçalho Origin existir, precisa apontar para o mesmo Host (anti CSRF / cross-site WebSocket hijacking). */
function sameOriginOk(array $headers): bool {
    $origin = $headers['origin'] ?? '';
    if ($origin === '' || $origin === 'null') {
        return $origin === '';
    }
    $oh = parse_url($origin, PHP_URL_HOST);
    $op = parse_url($origin, PHP_URL_PORT);
    $oHostPort = strtolower((string)$oh . ($op ? ':' . $op : ''));
    return $oHostPort !== '' && $oHostPort === strtolower($headers['host'] ?? '');
}

function clientIp(array $headers): string {
    $xff = $headers['x-forwarded-for'] ?? '';
    if ($xff !== '') {
        $parts = array_map('trim', explode(',', $xff));
        return (string)end($parts);
    }
    return 'local';
}

function sendJsonResponse($conn, int $clientId, int $status, array $data, array $extraHeaders = []): void {
    global $clients, $clientMeta;
    $texts = [200 => 'OK', 201 => 'Created', 400 => 'Bad Request', 401 => 'Unauthorized', 403 => 'Forbidden',
              404 => 'Not Found', 409 => 'Conflict', 415 => 'Unsupported Media Type', 429 => 'Too Many Requests', 500 => 'Internal Server Error'];
    $body = safeJsonEncode($data);
    $resp = "HTTP/1.1 {$status} " . ($texts[$status] ?? 'OK') . "\r\n" .
            "Content-Type: application/json; charset=utf-8\r\n" .
            "Content-Length: " . strlen($body) . "\r\n" .
            "Cache-Control: no-store\r\n" .
            "X-Content-Type-Options: nosniff\r\n";
    foreach ($extraHeaders as $h) {
        $resp .= $h . "\r\n";
    }
    $resp .= "Connection: close\r\n\r\n" . $body;
    @fwrite($conn, $resp);
    @fclose($conn);
    unset($clients[$clientId], $clientMeta[$clientId]);
}

/** Exige papel mínimo em endpoints JSON. Responde 401/403 e retorna false se negado. */
function requireHttpRole($conn, int $clientId, ?array $sess, string $min): bool {
    if (!$sess) {
        sendJsonResponse($conn, $clientId, 401, ['ok' => false, 'error' => 'Autenticação necessária']);
        return false;
    }
    if (!hasRole($sess, $min)) {
        sendJsonResponse($conn, $clientId, 403, ['ok' => false, 'error' => $sess['must_change'] ? 'must_change_password' : 'Permissão insuficiente']);
        return false;
    }
    return true;
}

/** Exige papel mínimo em rotas de navegação (redireciona ao login / página 403). */
function requireNavRole($conn, int $clientId, ?array $sess, string $min, ?array $headers = null): bool {
    global $clients, $clientMeta;
    if (hasRole($sess, $min)) return true;
    if (!$sess) {
        if ($headers !== null && stripos($headers['accept'] ?? '', 'text/html') === false) {
            sendJsonResponse($conn, $clientId, 401, ['ok' => false, 'error' => 'Autenticação necessária']);
            return false;
        }
        $resp = "HTTP/1.1 302 Found\r\nLocation: /dashboard\r\nCache-Control: no-store\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    } else {
        $body = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Acesso negado</title></head><body style='font-family:sans-serif;background:#0d1117;color:#c9d1d9;text-align:center;padding:60px 20px;'><h2>Acesso negado</h2><p>Seu perfil não tem permissão para acessar a interface do roteador.</p><p><a href='/dashboard' style='color:#58a6ff'>Voltar ao painel</a></p></body></html>";
        $resp = "HTTP/1.1 403 Forbidden\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " . strlen($body) . "\r\nConnection: close\r\n\r\n" . $body;
    }
    @fwrite($conn, $resp);
    @fclose($conn);
    unset($clients[$clientId], $clientMeta[$clientId]);
    return false;
}

// ---- Rate limit de login (por usuário+IP e por IP) ----
function authLockRemaining(string $key): int {
    global $authFailures;
    $f = $authFailures[$key] ?? null;
    if ($f && ($f['until'] ?? 0) > time()) {
        return $f['until'] - time();
    }
    return 0;
}

function authRegisterFailure(string $key, int $limit): void {
    global $authFailures;
    $now = time();
    $f = $authFailures[$key] ?? ['n' => 0, 'until' => 0, 'last' => $now];
    if ($now - ($f['last'] ?? 0) > 900) {
        $f = ['n' => 0, 'until' => 0, 'last' => $now];
    }
    $f['n']++;
    $f['last'] = $now;
    if ($f['n'] >= $limit) {
        $f['until'] = $now + 300;
        $f['n'] = 0;
    }
    $authFailures[$key] = $f;
}

function pruneAuthFailures(): void {
    global $authFailures;
    $now = time();
    foreach ($authFailures as $k => $f) {
        if (($f['until'] ?? 0) < $now && $now - ($f['last'] ?? 0) > 900) {
            unset($authFailures[$k]);
        }
    }
}

function validUsername(string $u): bool {
    return (bool)preg_match('/^[a-z0-9._-]{3,32}$/', $u);
}

function passwordProblem(string $p): ?string {
    if (strlen($p) < 10) return 'A senha deve ter pelo menos 10 caracteres.';
    if (strlen($p) > 200) return 'Senha muito longa.';
    if (!preg_match('/[A-Za-z]/', $p) || !preg_match('/\d/', $p)) return 'A senha deve conter letras e números.';
    return null;
}

function publicUser(array $u): array {
    return [
        'username' => $u['username'],
        'name' => $u['name'] ?? $u['username'],
        'role' => $u['role'] ?? 'viewer',
        'active' => !empty($u['active']),
        'must_change' => !empty($u['must_change']),
        'created_at' => $u['created_at'] ?? null,
        'last_login' => $u['last_login'] ?? null
    ];
}

function countActiveAdmins(?string $excludeUser = null): int {
    global $users;
    $n = 0;
    foreach ($users as $u) {
        if ($excludeUser !== null && $u['username'] === $excludeUser) continue;
        if (!empty($u['active']) && ($u['role'] ?? '') === 'admin') $n++;
    }
    return $n;
}

/** Código de configuração inicial (impresso nos logs do Cloud Run) — impede que um terceiro crie o 1º admin. */
function ensureSetupCode(): ?string {
    global $users, $SETUP_CODE_FILE, $authFailures;
    if (!empty($users)) return null;
    if (is_file($SETUP_CODE_FILE)) {
        $c = trim((string)@file_get_contents($SETUP_CODE_FILE));
        if ($c !== '') return $c;
    }
    $raw = strtoupper(bin2hex(random_bytes(4)));
    $code = substr($raw, 0, 4) . '-' . substr($raw, 4, 4);
    atomicWriteFile($SETUP_CODE_FILE, $code);
    @chmod($SETUP_CODE_FILE, 0600);
    return $code;
}

if (empty($users)) {
    $bootSetupCode = ensureSetupCode();
    echo "[SETUP] Nenhum usuário cadastrado. Código de configuração inicial: {$bootSetupCode}\n";
}

/** Encerra sockets (admin/terminal) cuja sessão expirou, foi revogada ou perdeu privilégio. */
function revalidateAuthSockets(): void {
    global $clientMeta, $users;
    $now = time();
    foreach ($clientMeta as $cid => $m) {
        if (empty($m['user'])) continue;
        $u = $users[$m['user']] ?? null;
        $bad = !$u || empty($u['active']) || !empty($u['must_change'])
            || (int)($u['tv'] ?? 0) !== (int)($m['tv'] ?? -1)
            || $now > (int)($m['sess_exp'] ?? 0);
        if (!$bad && ($m['type'] ?? '') === 'terminal' && roleRank((string)($u['role'] ?? '')) < roleRank('operator')) {
            $bad = true;
        }
        if ($bad) {
            closeClient((int)$cid);
        }
    }
}

function extendUserSockets(string $username, int $exp): void {
    global $clientMeta;
    foreach ($clientMeta as $cid => $m) {
        if (($m['user'] ?? '') === $username && $exp > (int)($m['sess_exp'] ?? 0)) {
            $clientMeta[$cid]['sess_exp'] = $exp;
        }
    }
}

function wsSocketHasRole(int $clientId, string $min): bool {
    global $clientMeta, $users;
    $uname = $clientMeta[$clientId]['user'] ?? '';
    $u = $users[$uname] ?? null;
    if (!$u || empty($u['active']) || !empty($u['must_change'])) return false;
    return roleRank((string)($u['role'] ?? '')) >= roleRank($min);
}

/** Papel mínimo necessário para cada ação do canal admin (WebSocket). */
function authorizeWsAction($conn, int $clientId, string $action): bool {
    global $clientMeta;
    if (in_array($action, ['ping', 'get_default_dns_blocklist'], true)) {
        $min = 'viewer';
    } elseif ($action === 'forget_device') {
        $min = 'admin';
    } else {
        $min = 'operator';
    }
    if (wsSocketHasRole($clientId, $min)) {
        if (!in_array($action, ['ping', 'get_default_dns_blocklist'], true)) {
            auditLog((string)($clientMeta[$clientId]['user'] ?? '?'), 'ws_' . $action);
        }
        return true;
    }
    sendToClient($conn, safeJsonEncode(['event' => 'forbidden', 'action' => $action, 'error' => 'Permissão insuficiente para esta ação']));
    return false;
}

/**
 * Rotas /api/auth/* e /api/users*. Retorna true se a requisição foi tratada (resposta enviada).
 */
function handleAuthApi($conn, int $clientId, string $method, string $path, array $headers, string $reqBody, ?array $sess): bool {
    global $users, $SETUP_CODE_FILE, $authFailures;

    $isAuthPath = strpos($path, '/api/auth/') === 0;
    $isUsersPath = ($path === '/api/users' || strpos($path, '/api/users/') === 0);
    if (!$isAuthPath && !$isUsersPath) return false;

    $secure = isSecureRequest($headers);
    $reply = function (int $status, array $data, array $extra = []) use ($conn, $clientId) {
        sendJsonResponse($conn, $clientId, $status, $data, $extra);
    };

    if ($method !== 'GET' && $method !== 'HEAD') {
        if (!sameOriginOk($headers)) {
            $reply(403, ['ok' => false, 'error' => 'Origem não permitida']);
            return true;
        }
        if (stripos($headers['content-type'] ?? '', 'application/json') === false) {
            $reply(415, ['ok' => false, 'error' => 'Content-Type deve ser application/json']);
            return true;
        }
    }
    $body = [];
    if ($reqBody !== '') {
        $decoded = @json_decode($reqBody, true);
        if (is_array($decoded)) $body = $decoded;
    }

    // ---------------- /api/auth/status ----------------
    if ($path === '/api/auth/status' && $method === 'GET') {
        $reply(200, ['ok' => true, 'setup_required' => empty($users), 'authenticated' => $sess !== null]);
        return true;
    }

    // ---------------- /api/auth/setup (primeiro administrador) ----------------
    if ($path === '/api/auth/setup' && $method === 'POST') {
        $ip = clientIp($headers);
        if (!empty($users)) {
            $reply(409, ['ok' => false, 'error' => 'A configuração inicial já foi concluída.']);
            return true;
        }
        if (authLockRemaining('setup|' . $ip) > 0) {
            $reply(429, ['ok' => false, 'error' => 'Muitas tentativas. Aguarde alguns minutos.']);
            return true;
        }
        $code = ensureSetupCode();
        $given = strtoupper(trim((string)($body['setup_code'] ?? '')));
        if ($code === null || !hash_equals($code, $given)) {
            authRegisterFailure('setup|' . $ip, 5);
            $reply(403, ['ok' => false, 'error' => 'Código de configuração inválido. Consulte os logs do servidor.']);
            return true;
        }
        $uname = strtolower(trim((string)($body['username'] ?? '')));
        $name = safeUtf8(trim((string)($body['name'] ?? '')));
        $pw = (string)($body['password'] ?? '');
        if (!validUsername($uname)) {
            $reply(400, ['ok' => false, 'error' => 'Usuário inválido (3-32 caracteres: letras minúsculas, números, . _ -).']);
            return true;
        }
        if (($pp = passwordProblem($pw)) !== null) {
            $reply(400, ['ok' => false, 'error' => $pp]);
            return true;
        }
        $users[$uname] = [
            'username' => $uname,
            'name' => $name !== '' ? mb_substr($name, 0, 80) : $uname,
            'role' => 'admin',
            'password_hash' => password_hash($pw, PASSWORD_BCRYPT, ['cost' => 10]),
            'active' => true,
            'must_change' => false,
            'tv' => 1,
            'created_at' => time(),
            'last_login' => time()
        ];
        if (!saveUsers()) {
            unset($users[$uname]);
            $reply(500, ['ok' => false, 'error' => 'Falha ao gravar usuários no armazenamento.']);
            return true;
        }
        @unlink($SETUP_CODE_FILE);
        auditLog($uname, 'setup_first_admin');
        $tk = makeAuthToken($uname, 1, false);
        $reply(200, ['ok' => true, 'user' => publicUser($users[$uname])], [sessionCookieHeader($tk['token'], $tk['ttl'], $secure)]);
        return true;
    }

    // ---------------- /api/auth/login ----------------
    if ($path === '/api/auth/login' && $method === 'POST') {
        $ip = clientIp($headers);
        $uname = strtolower(trim((string)($body['username'] ?? '')));
        $pw = (string)($body['password'] ?? '');
        $remember = !empty($body['remember']);
        $kUser = 'u|' . $uname . '|' . $ip;
        $kIp = 'ip|' . $ip;
        $wait = max(authLockRemaining($kUser), authLockRemaining($kIp));
        if ($wait > 0) {
            $reply(429, ['ok' => false, 'error' => 'Muitas tentativas. Tente novamente em ' . (int)ceil($wait / 60) . ' min.', 'retry_after' => $wait]);
            return true;
        }
        static $dummyHash = null;
        if ($dummyHash === null) {
            $dummyHash = password_hash('dummy-password-timing', PASSWORD_BCRYPT, ['cost' => 10]);
        }
        $u = $users[$uname] ?? null;
        $hash = ($u && !empty($u['password_hash'])) ? $u['password_hash'] : $dummyHash;
        $ok = password_verify($pw, $hash) && $u && !empty($u['active']);
        if (!$ok) {
            authRegisterFailure($kUser, 5);
            authRegisterFailure($kIp, 30);
            auditLog($uname !== '' ? $uname : '?', 'login_failed', "ip={$ip}");
            $reply(401, ['ok' => false, 'error' => 'Usuário ou senha inválidos.']);
            return true;
        }
        unset($authFailures[$kUser]);
        $users[$uname]['last_login'] = time();
        if (password_needs_rehash($hash, PASSWORD_BCRYPT, ['cost' => 10])) {
            $users[$uname]['password_hash'] = password_hash($pw, PASSWORD_BCRYPT, ['cost' => 10]);
        }
        saveUsers();
        auditLog($uname, 'login', "ip={$ip} remember=" . ($remember ? '1' : '0'));
        $tk = makeAuthToken($uname, (int)($users[$uname]['tv'] ?? 0), $remember);
        $reply(200, ['ok' => true, 'user' => publicUser($users[$uname])], [sessionCookieHeader($tk['token'], $tk['ttl'], $secure)]);
        return true;
    }

    // ---------------- /api/auth/logout ----------------
    if ($path === '/api/auth/logout' && $method === 'POST') {
        if ($sess) {
            auditLog($sess['username'], 'logout');
        }
        $reply(200, ['ok' => true], [clearCookieHeader($secure)]);
        return true;
    }

    // Todas as demais rotas exigem sessão válida
    if (!$sess) {
        $reply(401, ['ok' => false, 'error' => 'Autenticação necessária'], [clearCookieHeader($secure)]);
        return true;
    }

    // ---------------- /api/auth/me (também renova a sessão deslizante) ----------------
    if ($path === '/api/auth/me' && $method === 'GET') {
        $tk = makeAuthToken($sess['username'], (int)($sess['user']['tv'] ?? 0), $sess['rem']);
        extendUserSockets($sess['username'], $tk['exp']);
        $reply(200, ['ok' => true, 'user' => publicUser($sess['user']), 'expires_at' => $tk['exp']], [sessionCookieHeader($tk['token'], $tk['ttl'], $secure)]);
        return true;
    }

    // ---------------- /api/auth/change-password ----------------
    if ($path === '/api/auth/change-password' && $method === 'POST') {
        $cur = (string)($body['current_password'] ?? '');
        $new = (string)($body['new_password'] ?? '');
        $uname = $sess['username'];
        if (!password_verify($cur, (string)($users[$uname]['password_hash'] ?? ''))) {
            $reply(400, ['ok' => false, 'error' => 'Senha atual incorreta.']);
            return true;
        }
        if (($pp = passwordProblem($new)) !== null) {
            $reply(400, ['ok' => false, 'error' => $pp]);
            return true;
        }
        if ($new === $cur) {
            $reply(400, ['ok' => false, 'error' => 'A nova senha deve ser diferente da atual.']);
            return true;
        }
        $users[$uname]['password_hash'] = password_hash($new, PASSWORD_BCRYPT, ['cost' => 10]);
        $users[$uname]['must_change'] = false;
        $users[$uname]['tv'] = (int)($users[$uname]['tv'] ?? 0) + 1;
        saveUsers();
        auditLog($uname, 'change_password');
        revalidateAuthSockets();
        $tk = makeAuthToken($uname, (int)$users[$uname]['tv'], $sess['rem']);
        $reply(200, ['ok' => true, 'user' => publicUser($users[$uname])], [sessionCookieHeader($tk['token'], $tk['ttl'], $secure)]);
        return true;
    }

    // ---------------- CRUD de usuários (somente administrador) ----------------
    if ($isUsersPath) {
        if (!hasRole($sess, 'admin')) {
            $reply(403, ['ok' => false, 'error' => $sess['must_change'] ? 'must_change_password' : 'Somente administradores podem gerenciar usuários.']);
            return true;
        }
        $me = $sess['username'];
        $target = null;
        if (preg_match('#^/api/users/([^/]+)$#', $path, $um)) {
            $target = strtolower(rawurldecode($um[1]));
        }

        // Listar
        if ($target === null && $method === 'GET') {
            $list = array_map('publicUser', array_values($users));
            usort($list, fn($a, $b) => strcmp($a['username'], $b['username']));
            $reply(200, ['ok' => true, 'users' => $list]);
            return true;
        }

        // Criar
        if ($target === null && $method === 'POST') {
            $uname = strtolower(trim((string)($body['username'] ?? '')));
            $role = (string)($body['role'] ?? 'viewer');
            $pw = (string)($body['password'] ?? '');
            $name = safeUtf8(trim((string)($body['name'] ?? '')));
            if (!validUsername($uname)) {
                $reply(400, ['ok' => false, 'error' => 'Usuário inválido (3-32 caracteres: letras minúsculas, números, . _ -).']);
                return true;
            }
            if (isset($users[$uname])) {
                $reply(409, ['ok' => false, 'error' => 'Já existe um usuário com esse login.']);
                return true;
            }
            if (roleRank($role) === 0) {
                $reply(400, ['ok' => false, 'error' => 'Perfil inválido.']);
                return true;
            }
            if (($pp = passwordProblem($pw)) !== null) {
                $reply(400, ['ok' => false, 'error' => $pp]);
                return true;
            }
            $users[$uname] = [
                'username' => $uname,
                'name' => $name !== '' ? mb_substr($name, 0, 80) : $uname,
                'role' => $role,
                'password_hash' => password_hash($pw, PASSWORD_BCRYPT, ['cost' => 10]),
                'active' => true,
                'must_change' => !isset($body['must_change']) || !empty($body['must_change']),
                'tv' => 1,
                'created_at' => time(),
                'last_login' => null
            ];
            saveUsers();
            auditLog($me, 'user_create', "target={$uname} role={$role}");
            $reply(201, ['ok' => true, 'user' => publicUser($users[$uname])]);
            return true;
        }

        // Atualizar
        if ($target !== null && $method === 'PUT') {
            if (!isset($users[$target])) {
                $reply(404, ['ok' => false, 'error' => 'Usuário não encontrado.']);
                return true;
            }
            $u = $users[$target];
            if (isset($body['name'])) {
                $nm = safeUtf8(trim((string)$body['name']));
                if ($nm !== '') $u['name'] = mb_substr($nm, 0, 80);
            }
            if (isset($body['role'])) {
                $role = (string)$body['role'];
                if (roleRank($role) === 0) {
                    $reply(400, ['ok' => false, 'error' => 'Perfil inválido.']);
                    return true;
                }
                if ($target === $me && $role !== $u['role']) {
                    $reply(400, ['ok' => false, 'error' => 'Você não pode alterar o seu próprio perfil.']);
                    return true;
                }
                $u['role'] = $role;
            }
            if (isset($body['active'])) {
                $act = !empty($body['active']);
                if ($target === $me && !$act) {
                    $reply(400, ['ok' => false, 'error' => 'Você não pode desativar a sua própria conta.']);
                    return true;
                }
                $u['active'] = $act;
            }
            if (isset($body['password']) && $body['password'] !== '') {
                $pw = (string)$body['password'];
                if (($pp = passwordProblem($pw)) !== null) {
                    $reply(400, ['ok' => false, 'error' => $pp]);
                    return true;
                }
                $u['password_hash'] = password_hash($pw, PASSWORD_BCRYPT, ['cost' => 10]);
                $u['must_change'] = ($target === $me) ? false : true;
                $u['tv'] = (int)($u['tv'] ?? 0) + 1;
            }
            if (($u['role'] !== 'admin' || empty($u['active'])) && $users[$target]['role'] === 'admin' && !empty($users[$target]['active'])
                && countActiveAdmins($target) < 1) {
                $reply(400, ['ok' => false, 'error' => 'É necessário manter pelo menos um administrador ativo.']);
                return true;
            }
            $privChanged = ($u['role'] !== $users[$target]['role']) || ($u['active'] !== !empty($users[$target]['active']));
            if ($privChanged) {
                $u['tv'] = (int)($u['tv'] ?? 0) + 1; // revoga sessões existentes
            }
            $users[$target] = $u;
            saveUsers();
            auditLog($me, 'user_update', "target={$target} role={$u['role']} active=" . (!empty($u['active']) ? '1' : '0') . (isset($body['password']) && $body['password'] !== '' ? ' password_reset=1' : ''));
            revalidateAuthSockets();
            $extra = [];
            if ($target === $me) {
                $tk = makeAuthToken($me, (int)$u['tv'], $sess['rem']);
                $extra[] = sessionCookieHeader($tk['token'], $tk['ttl'], $secure);
            }
            $reply(200, ['ok' => true, 'user' => publicUser($u)], $extra);
            return true;
        }

        // Excluir
        if ($target !== null && $method === 'DELETE') {
            if (!isset($users[$target])) {
                $reply(404, ['ok' => false, 'error' => 'Usuário não encontrado.']);
                return true;
            }
            if ($target === $me) {
                $reply(400, ['ok' => false, 'error' => 'Você não pode excluir a sua própria conta.']);
                return true;
            }
            if ($users[$target]['role'] === 'admin' && !empty($users[$target]['active']) && countActiveAdmins($target) < 1) {
                $reply(400, ['ok' => false, 'error' => 'É necessário manter pelo menos um administrador ativo.']);
                return true;
            }
            unset($users[$target]);
            saveUsers();
            auditLog($me, 'user_delete', "target={$target}");
            revalidateAuthSockets();
            $reply(200, ['ok' => true]);
            return true;
        }

        $reply(404, ['ok' => false, 'error' => 'Rota não encontrada.']);
        return true;
    }

    $reply(404, ['ok' => false, 'error' => 'Rota não encontrada.']);
    return true;
}

$DEFAULT_DNS_BLOCKLIST_FILE = $DATA_DIR . '/default_dns_blocklist.json';

function getDefaultInitialBlocklist(): array {
    return [
        'description' => 'Lista Padrao de Bloqueio DNS do Floresta Controller',
        'updated_at' => time(),
        'domains' => [
            // Casas de Apostas / Bets
            'bet365.com',
            'betano.com',
            'betfair.com',
            'sportingbet.com',
            'pixbet.com',
            'blaze.com',
            'kto.com',
            'estrelabet.com',
            'apostaganha.bet',
            'novibet.com',
            'vaidebet.com',
            'superbet.com',
            'parimatch.com',
            '1xbet.com',
            'bodog.com',
            'rivalo.com',
            'casasdeapostas.com',
            'f12.bet',
            'jogodobicho.com',
            // Conteudo Adulto / Nocivo
            'xvideos.com',
            'pornhub.com',
            'xnxx.com',
            'redtube.com',
            'erome.com'
        ]
    ];
}

function loadDefaultDnsBlocklist(): array {
    global $DEFAULT_DNS_BLOCKLIST_FILE;
    if (file_exists($DEFAULT_DNS_BLOCKLIST_FILE)) {
        $raw = file_get_contents($DEFAULT_DNS_BLOCKLIST_FILE);
        $data = @json_decode($raw, true);
        if (!is_array($data)) {
            $cleanRaw = safeUtf8($raw);
            $data = @json_decode($cleanRaw, true);
        }
        if (is_array($data) && isset($data['domains']) && is_array($data['domains'])) {
            $data['domains'] = safeUtf8($data['domains']);
            return $data;
        }
    }
    $initial = getDefaultInitialBlocklist();
    saveDefaultDnsBlocklist($initial);
    return $initial;
}

function saveDefaultDnsBlocklist(array $data): void {
    global $DEFAULT_DNS_BLOCKLIST_FILE;
    @file_put_contents($DEFAULT_DNS_BLOCKLIST_FILE, safeJsonEncode($data, JSON_PRETTY_PRINT));
}

$defaultDnsBlocklist = loadDefaultDnsBlocklist();

// ============================================================================
// HISTÓRICO DE TELEMETRIA E DISPONIBILIDADE (ATÉ 365 DIAS / INTERVALOS DE 10 MIN)
// Cada ponto = [bucket_ts, online(0|1), clients_count, mem_free_mb, cpu_load_1m]
// ============================================================================
$HISTORY_DIR = $DATA_DIR . '/history';
$HISTORY_INTERVAL = 600;          // 10 minutos (600 segundos)
$HISTORY_MAX_AGE = 365 * 86400;   // 365 dias
if (!is_dir($HISTORY_DIR)) {
    @mkdir($HISTORY_DIR, 0777, true);
}

$routerHistory = [];          // mac => [ bucketTs => [ts, online, clients, mem, cpu] ]
$historyDirty = [];           // mac => bool
$historyLastSavedBucket = []; // mac => int
$historyLastFlushTime = [];   // mac => int

function getRouterHistoryFile(string $mac): string {
    global $HISTORY_DIR;
    return $HISTORY_DIR . '/history_' . cleanMac($mac) . '.json';
}

function loadRouterHistory(string $mac): array {
    global $routerHistory, $HISTORY_MAX_AGE;
    $mac = normalizeMac($mac);
    if (isset($routerHistory[$mac])) {
        return $routerHistory[$mac];
    }
    $routerHistory[$mac] = [];
    $file = getRouterHistoryFile($mac);
    if (file_exists($file)) {
        $raw = @file_get_contents($file);
        $data = @json_decode((string)$raw, true);
        $points = is_array($data['points'] ?? null) ? $data['points'] : (is_array($data) ? $data : []);
        $cutoff = time() - $HISTORY_MAX_AGE;
        foreach ($points as $pt) {
            if (is_array($pt) && isset($pt[0]) && (int)$pt[0] >= $cutoff) {
                $bTs = (int)$pt[0];
                $routerHistory[$mac][$bTs] = [
                    $bTs,
                    (int)($pt[1] ?? 0),
                    (int)($pt[2] ?? 0),
                    (int)($pt[3] ?? 0),
                    round((float)($pt[4] ?? 0.0), 2)
                ];
            }
        }
        ksort($routerHistory[$mac]);
    }
    return $routerHistory[$mac];
}

function saveRouterHistory(string $mac): void {
    global $routerHistory, $historyDirty, $historyLastFlushTime, $HISTORY_MAX_AGE;
    $mac = normalizeMac($mac);
    if (!isset($routerHistory[$mac])) return;

    $cutoff = time() - $HISTORY_MAX_AGE;
    foreach ($routerHistory[$mac] as $bTs => $pt) {
        if ($bTs < $cutoff) {
            unset($routerHistory[$mac][$bTs]);
        }
    }
    ksort($routerHistory[$mac]);

    $file = getRouterHistoryFile($mac);
    $payload = [
        'mac' => $mac,
        'interval_sec' => 600,
        'updated_at' => time(),
        'points' => array_values($routerHistory[$mac])
    ];
    @file_put_contents($file, json_encode($payload, JSON_UNESCAPED_SLASHES));
    $historyDirty[$mac] = false;
    $historyLastFlushTime[$mac] = time();
}

function recordRouterHistoryPoint(string $mac, bool $online, ?array $telemetry = null, bool $forceFlush = false): void {
    global $routerHistory, $historyDirty, $historyLastSavedBucket, $historyLastFlushTime, $HISTORY_INTERVAL;
    $mac = normalizeMac($mac);
    if (!$mac || $mac === 'UNKNOWN_MAC') return;

    loadRouterHistory($mac);
    $now = time();
    $bucketTs = (int)(floor($now / $HISTORY_INTERVAL) * $HISTORY_INTERVAL);

    $clientsCount = 0;
    $memFree = 0;
    $cpuLoad = 0.0;
    if ($online && is_array($telemetry)) {
        $sessions = (isset($telemetry['sessions']['sessions']) && is_array($telemetry['sessions']['sessions']))
            ? $telemetry['sessions']['sessions']
            : ((isset($telemetry['sessions']) && is_array($telemetry['sessions'])) ? $telemetry['sessions'] : []);
        $clientsCount = isset($telemetry['auth_count']) ? (int)$telemetry['auth_count'] : count($sessions);
        $memFree = (int)($telemetry['mem_free_mb'] ?? 0);
        $cpuLoad = isset($telemetry['loadavg'][0]) ? round((float)$telemetry['loadavg'][0], 2) : 0.0;
    }

    $isNewBucket = !isset($routerHistory[$mac][$bucketTs]);
    if ($isNewBucket) {
        $routerHistory[$mac][$bucketTs] = [
            $bucketTs,
            $online ? 1 : 0,
            $online ? $clientsCount : 0,
            $online ? $memFree : 0,
            $online ? $cpuLoad : 0.0
        ];
        $historyDirty[$mac] = true;
    } else {
        $prev = $routerHistory[$mac][$bucketTs];
        if ($online) {
            $newClients = ($prev[1] === 0) ? $clientsCount : max((int)$prev[2], $clientsCount);
            $newMem = $memFree > 0 ? $memFree : (int)$prev[3];
            $newCpu = $cpuLoad > 0 ? $cpuLoad : (float)$prev[4];
            $updated = [$bucketTs, 1, $newClients, $newMem, $newCpu];
            if ($updated !== $prev) {
                $routerHistory[$mac][$bucketTs] = $updated;
                $historyDirty[$mac] = true;
            }
        }
    }

    if ($forceFlush || $isNewBucket || (($historyLastSavedBucket[$mac] ?? 0) !== $bucketTs)) {
        saveRouterHistory($mac);
        $historyLastSavedBucket[$mac] = $bucketTs;
    } elseif (!empty($historyDirty[$mac]) && ($now - ($historyLastFlushTime[$mac] ?? 0) >= 300)) {
        saveRouterHistory($mac);
    }
}

foreach ($adoptedDevices as $initMac => $initInfo) {
    loadRouterHistory($initMac);
}

echo "========================================================\n";
echo "   Conexao Povos da Floresta - Cloud Controller (PHP)   \n";
echo "   Inspirado no Ubiquiti UniFi (WebSockets / Sem VPN)   \n";
echo "========================================================\n";
echo "[*] Servidor iniciando em http://{$HOST}:{$PORT} ...\n";

$server = @stream_socket_server("tcp://{$HOST}:{$PORT}", $errno, $errstr);
if (!$server) {
    fwrite(STDERR, "[FALHA] Nao foi possivel abrir porta {$PORT}: $errstr ($errno)\n");
    exit(1);
}

stream_set_blocking($server, false);

echo "[OK] Servidor ativo! Acesse no navegador: http://localhost:{$PORT}\n";
echo "[*] Dispositivos adotados na base: " . count($adoptedDevices) . "\n";
echo "[*] Aguardando conexoes de roteadores e administradores...\n\n";

$clients = [];
$clientMeta = [];
$routers = [];      // mac => clientId
$adminSockets = []; // id => true

// ============================================================================
// GERENCIADOR DE TÚNEIS TCP (MODELO A - WEBSOCKET REVERSE PROXY)
// ============================================================================
$tunnelServers = [];    // mac => ['socket' => resource, 'port' => 8085, 'created_at' => timestamp, 'last_activity' => timestamp]
$tunnelClients = [];    // clientId => ['mac' => $mac, 'tunnel_id' => $seqId]
$macTunnelMap = [];     // mac => [ $seqId => clientId ]
$nextTunnelSeq = 1;

function findFreeTunnelPort(int $startPort = 8085): int {
    global $tunnelServers;
    $usedPorts = array_column($tunnelServers, 'port');
    for ($p = $startPort; $p < $startPort + 50; $p++) {
        if (in_array($p, $usedPorts, true)) continue;
        $t = @stream_socket_server("tcp://0.0.0.0:{$p}", $errno, $errstr);
        if ($t) {
            fclose($t);
            return $p;
        }
    }
    return $startPort;
}

function startWebTunnel(string $targetMac): array {
    global $routers;
    $targetMac = normalizeMac($targetMac);

    if (!isset($routers[$targetMac])) {
        return ['ok' => false, 'error' => 'Roteador offline ou não conectado'];
    }

    $cMac = cleanMac($targetMac);
    echo "[✓] TÚNEL HTTP PRONTO: MAC={$targetMac} via /select-router?mac={$cMac}\n";
    return [
        'ok' => true,
        'mac' => $targetMac,
        'port' => 443,
        'url' => "/select-router?mac={$cMac}",
        'already_active' => true
    ];
}

function stopWebTunnel(string $targetMac): bool {
    global $tunnelServers, $macTunnelMap, $clients, $clientMeta, $tunnelClients, $routers;
    $targetMac = normalizeMac($targetMac);

    if (!isset($tunnelServers[$targetMac])) {
        return false;
    }

    $tSock = $tunnelServers[$targetMac]['socket'];
    if (is_resource($tSock)) {
        @fclose($tSock);
    }

    if (isset($macTunnelMap[$targetMac])) {
        foreach ($macTunnelMap[$targetMac] as $seq => $cid) {
            if (isset($clients[$cid])) {
                @fclose($clients[$cid]);
                unset($clients[$cid], $clientMeta[$cid], $tunnelClients[$cid]);
            }
            if (isset($routers[$targetMac]) && isset($clients[$routers[$targetMac]])) {
                sendToClient($clients[$routers[$targetMac]], json_encode([
                    'type' => 'tcp_tunnel_close',
                    'tunnel_id' => $seq
                ]));
            }
        }
    }

    unset($tunnelServers[$targetMac], $macTunnelMap[$targetMac]);
    echo "[x] TÚNEL TCP ENCERRADO: MAC={$targetMac}\n";
    return true;
}

function closeClient(int $cid, bool $notifyRouter = true): void {
    global $clients, $clientMeta, $routers, $adminSockets, $tunnelClients, $macTunnelMap;

    if (!isset($clients[$cid]) && !isset($clientMeta[$cid])) {
        return;
    }

    $meta = $clientMeta[$cid] ?? [];
    $type = $meta['type'] ?? 'unknown';
    $mac = $meta['mac'] ?? null;

    if ($type === 'router' && $mac) {
        if (($routers[$mac] ?? null) === $cid) {
            echo "[-] ROTEADOR DESCONECTADO: MAC={$mac} (ID: {$cid})\n";
            unset($routers[$mac]);
            stopWebTunnel($mac);
            broadcastToAdmins(['event' => 'router_offline', 'mac' => $mac]);
        }
    } elseif ($type === 'terminal') {
        echo "[x] TERMINAL FECHADO (ID: {$cid})\n";
        if ($notifyRouter && $mac && isset($routers[$mac]) && isset($clients[$routers[$mac]])) {
            sendToClient($clients[$routers[$mac]], json_encode([
                'type' => 'term_stop',
                'term_id' => $cid
            ]));
        }
    } elseif ($type === 'admin') {
        unset($adminSockets[$cid]);
    } elseif ($type === 'http_tunnel' || $type === 'tcp_tunnel') {
        $tSeq = $meta['tunnel_id'] ?? 0;
        if ($mac && $tSeq) {
            if (isset($macTunnelMap[$mac][$tSeq])) {
                unset($macTunnelMap[$mac][$tSeq]);
            }
            if ($notifyRouter && isset($routers[$mac]) && isset($clients[$routers[$mac]])) {
                sendToClient($clients[$routers[$mac]], json_encode([
                    'type' => 'tcp_tunnel_close',
                    'tunnel_id' => $tSeq
                ]));
            }
        }
        unset($tunnelClients[$cid]);
    }

    if (isset($clients[$cid])) {
        if (is_resource($clients[$cid])) {
            // Se for conexão HTTP que está fechando antes de emitir qualquer resposta ao cliente,
            // emite status 504 limpo com Content-Length para evitar erro 503 ("malformed response") do Cloud Run.
            if (($type === 'http' || $type === 'http_tunnel') && empty($meta['headers_done']) && empty($meta['headers_sent']) && empty($meta['html_sent'])) {
                $errBody = "Gateway Timeout: Router did not respond in time";
                $errResp = "HTTP/1.1 504 Gateway Timeout\r\nContent-Type: text/plain\r\nContent-Length: " . strlen($errBody) . "\r\nConnection: close\r\n\r\n" . $errBody;
                @fwrite($clients[$cid], $errResp);
            }
            @fclose($clients[$cid]);
        }
        unset($clients[$cid]);
    }
    unset($clientMeta[$cid]);
}

function generateWsKey(string $key): string {
    return base64_encode(sha1($key . '258EAFA5-E914-47DA-95CA-C5AB0DC85B11', true));
}

function wsEncode(string $payload, int $type = 1): string {
    $length = strlen($payload);
    $header = chr(0x80 | ($type & 0x0f));

    if ($length < 126) {
        $header .= chr($length);
    } elseif ($length <= 0xffff) {
        $header .= chr(126) . pack('n', $length);
    } else {
        $header .= chr(127) . pack('J', $length);
    }

    return $header . $payload;
}

function wsDecode(string &$buffer): ?array {
    $bufLen = strlen($buffer);
    if ($bufLen < 2) return null;

    $b0 = ord($buffer[0]);
    $b1 = ord($buffer[1]);
    $fin = ($b0 & 0x80) !== 0;
    $opcode = $b0 & 0x0f;
    $masked = ($b1 & 0x80) !== 0;
    $payloadLen = $b1 & 0x7f;

    $offset = 2;
    if ($payloadLen === 126) {
        if ($bufLen < 4) return null;
        $payloadLen = unpack('n', substr($buffer, 2, 2))[1];
        $offset = 4;
    } elseif ($payloadLen === 127) {
        if ($bufLen < 10) return null;
        $payloadLen = unpack('J', substr($buffer, 2, 8))[1];
        $offset = 10;
    }

    $maskKey = '';
    if ($masked) {
        if ($bufLen < $offset + 4) return null;
        $maskKey = substr($buffer, $offset, 4);
        $offset += 4;
    }

    if ($bufLen < $offset + $payloadLen) return null;

    $payload = substr($buffer, $offset, $payloadLen);
    $buffer = substr($buffer, $offset + $payloadLen);

    if ($masked && $maskKey !== '') {
        $unmasked = '';
        for ($i = 0; $i < $payloadLen; $i++) {
            $unmasked .= chr(ord($payload[$i]) ^ ord($maskKey[$i % 4]));
        }
        $payload = $unmasked;
    }

    return ['opcode' => $opcode, 'payload' => $payload, 'fin' => $fin];
}

function sendToClient($socket, mixed $data, int $type = 1): bool {
    if (!is_resource($socket)) return false;
    if (!is_string($data)) {
        if (is_array($data)) {
            $data = safeJsonEncode($data);
        } elseif ($data === false || $data === null) {
            return false;
        } else {
            $data = (string)$data;
        }
    }
    $frame = wsEncode($data, $type);
    $len = strlen($frame);
    $written = 0;
    $retries = 0;
    while ($written < $len && $retries < 50) {
        $n = @fwrite($socket, substr($frame, $written));
        if ($n === false) {
            return false;
        }
        if ($n === 0) {
            $retries++;
            usleep(1000); // 1ms
            continue;
        }
        $written += $n;
    }
    return $written >= $len;
}

function broadcastToAdmins(array $msg): void {
    global $adminSockets, $clients;
    $json = safeJsonEncode($msg);
    foreach (array_keys($adminSockets) as $adminId) {
        if (isset($clients[$adminId])) {
            sendToClient($clients[$adminId], $json);
        }
    }
}

function processHtmlTunnelResponse(string $buf, string $cleanMac): string {
    if (strpos($buf, "\r\n\r\n") === false) {
        return $buf;
    }
    [$rawHeaders, $rawBody] = explode("\r\n\r\n", $buf, 2);

    $isGzip = (stripos($rawHeaders, 'Content-Encoding: gzip') !== false)
        || (substr($rawBody, 0, 2) === "\x1f\x8b");

    $html = $isGzip ? @gzdecode($rawBody) : $rawBody;
    if ($html === false) {
        $html = $rawBody;
        $isGzip = false;
    }

    $isDoc = (stripos($html, '<html') !== false || stripos($html, '<head') !== false || stripos($html, '<!DOCTYPE') !== false || stripos($html, '<body') !== false);

    if ($isDoc) {
        $badgeHtml = "<div id='floresta-badge' style='position:fixed;top:12px;right:16px;z-index:9999999;background:rgba(15,23,42,0.92);backdrop-filter:blur(10px);border:1px solid rgba(255,255,255,0.2);box-shadow:0 8px 32px rgba(0,0,0,0.4);padding:6px 14px;border-radius:24px;font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,sans-serif;font-size:12px;display:flex;align-items:center;gap:10px;color:#f8fafc;pointer-events:auto;user-select:none;'>" .
            "<span style='display:inline-block;width:8px;height:8px;border-radius:50%;background:#10b981;box-shadow:0 0 8px #10b981;'></span>" .
            "<span style='font-weight:600;letter-spacing:0.3px;'>BE220 ({$cleanMac})</span>" .
            "<a href='/dashboard' style='color:#38bdf8;text-decoration:none;font-weight:600;padding-left:10px;border-left:1px solid rgba(255,255,255,0.25);transition:all 0.2s;'>&larr; Painel Geral</a>" .
            "<a href='/exit-router' title='Desconectar deste roteador' style='color:#f43f5e;text-decoration:none;font-size:14px;line-height:1;padding-left:4px;cursor:pointer;'>&times;</a>" .
            "</div>";

        if (stripos($html, '</body>') !== false) {
            $html = str_ireplace('</body>', $badgeHtml . '</body>', $html);
        } else {
            $html .= $badgeHtml;
        }
    }

    $newBody = $isGzip ? gzencode($html) : $html;

    $headerLines = explode("\r\n", $rawHeaders);
    $newHeaderLines = [];
    foreach ($headerLines as $hline) {
        if (empty(trim($hline))) continue;
        if (stripos($hline, 'Content-Length:') === 0) continue;
        if (stripos($hline, 'X-Frame-Options:') === 0) continue;
        if (stripos($hline, 'Content-Security-Policy:') === 0) continue;
        if (stripos($hline, 'ETag:') === 0) continue;
        if (stripos($hline, 'Last-Modified:') === 0) continue;
        if (stripos($hline, 'Cache-Control:') === 0) continue;
        if (stripos($hline, 'Location:') === 0) {
            $hline = preg_replace('/Location:\s*https?:\/\/(?:192\.168\.0\.1|127\.0\.0\.1)(?::[0-9]+)?/i', 'Location: ', $hline);
        }
        $newHeaderLines[] = $hline;
    }

    $newHeaderLines[] = "Cache-Control: no-cache, no-store, must-revalidate";
    $newHeaderLines[] = "Pragma: no-cache";
    $newHeaderLines[] = "Expires: 0";
    $newHeaderLines[] = "Content-Length: " . strlen($newBody);

    return implode("\r\n", $newHeaderLines) . "\r\n\r\n" . $newBody;
}


function serveStaticFile($conn, int $clientId, string $fullPath): void {
    global $clients, $clientMeta, $PUBLIC_DIR;

    $filePath = is_file($fullPath) ? realpath($fullPath) : false;
    // Anti path-traversal: o arquivo precisa residir dentro de public/
    $publicReal = realpath($PUBLIC_DIR);
    if ($filePath && (!$publicReal || strpos($filePath, $publicReal . DIRECTORY_SEPARATOR) !== 0)) {
        $filePath = false;
    }
    if ($filePath && is_file($filePath)) {
        $ext = strtolower(pathinfo($filePath, PATHINFO_EXTENSION));
        $mimeTypes = [
            'html' => 'text/html; charset=utf-8',
            'css'  => 'text/css; charset=utf-8',
            'js'   => 'application/javascript; charset=utf-8',
            'json' => 'application/json; charset=utf-8',
            'svg'  => 'image/svg+xml',
            'png'  => 'image/png',
            'jpg'  => 'image/jpeg',
            'ico'  => 'image/x-icon'
        ];
        $ctype = $mimeTypes[$ext] ?? 'application/octet-stream';
        $content = file_get_contents($filePath);
        $len = strlen($content);

        $resp = "HTTP/1.1 200 OK\r\n" .
                "Content-Type: {$ctype}\r\n" .
                "Content-Length: {$len}\r\n" .
                "Cache-Control: no-cache, no-store, must-revalidate\r\n" .
                "Pragma: no-cache\r\n" .
                "Connection: close\r\n\r\n" .
                $content;
        @fwrite($conn, $resp);
    } else {
        $body = "404 Not Found: " . htmlspecialchars(basename($fullPath));
        $resp = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: " . strlen($body) . "\r\nConnection: close\r\n\r\n" . $body;
        @fwrite($conn, $resp);
    }

    @fclose($conn);
    unset($clients[$clientId], $clientMeta[$clientId]);
}

function handleHttpRequest($conn, int $clientId, string $buffer): void {
    global $PUBLIC_DIR, $clients, $clientMeta, $routers, $adminSockets, $adoptedDevices, $tunnelServers, $macTunnelMap, $tunnelClients, $nextTunnelSeq, $defaultDnsBlocklist;

    [$headerPart, $reqBody] = explode("\r\n\r\n", $buffer, 2) + ['', ''];
    $headers = [];
    $lines = explode("\r\n", $headerPart);
    $reqLine = array_shift($lines);
    if (!preg_match('#^(GET|POST|PUT|DELETE|HEAD)\s+(.+?)\s+HTTP/1\.[01]#i', $reqLine, $m)) {
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    $method = strtoupper($m[1]);
    $rawUri = $m[2];
    $uriParts = parse_url($rawUri);
    $path = $uriParts['path'] ?? '/';
    parse_str($uriParts['query'] ?? '', $query);

    foreach ($lines as $line) {
        if (strpos($line, ':') !== false) {
            [$k, $v] = explode(':', $line, 2);
            $headers[strtolower(trim($k))] = trim($v);
        }
    }

    $cookies = parseCookies($headers['cookie'] ?? '');

    // Handshake WebSocket
    if (isset($headers['upgrade']) && strtolower($headers['upgrade']) === 'websocket') {
        $wsKey = $headers['sec-websocket-key'] ?? '';
        if (!$wsKey) {
            @fwrite($conn, "HTTP/1.1 400 Bad Request\r\n\r\n");
            @fclose($conn);
            unset($clients[$clientId], $clientMeta[$clientId]);
            return;
        }

        // Autenticação do canal WS (exceto /ws/router, usado pelos roteadores via cabeçalhos X-Device-*)
        $wsSess = null;
        if (strpos($path, '/ws/router') !== 0) {
            $wsSess = authenticate($cookies);
            $wsMin = (strpos($path, '/ws/terminal') === 0) ? 'operator' : 'viewer';
            if (!sameOriginOk($headers) || !hasRole($wsSess, $wsMin)) {
                $denyCode = $wsSess ? '403 Forbidden' : '401 Unauthorized';
                @fwrite($conn, "HTTP/1.1 {$denyCode}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                @fclose($conn);
                unset($clients[$clientId], $clientMeta[$clientId]);
                return;
            }
        }

        $acceptKey = generateWsKey($wsKey);
        $resp = "HTTP/1.1 101 Switching Protocols\r\n" .
                "Upgrade: websocket\r\n" .
                "Connection: Upgrade\r\n" .
                "Sec-WebSocket-Accept: {$acceptKey}\r\n\r\n";
        @fwrite($conn, $resp);

        // Identifica canal WebSocket
        if (strpos($path, '/ws/router') === 0) {
            $rawMac = $headers['x-device-mac'] ?? ($query['mac'] ?? 'UNKNOWN_MAC');
            $mac = normalizeMac($rawMac);

            $reportedAdopted = ($headers['x-device-adopted'] ?? ($query['adopted'] ?? '0')) === '1'
                || ($headers['x-device-adopted'] ?? '') === 'true'
                || ($query['adopted'] ?? '') === 'true';

            $reportedName = $headers['x-device-name'] ?? ($query['name'] ?? null);
            if ($reportedName) {
                $reportedName = safeUtf8(urldecode(trim($reportedName)));
            }

            // Sincroniza com o arquivo em disco
            $freshAdopted = loadAdoptedDevices();
            foreach ($freshAdopted as $fk => $fv) {
                $adoptedDevices[$fk] = $fv;
            }

            $isAdopted = isset($adoptedDevices[$mac]);

            // AUTO-RESTAURAÇÃO / AUTO-HEALING:
            // Se o roteador possui no hardware a marca de adotado (sobreviveu a reboot do Cloud Run),
            // restaura a adoção na base do servidor automaticamente.
            if (!$isAdopted && $reportedAdopted) {
                $isAdopted = true;
                $adoptedDevices[$mac] = [
                    'name' => $reportedName ?: 'Archer BE220',
                    'adopted_at' => time()
                ];
                saveAdoptedDevices($adoptedDevices);
                echo "[✓] ROTEADOR AUTO-RESTAURADO COMO ADOTADO (credenciais do hardware): MAC={$mac}\n";
            }

            if ($isAdopted) {
                $savedName = safeUtf8($adoptedDevices[$mac]['name'] ?? null);
                $isSavedGeneric = empty($savedName) || $savedName === 'BE220' || $savedName === 'Archer BE220' || strpos($savedName, 'Archer BE220 - Polo') === 0;

                if (!$isSavedGeneric) {
                    $deviceName = $savedName;
                } elseif ($reportedName && $reportedName !== 'BE220' && $reportedName !== 'Archer BE220' && strpos($reportedName, 'Archer BE220 - Polo') !== 0) {
                    $deviceName = $reportedName;
                    $adoptedDevices[$mac]['name'] = $deviceName;
                    saveAdoptedDevices($adoptedDevices);
                } else {
                    $deviceName = $savedName ?: ($reportedName ?: 'Archer BE220');
                }
            } else {
                $deviceName = $reportedName ?: 'Archer BE220 (Pendente)';
            }
            $deviceName = safeUtf8($deviceName);

            $clientMeta[$clientId] = [
                'type' => 'router',
                'mac' => $mac,
                'name' => $deviceName,
                'adopted' => $isAdopted,
                'buf' => '',
                'connected_at' => time(),
                'last_ping' => time(),
                'telemetry' => []
            ];
            if (isset($routers[$mac]) && $routers[$mac] !== $clientId) {
                $oldCid = $routers[$mac];
                echo "[!] Roteador {$mac} reconectou (novo ID: {$clientId}, fechando anterior: {$oldCid})\n";
                closeClient($oldCid);
            }
            $routers[$mac] = $clientId;

            // Se houver sessões de terminal ativas no navegador para este MAC, reconecta-as ao novo socket do roteador
            foreach ($clientMeta as $tCid => $tMeta) {
                if (($tMeta['type'] ?? '') === 'terminal' && ($tMeta['mac'] ?? '') === $mac) {
                    echo "[>] REANEXANDO TERMINAL ATIVO {$tCid} ao novo socket do roteador {$clientId} (MAC={$mac})\n";
                    sendToClient($conn, json_encode([
                        'type' => 'term_start',
                        'term_id' => $tCid
                    ]));
                }
            }

            if ($isAdopted) {
                echo "[+] ROTEADOR ADOTADO ONLINE: MAC={$mac} (Nome: {$deviceName})\n";
                broadcastToAdmins([
                    'event' => 'router_online',
                    'mac' => $mac,
                    'name' => $deviceName,
                    'adopted' => true,
                    'connected_at' => time()
                ]);

                // Sincroniza nome de volta para o roteador se o roteador informou um nome desatualizado
                if ($reportedName && $reportedName !== $deviceName) {
                    sendToClient($conn, safeJsonEncode([
                        'type' => 'set_adopted',
                        'adopted' => true,
                        'name' => $deviceName
                    ]));
                }

                // Envia sincronizacao de bloqueio DNS inicial caso o roteador possua regras configuradas
                if (!empty($adoptedDevices[$mac]['dns_blocklist']) && is_array($adoptedDevices[$mac]['dns_blocklist'])) {
                    echo "[+] Enviando lista de bloqueio DNS persistida para {$mac} (" . count($adoptedDevices[$mac]['dns_blocklist']) . " dominios)\n";
                    sendToClient($conn, safeJsonEncode([
                        'type' => 'command',
                        'cmd_id' => 'boot_dns_' . uniqid(),
                        'action' => 'dns_block_update',
                        'params' => [
                            'domains' => $adoptedDevices[$mac]['dns_blocklist']
                        ]
                    ]));
                } else {
                    // Se o servidor ainda não tem a lista DNS gravada para este roteador,
                    // consulta a Flash do próprio roteador para recuperar sem perdas
                    echo "[?] Consultando Flash do roteador {$mac} para recuperar lista DNS existente...\n";
                    sendToClient($conn, safeJsonEncode([
                        'type' => 'command',
                        'cmd_id' => 'boot_dns_get_' . uniqid(),
                        'action' => 'dns_block_get'
                    ]));
                }
            } else {
                echo "[!] NOVO ROTEADOR AGUARDANDO ADOCAO: MAC={$mac} (Nome: {$deviceName})\n";
                broadcastToAdmins([
                    'event' => 'router_pending',
                    'mac' => $mac,
                    'name' => $deviceName,
                    'adopted' => false,
                    'connected_at' => time()
                ]);
            }
        } elseif (strpos($path, '/ws/terminal') === 0) {
            $mac = normalizeMac($query['mac'] ?? '');
            $clientMeta[$clientId] = [
                'type' => 'terminal',
                'mac' => $mac,
                'buf' => '',
                'user' => $wsSess['username'],
                'tv' => (int)($wsSess['user']['tv'] ?? 0),
                'sess_exp' => $wsSess['exp']
            ];
            auditLog($wsSess['username'], 'terminal_open', $mac);
            echo "[>] TERMINAL WEB ABERTO para MAC={$mac} (ID: {$clientId})\n";
            if ($mac && isset($routers[$mac]) && isset($clients[$routers[$mac]])) {
                sendToClient($clients[$routers[$mac]], json_encode([
                    'type' => 'term_start',
                    'term_id' => $clientId
                ]));
            }
        } else {
            // Canal Admin (Dashboard Web)
            $clientMeta[$clientId] = [
                'type' => 'admin',
                'buf' => '',
                'user' => $wsSess['username'],
                'tv' => (int)($wsSess['user']['tv'] ?? 0),
                'sess_exp' => $wsSess['exp']
            ];
            $adminSockets[$clientId] = true;
            echo "[*] ADMIN CONECTADO AO DASHBOARD (ID: {$clientId})\n";

            // Sincroniza com a base em disco mais recente
            $freshAdopted = loadAdoptedDevices();
            foreach ($freshAdopted as $fk => $fv) {
                $adoptedDevices[$fk] = $fv;
            }

            $adoptedList = [];
            $pendingList = [];

            foreach ($routers as $rmac => $rid) {
                if (isset($clientMeta[$rid])) {
                    $isAd = ($clientMeta[$rid]['adopted'] ?? false) || isset($adoptedDevices[$rmac]);
                    if ($isAd) {
                        $clientMeta[$rid]['adopted'] = true;
                    }
                    $telem = $clientMeta[$rid]['telemetry'] ?? null;
                    if ((empty($telem) || !is_array($telem) || count($telem) === 0) && isset($adoptedDevices[$rmac]['last_telemetry'])) {
                        $telem = $adoptedDevices[$rmac]['last_telemetry'];
                    }
                    $rInfo = [
                        'mac' => $rmac,
                        'name' => $clientMeta[$rid]['name'] ?? ($adoptedDevices[$rmac]['name'] ?? 'Archer BE220'),
                        'online' => true,
                        'adopted' => $isAd,
                        'connected_at' => $clientMeta[$rid]['connected_at'] ?? time(),
                        'telemetry' => $telem,
                        'dns_blocklist' => $adoptedDevices[$rmac]['dns_blocklist'] ?? []
                    ];
                    if ($isAd) {
                        $adoptedList[] = $rInfo;
                    } else {
                        $pendingList[] = $rInfo;
                    }
                }
            }

            // Inclui dispositivos adotados que estão offline
            foreach ($adoptedDevices as $amac => $ainfo) {
                if (!isset($routers[$amac])) {
                    $adoptedList[] = [
                        'mac' => $amac,
                        'name' => $ainfo['name'] ?? 'Archer BE220',
                        'online' => false,
                        'adopted' => true,
                        'connected_at' => null,
                        'telemetry' => $ainfo['last_telemetry'] ?? null,
                        'dns_blocklist' => $ainfo['dns_blocklist'] ?? []
                    ];
                }
            }

            $activeTunnelsList = [];
            foreach ($tunnelServers as $tMac => $tInfo) {
                $activeTunnelsList[$tMac] = $tInfo['port'];
            }

            sendToClient($conn, safeJsonEncode([
                'event' => 'init_state',
                'routers' => $adoptedList,
                'pending' => $pendingList,
                'tunnels' => $activeTunnelsList,
                'default_dns_blocklist' => $defaultDnsBlocklist['domains'] ?? []
            ]));
        }

        return;
    }

    // ========================================================================
    // ROTAS HTTP DO CLOUD CONTROLLER E PROXY TRANSPARENTE (OPÇÃO A)
    // A interface do roteador reside diretamente na raiz (/) usando sessão por cookie
    // ========================================================================

    // Sessão do usuário (cookie fl_session) + rotas de autenticação/usuários
    $sess = authenticate($cookies);
    if (handleAuthApi($conn, $clientId, $method, $path, $headers, $reqBody, $sess)) {
        return;
    }

    // 0. Rota API Bloqueio DNS (/api/router/dns-blocklist?mac=...)
    if (strpos($path, '/api/router/dns-blocklist') === 0) {
        if (!requireHttpRole($conn, $clientId, $sess, 'viewer')) return;
        $reqMac = !empty($query['mac']) ? normalizeMac($query['mac']) : null;
        $domains = [];
        if ($reqMac && isset($adoptedDevices[$reqMac]['dns_blocklist'])) {
            $domains = $adoptedDevices[$reqMac]['dns_blocklist'];
        } else {
            $domains = $defaultDnsBlocklist['domains'] ?? [];
        }
        $respBody = json_encode([
            'ok' => true,
            'mac' => $reqMac,
            'domains' => $domains,
            'count' => count($domains),
            'updated_at' => time()
        ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);

        $resp = "HTTP/1.1 200 OK\r\n" .
                "Content-Type: application/json; charset=utf-8\r\n" .
                "Content-Length: " . strlen($respBody) . "\r\n" .
                "Access-Control-Allow-Origin: *\r\n" .
                "Connection: close\r\n\r\n" . $respBody;
        @fwrite($conn, $resp);
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    // 0.05 Rota API Histórico de Telemetria 365 Dias (/api/router/history?mac=...&days=...)
    if (strpos($path, '/api/router/history') === 0) {
        if (!requireHttpRole($conn, $clientId, $sess, 'viewer')) return;
        $reqMac = !empty($query['mac']) ? normalizeMac((string)$query['mac']) : '';
        $days = isset($query['days']) ? max(1, min(365, (int)$query['days'])) : 7;

        if (!$reqMac) {
            $errBody = json_encode(['ok' => false, 'error' => 'MAC obrigatorio']);
            $resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: " . strlen($errBody) . "\r\nConnection: close\r\n\r\n" . $errBody;
            @fwrite($conn, $resp);
            @fclose($conn);
            unset($clients[$clientId], $clientMeta[$clientId]);
            return;
        }

        $isOn = isset($routers[$reqMac]) && isset($clients[$routers[$reqMac]]);
        $curTelem = null;
        if ($isOn) {
            $rid = $routers[$reqMac];
            $curTelem = $clientMeta[$rid]['telemetry'] ?? ($adoptedDevices[$reqMac]['last_telemetry'] ?? null);
        }
        recordRouterHistoryPoint($reqMac, $isOn, $curTelem, false);

        $allMap = loadRouterHistory($reqMac);
        $cutoff = time() - ($days * 86400);
        $points = [];
        foreach ($allMap as $bTs => $pt) {
            if ($bTs >= $cutoff) {
                $points[] = $pt;
            }
        }

        $rName = $adoptedDevices[$reqMac]['name'] ?? 'Archer BE220';
        if ($isOn && !empty($clientMeta[$routers[$reqMac]]['name'])) {
            $rName = $clientMeta[$routers[$reqMac]]['name'];
        }

        $respBody = safeJsonEncode([
            'ok' => true,
            'mac' => $reqMac,
            'name' => $rName,
            'days' => $days,
            'interval_sec' => 600,
            'online_now' => $isOn,
            'points' => $points
        ]);

        $resp = "HTTP/1.1 200 OK\r\n" .
                "Content-Type: application/json; charset=utf-8\r\n" .
                "Content-Length: " . strlen($respBody) . "\r\n" .
                "Access-Control-Allow-Origin: *\r\n" .
                "Cache-Control: no-cache, no-store, must-revalidate\r\n" .
                "Connection: close\r\n\r\n" . $respBody;
        @fwrite($conn, $resp);
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    // 0.1 Rota de Turbo Upload (Upload direto HTTP para Cloud e Download acelerado pelo Roteador)
    if ($path === '/api/upload') {
        if (!sameOriginOk($headers) || !requireHttpRole($conn, $clientId, $sess, 'operator')) return;
        $token = 'up_' . bin2hex(random_bytes(8));
        $rawFilename = $query['filename'] ?? 'upload.bin';
        $cleanName = preg_replace('/[^a-zA-Z0-9._-]/', '_', basename($rawFilename));
        if (empty($cleanName)) $cleanName = 'firmware.bin';

        $uploadDir = sys_get_temp_dir() . '/cloud_uploads';
        if (!is_dir($uploadDir)) {
            @mkdir($uploadDir, 0777, true);
        }
        $targetFile = $uploadDir . '/' . $token . '_' . $cleanName;

        // Salva corpo binário diretamente no arquivo temporário
        file_put_contents($targetFile, $reqBody);
        $fileSize = filesize($targetFile);

        $proto = (!empty($headers['x-forwarded-proto']) && $headers['x-forwarded-proto'] === 'https') ? 'https' : 'https';
        $host = $headers['host'] ?? '<CONTROLLER_HOST>';
        $downloadUrl = "{$proto}://{$host}/api/download?token={$token}&file=" . urlencode($cleanName);

        $respBody = json_encode([
            'ok' => true,
            'token' => $token,
            'filename' => $cleanName,
            'size' => $fileSize,
            'download_url' => $downloadUrl
        ]);
        $resp = "HTTP/1.1 200 OK\r\n" .
                "Content-Type: application/json; charset=utf-8\r\n" .
                "Content-Length: " . strlen($respBody) . "\r\n" .
                "Access-Control-Allow-Origin: *\r\n" .
                "Connection: close\r\n\r\n" . $respBody;
        @fwrite($conn, $resp);
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    // 0.2 Rota de Download Acelerado para o Roteador (Stream binário raw de alta vazão com Content-Length)
    if ($path === '/api/download') {
        $token = preg_replace('/[^a-zA-Z0-9_]/', '', $query['token'] ?? '');
        $uploadDir = sys_get_temp_dir() . '/cloud_uploads';
        $matched = glob($uploadDir . '/' . $token . '_*');
        if ($token && !empty($matched) && is_file($matched[0])) {
            $filePath = $matched[0];
            $fSize = filesize($filePath);
            $hdr = "HTTP/1.1 200 OK\r\n" .
                   "Content-Type: application/octet-stream\r\n" .
                   "Content-Length: {$fSize}\r\n" .
                   "Connection: close\r\n\r\n";
            @fwrite($conn, $hdr);
            $fh = fopen($filePath, 'rb');
            if ($fh) {
                while (!feof($fh)) {
                    $chunk = fread($fh, 65536);
                    if ($chunk === false || $chunk === '') break;
                    $wLen = strlen($chunk);
                    $wOff = 0;
                    while ($wOff < $wLen) {
                        $n = @fwrite($conn, substr($chunk, $wOff));
                        if ($n === false || $n === 0) break;
                        $wOff += $n;
                    }
                }
                fclose($fh);
            }
            @unlink($filePath);
        } else {
            $err = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found";
            @fwrite($conn, $err);
        }
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    // 1. Rota de Seleção de Roteador (/select-router?mac=...)
    if ($path === '/select-router') {
        if (!requireNavRole($conn, $clientId, $sess, 'operator')) return;
        $rawMac = $query['mac'] ?? '';
        $clean = cleanMac(normalizeMac($rawMac));
        if (!$clean && count($routers) === 1) {
            $clean = cleanMac(array_key_first($routers));
        }
        $resp = "HTTP/1.1 302 Found\r\n" .
                "Location: /webpages/index.html\r\n" .
                "Set-Cookie: tp_selected_mac={$clean}; Path=/; SameSite=Lax\r\n" .
                "Set-Cookie: tp_tunnel_mac={$clean}; Path=/; SameSite=Lax\r\n" .
                "Content-Length: 0\r\n" .
                "Connection: close\r\n\r\n";
        @fwrite($conn, $resp);
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    // 2. Rota de Saída do Roteador (/exit-router)
    if ($path === '/exit-router') {
        $resp = "HTTP/1.1 302 Found\r\n" .
                "Location: /dashboard\r\n" .
                "Set-Cookie: tp_selected_mac=; Path=/; Max-Age=0; SameSite=Lax\r\n" .
                "Set-Cookie: tp_tunnel_mac=; Path=/; Max-Age=0; SameSite=Lax\r\n" .
                "Content-Length: 0\r\n" .
                "Connection: close\r\n\r\n";
        @fwrite($conn, $resp);
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    // 3. Compatibilidade Legada (/tunnel/{mac}/*) -> define cookie e redireciona para /webpages/index.html
    if (preg_match('#^/tunnel/([0-9a-fA-F:_-]+)(/?.*)$#i', $path, $pm)) {
        if (!requireNavRole($conn, $clientId, $sess, 'operator')) return;
        $clean = cleanMac(normalizeMac($pm[1]));
        $subPath = $pm[2] ?: '/webpages/index.html';
        if ($subPath === '' || $subPath === '/') {
            $subPath = '/webpages/index.html';
        }
        $queryString = !empty($uriParts['query']) ? ('?' . $uriParts['query']) : '';
        $target = $subPath . $queryString;
        $resp = "HTTP/1.1 302 Found\r\n" .
                "Location: {$target}\r\n" .
                "Set-Cookie: tp_selected_mac={$clean}; Path=/; SameSite=Lax\r\n" .
                "Set-Cookie: tp_tunnel_mac={$clean}; Path=/; SameSite=Lax\r\n" .
                "Content-Length: 0\r\n" .
                "Connection: close\r\n\r\n";
        @fwrite($conn, $resp);
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    // 4. Rota do Painel do Cloud Controller (/dashboard e /dashboard/*)
    if ($path === '/dashboard' || strpos($path, '/dashboard/') === 0) {
        $sub = substr($path, strlen('/dashboard'));
        if ($sub === '' || $sub === '/') {
            $sub = '/index.html';
        }
        // Sem sessão: apenas a tela de login (autocontida) é entregue; demais arquivos exigem login.
        if (!$sess) {
            if ($sub === '/index.html' || $sub === '/login.html') {
                $sub = '/login.html';
            } else {
                sendJsonResponse($conn, $clientId, 401, ['ok' => false, 'error' => 'Autenticação necessária']);
                return;
            }
        }
        $cleanPath = str_replace(['\\', '/'], DIRECTORY_SEPARATOR, $sub);
        $fullPath = rtrim($PUBLIC_DIR, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . ltrim($cleanPath, DIRECTORY_SEPARATOR);
        serveStaticFile($conn, $clientId, $fullPath);
        return;
    }

    // 5. Rota Raiz (/)
    if ($path === '/' || $path === '') {
        $selectedMac = $cookies['tp_selected_mac'] ?? ($cookies['tp_tunnel_mac'] ?? null);
        if ($selectedMac) {
            $normMac = normalizeMac($selectedMac);
            if (isset($routers[$normMac])) {
                $resp = "HTTP/1.1 302 Found\r\nLocation: /webpages/index.html\r\nConnection: close\r\n\r\n";
                @fwrite($conn, $resp);
                @fclose($conn);
                unset($clients[$clientId], $clientMeta[$clientId]);
                return;
            }
        }
        $resp = "HTTP/1.1 302 Found\r\nLocation: /dashboard\r\nConnection: close\r\n\r\n";
        @fwrite($conn, $resp);
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    // 6. Arquivos estáticos do Cloud Controller na raiz (favicon, robots)
    if (in_array($path, ['/favicon.ico', '/robots.txt'])) {
        $cleanPath = str_replace(['\\', '/'], DIRECTORY_SEPARATOR, $path);
        $fullPath = rtrim($PUBLIC_DIR, DIRECTORY_SEPARATOR) . DIRECTORY_SEPARATOR . ltrim($cleanPath, DIRECTORY_SEPARATOR);
        if (is_file($fullPath)) {
            serveStaticFile($conn, $clientId, $fullPath);
            return;
        }
    }

    // 7. Proxy Transparente para a WebUI do Roteador TP-Link (exige sessão operador/admin)
    if (!requireNavRole($conn, $clientId, $sess, 'operator', $headers)) return;
    $tunnelMac = null;
    $selected = $cookies['tp_selected_mac'] ?? ($cookies['tp_tunnel_mac'] ?? null);
    if ($selected) {
        $tunnelMac = normalizeMac($selected);
    } elseif (count($routers) === 1) {
        $tunnelMac = array_key_first($routers);
    }

    if ($tunnelMac === null || !isset($routers[$tunnelMac]) || !isset($clients[$routers[$tunnelMac]])) {
        $body = "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Roteador Não Conectado</title></head><body style='font-family:sans-serif;background:#0d1117;color:#c9d1d9;text-align:center;padding:60px 20px;'><h2>Roteador Indisponível</h2><p>Nenhum roteador ativo foi selecionado para esta sessão ou o roteador está offline.</p><p style='margin-top:24px;'><a href='/dashboard' style='display:inline-block;padding:10px 20px;background:#2563eb;color:#ffffff;text-decoration:none;border-radius:8px;font-weight:600;'>&larr; Voltar ao Painel Geral</a></p></body></html>";
        $resp = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: " . strlen($body) . "\r\nConnection: close\r\n\r\n" . $body;
        @fwrite($conn, $resp);
        @fclose($conn);
        unset($clients[$clientId], $clientMeta[$clientId]);
        return;
    }

    $queryString = !empty($uriParts['query']) ? ('?' . $uriParts['query']) : '';
    $targetUri = $path . $queryString;

    // Normaliza recursos requisitados diretamente sem /webpages
    if (
        strpos($targetUri, '/assets/') === 0 ||
        strpos($targetUri, '/js/') === 0 ||
        strpos($targetUri, '/locale/') === 0 ||
        strpos($targetUri, '/config/') === 0 ||
        strpos($targetUri, '/data/') === 0
    ) {
        $targetUri = '/webpages' . $targetUri;
    }

    $isHtml = ($targetUri === '/webpages/index.html' || strpos($targetUri, '/webpages/index.html?') === 0 || substr($path, -5) === '.html');

    $targetHost = "192.168.0.1";
    $rCid = $routers[$tunnelMac] ?? null;
    if ($rCid && isset($clientMeta[$rCid]['telemetry']['lan_ip'])) {
        $lip = trim($clientMeta[$rCid]['telemetry']['lan_ip']);
        if (!empty($lip) && $lip !== '—') {
            $targetHost = $lip;
        }
    }

    $newReqLine = "{$method} {$targetUri} HTTP/1.1";
    $newHeaders = [];
    $newHeaders[] = $newReqLine;
    $newHeaders[] = "Host: {$targetHost}";
    $newHeaders[] = "Connection: close";

    foreach ($lines as $line) {
        if (empty(trim($line))) continue;
        if (strpos($line, ':') !== false) {
            [$k, $v] = explode(':', $line, 2);
            $lk = strtolower(trim($k));
            if ($lk === 'host' || $lk === 'connection') continue;
            // Nunca repassa o cookie de sessão do Cloud Controller para o roteador
            if ($lk === 'cookie') {
                $kept = [];
                foreach (explode(';', $v) as $cp) {
                    $cpName = trim(explode('=', trim($cp), 2)[0]);
                    if ($cpName === '' || $cpName === AUTH_COOKIE) continue;
                    $kept[] = trim($cp);
                }
                if ($kept) {
                    $newHeaders[] = 'Cookie: ' . implode('; ', $kept);
                }
                continue;
            }
            if ($isHtml && ($lk === 'if-none-match' || $lk === 'if-modified-since')) continue;
            if ($lk === 'origin') {
                $newHeaders[] = "Origin: http://{$targetHost}";
                continue;
            }
            if ($lk === 'referer') {
                $newHeaders[] = "Referer: http://{$targetHost}/webpages/index.html";
                continue;
            }
            if ($lk === 'content-length') {
                $newHeaders[] = "Content-Length: " . strlen($reqBody);
                continue;
            }
            $newHeaders[] = trim($k) . ': ' . trim($v);
        }
    }

    if ($method === 'POST' && stripos(implode("\r\n", $newHeaders), 'Content-Length:') === false) {
        $newHeaders[] = "Content-Length: " . strlen($reqBody);
    }

    $forwardBuffer = implode("\r\n", $newHeaders) . "\r\n\r\n" . $reqBody;

    $seqId = $nextTunnelSeq++;
    $clean = cleanMac($tunnelMac);
    $clientMeta[$clientId] = [
        'type' => 'http_tunnel',
        'mac' => $tunnelMac,
        'clean_mac' => $clean,
        'tunnel_id' => $seqId,
        'buf' => '',
        'resp_buf' => '',
        'is_html' => $isHtml,
        'html_sent' => false,
        'headers_sent' => false,
        'headers_done' => false,
        'expected_len' => null,
        'body_sent' => 0,
        'is_chunked' => false,
        'created_at' => time()
    ];
    $tunnelClients[$clientId] = ['mac' => $tunnelMac, 'tunnel_id' => $seqId];
    $macTunnelMap[$tunnelMac][$seqId] = $clientId;

    $rSock = $clients[$routers[$tunnelMac]];
    $ok1 = sendToClient($rSock, json_encode([
        'type' => 'tcp_tunnel_open',
        'tunnel_id' => $seqId,
        'target_port' => 80
    ]));

    $ok2 = sendToClient($rSock, json_encode([
        'type' => 'tcp_tunnel_data',
        'tunnel_id' => $seqId,
        'data' => base64_encode($forwardBuffer)
    ]));

    if (!$ok1 || !$ok2) {
        $body = "502 Bad Gateway: Failed to forward request to router";
        $resp = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: " . strlen($body) . "\r\nConnection: close\r\n\r\n" . $body;
        @fwrite($conn, $resp);
        closeClient($clientId, false);
        return;
    }

    return;
}

// Loop principal de eventos assíncronos (stream_select)
while (true) {
    foreach ($clients as $cid => $cres) {
        if (!is_resource($cres)) {
            unset($clients[$cid], $clientMeta[$cid]);
        }
    }
    $tListeners = [];
    foreach ($tunnelServers as $tMac => $tInfo) {
        if (isset($tInfo['socket']) && is_resource($tInfo['socket'])) {
            $tListeners[] = $tInfo['socket'];
        }
    }

    $read = array_merge([$server], $clients, $tListeners);
    $write = null;
    $except = null;

    if (@stream_select($read, $write, $except, 0, 5000) === false) {
        continue;
    }

    // Limpeza de conexões HTTP/túnel órfãs ou inativas (>20 segundos) e roteadores zumbis (>45s)
    static $lastCleanup = 0;
    $now = time();
    if ($now - $lastCleanup >= 3) {
        $lastCleanup = $now;
        revalidateAuthSockets();
        pruneAuthFailures();
        foreach ($clientMeta as $cid => $cMeta) {
            $cType = $cMeta['type'] ?? '';
            $created = $cMeta['created_at'] ?? 0;
            if (($cType === 'http' || $cType === 'http_tunnel') && $created > 0 && ($now - $created > 20)) {
                closeClient($cid);
            }
            if ($cType === 'router') {
                $lastAct = $cMeta['last_ping'] ?? ($cMeta['connected_at'] ?? $created);
                // Heartbeat ativo: a cada 15s sem atividade, envia ping de WebSocket (0x09)
                if (isset($clients[$cid]) && ($now - $lastAct >= 15)) {
                    @fwrite($clients[$cid], wsEncode('', 0x09));
                }
                // Timeout estendido para 90s para evitar desconexões prematuras durante transferências e comandos
                if ($lastAct > 0 && ($now - $lastAct > 90)) {
                    echo "[!] Roteador {$cid} sem resposta há >90s, fechando socket.\n";
                    closeClient($cid);
                }
            }
        }
    }

    // Amostrador periódico de histórico (janelas de 10 em 10 minutos para todos os roteadores adotados)
    static $lastHistoryTick = 0;
    if ($now - $lastHistoryTick >= 30) {
        $lastHistoryTick = $now;
        $curBucket = (int)(floor($now / $HISTORY_INTERVAL) * $HISTORY_INTERVAL);
        foreach ($adoptedDevices as $amac => $ainfo) {
            $isOn = isset($routers[$amac]) && isset($clients[$routers[$amac]]);
            $telem = null;
            if ($isOn) {
                $rid = $routers[$amac];
                $telem = $clientMeta[$rid]['telemetry'] ?? ($ainfo['last_telemetry'] ?? null);
            }
            if (!isset($routerHistory[$amac][$curBucket])) {
                recordRouterHistoryPoint($amac, $isOn, $telem, true);
            } elseif (!empty($historyDirty[$amac]) && ($now - ($historyLastFlushTime[$amac] ?? 0) >= 300)) {
                saveRouterHistory($amac);
            }
        }
    }

    if (in_array($server, $read, true)) {
        $newConn = @stream_socket_accept($server, 0);
        if ($newConn) {
            stream_set_blocking($newConn, false);
            $newId = (int)$newConn;
            $clients[$newId] = $newConn;
            $clientMeta[$newId] = ['type' => 'http', 'buf' => '', 'created_at' => time()];
        }
        $key = array_search($server, $read, true);
        unset($read[$key]);
    }

    foreach ($tunnelServers as $tMac => $tInfo) {
        $tSock = $tInfo['socket'];
        if (in_array($tSock, $read, true)) {
            $newBrowser = @stream_socket_accept($tSock, 0);
            if ($newBrowser) {
                stream_set_blocking($newBrowser, false);
                $newCid = (int)$newBrowser;
                $seqId = $nextTunnelSeq++;

                $clients[$newCid] = $newBrowser;
                $clientMeta[$newCid] = [
                    'type' => 'tcp_tunnel',
                    'mac' => $tMac,
                    'tunnel_id' => $seqId,
                    'buf' => '',
                    'created_at' => time()
                ];
                $tunnelClients[$newCid] = ['mac' => $tMac, 'tunnel_id' => $seqId];
                $macTunnelMap[$tMac][$seqId] = $newCid;

                if (isset($routers[$tMac]) && isset($clients[$routers[$tMac]])) {
                    sendToClient($clients[$routers[$tMac]], json_encode([
                        'type' => 'tcp_tunnel_open',
                        'tunnel_id' => $seqId,
                        'target_port' => 80
                    ]));
                }
            }
            $key = array_search($tSock, $read, true);
            unset($read[$key]);
        }
    }

    foreach ($read as $conn) {
        $clientId = (int)$conn;
        $cType = $clientMeta[$clientId]['type'] ?? 'unknown';

        if ($cType === 'tcp_tunnel' || $cType === 'http_tunnel') {
            $tMac = $clientMeta[$clientId]['mac'] ?? '';
            $tSeq = $clientMeta[$clientId]['tunnel_id'] ?? 0;
            $data = @fread($conn, 8192);

            if ($data === false || $data === '') {
                closeClient($clientId);
                continue;
            }

            if ($tMac && isset($routers[$tMac]) && isset($clients[$routers[$tMac]])) {
                if (isset($tunnelServers[$tMac])) {
                    $tunnelServers[$tMac]['last_activity'] = time();
                }
                sendToClient($clients[$routers[$tMac]], json_encode([
                    'type' => 'tcp_tunnel_data',
                    'tunnel_id' => $tSeq,
                    'data' => base64_encode($data)
                ]));
            }
            continue;
        }

        $data = @fread($conn, 65536);

        if ($data === false || $data === '') {
            closeClient($clientId);
            continue;
        }

        $clientMeta[$clientId]['buf'] .= $data;
        while (strlen($data) >= 65536) {
            $extra = @fread($conn, 65536);
            if ($extra === false || $extra === '') break;
            $clientMeta[$clientId]['buf'] .= $extra;
            $data = $extra;
        }

        if (($clientMeta[$clientId]['type'] ?? '') === 'http') {
            $hdrPos = strpos($clientMeta[$clientId]['buf'], "\r\n\r\n");
            if ($hdrPos !== false) {
                $hdrPart = substr($clientMeta[$clientId]['buf'], 0, $hdrPos);
                $isComplete = false;
                if (preg_match('/Content-Length:\s*(\d+)/i', $hdrPart, $clm)) {
                    $contentLen = (int)$clm[1];
                    $bodyReceived = strlen($clientMeta[$clientId]['buf']) - ($hdrPos + 4);
                    if ($bodyReceived >= $contentLen) {
                        $isComplete = true;
                    }
                } elseif (stripos($hdrPart, 'Transfer-Encoding:') !== false && stripos($hdrPart, 'chunked') !== false) {
                    if (strpos($clientMeta[$clientId]['buf'], "\r\n0\r\n\r\n") !== false || substr($clientMeta[$clientId]['buf'], $hdrPos + 4) === "0\r\n\r\n") {
                        $isComplete = true;
                    }
                } else {
                    $isComplete = true;
                }

                if ($isComplete) {
                    handleHttpRequest($conn, $clientId, $clientMeta[$clientId]['buf']);
                }
            }
            continue;
        }

        while ($frame = wsDecode($clientMeta[$clientId]['buf'])) {
            $opcode = $frame['opcode'];
            $payload = $frame['payload'];

            if ($opcode === 0x08) {
                @fwrite($conn, wsEncode('', 0x08));
                closeClient($clientId);
                break;
            }

            if ($opcode === 0x09) {
                @fwrite($conn, wsEncode($payload, 0x0A));
                if (($clientMeta[$clientId]['type'] ?? '') === 'router') {
                    $clientMeta[$clientId]['last_ping'] = time();
                }
                continue;
            }

            if ($opcode === 0x0A) {
                if (($clientMeta[$clientId]['type'] ?? '') === 'router') {
                    $clientMeta[$clientId]['last_ping'] = time();
                }
                continue;
            }

            if ($opcode === 0x01 || $opcode === 0x02) {
                $json = @json_decode($payload, true);

                // CORREÇÃO E IDENTIFICAÇÃO INFALÍVEL:
                // Se a mensagem contém payloads exclusivos de roteador (telemetria, dados de túnel, etc.),
                // garante que o tipo seja 'router', prevenindo qualquer desvio ou sobrescrita para 'terminal'.
                // Sockets autenticados (admin/terminal com sessão de usuário) NUNCA podem virar 'router'.
                if ($json && isset($json['type']) && empty($clientMeta[$clientId]['user'])) {
                    $routerMsgTypes = ['telemetry', 'adopted_ack', 'term_output', 'tcp_tunnel_data', 'tcp_tunnel_close', 'cmd_res', 'file_upload_ready', 'file_upload_ack', 'file_upload_done'];
                    if (in_array($json['type'], $routerMsgTypes, true)) {
                        if (($clientMeta[$clientId]['type'] ?? '') !== 'router') {
                            echo "[!] CORREÇÃO: Forçando socket {$clientId} como 'router' (era: " . ($clientMeta[$clientId]['type'] ?? 'none') . ")\n";
                            $clientMeta[$clientId]['type'] = 'router';
                        }
                        if (empty($clientMeta[$clientId]['mac']) && !empty($json['data']['mac'])) {
                            $clientMeta[$clientId]['mac'] = normalizeMac($json['data']['mac']);
                        }
                        if (!empty($clientMeta[$clientId]['mac'])) {
                            $routers[$clientMeta[$clientId]['mac']] = $clientId;
                        }
                    }
                }

                $type = $clientMeta[$clientId]['type'] ?? '';

                // ROTEADOR -> SERVIDOR
                if ($type === 'router') {
                    // Atualiza last_ping em QUALQUER pacote vindo do roteador
                    $clientMeta[$clientId]['last_ping'] = time();

                    if ($json && isset($json['type'])) {
                        if ($json['type'] === 'telemetry') {
                            if (isset($json['data']['sessions']['sessions']) && is_array($json['data']['sessions']['sessions'])) {
                                $json['data']['sessions'] = $json['data']['sessions']['sessions'];
                            }
                            if (empty($json['data']['auth_count']) && !empty($json['data']['sessions']) && is_array($json['data']['sessions'])) {
                                $json['data']['auth_count'] = count($json['data']['sessions']);
                            }
                            $clientMeta[$clientId]['telemetry'] = $json['data'] ?? [];
                            $clientMeta[$clientId]['last_ping'] = time();

                            $cMac = $clientMeta[$clientId]['mac'] ?? '';
                            if ($cMac && isset($adoptedDevices[$cMac])) {
                                $adoptedDevices[$cMac]['last_telemetry'] = $json['data'] ?? [];
                            }
                            if ($cMac) {
                                recordRouterHistoryPoint($cMac, true, $json['data'] ?? [], false);
                            }

                            $telemName = $json['data']['name'] ?? null;
                            if ($telemName && $telemName !== 'BE220') {
                                $clientMeta[$clientId]['name'] = $telemName;
                                if ($cMac && isset($adoptedDevices[$cMac])) {
                                    if (($adoptedDevices[$cMac]['name'] ?? '') !== $telemName) {
                                        $adoptedDevices[$cMac]['name'] = $telemName;
                                        saveAdoptedDevices($adoptedDevices);
                                    }
                                }
                            }

                            // Se o roteador reporta adopted=true no hardware, garante adopted=true no servidor
                            $rAdopted = !empty($json['data']['adopted']);
                            if ($rAdopted && empty($clientMeta[$clientId]['adopted'])) {
                                $clientMeta[$clientId]['adopted'] = true;
                                if ($cMac && !isset($adoptedDevices[$cMac])) {
                                    $adoptedDevices[$cMac] = [
                                        'name' => ($clientMeta[$clientId]['name'] ?? null) ?: 'Archer BE220',
                                        'adopted_at' => time()
                                    ];
                                    saveAdoptedDevices($adoptedDevices);
                                }
                            }

                            broadcastToAdmins([
                                'event' => 'telemetry',
                                'mac' => $cMac,
                                'name' => $clientMeta[$clientId]['name'] ?? null,
                                'adopted' => $clientMeta[$clientId]['adopted'] ?? false,
                                'data' => $json['data']
                            ]);
                        } elseif ($json['type'] === 'adopted_ack') {
                            $rMac = $clientMeta[$clientId]['mac'] ?? '';
                            $isAd = !empty($json['adopted']);
                            echo "[✓] ACK DE ADOÇÃO DO ROTEADOR: MAC={$rMac}, Status=" . ($isAd ? 'ADOTADO' : 'NÃO-ADOTADO') . "\n";
                            $clientMeta[$clientId]['adopted'] = $isAd;
                            if ($rMac && $isAd && !isset($adoptedDevices[$rMac])) {
                                $adoptedDevices[$rMac] = [
                                    'name' => ($clientMeta[$clientId]['name'] ?? null) ?: 'Archer BE220',
                                    'adopted_at' => time()
                                ];
                                saveAdoptedDevices($adoptedDevices);
                            }
                        } elseif ($json['type'] === 'term_output') {
                            $termId = (int)($json['term_id'] ?? 0);
                            // O roteador envia os bytes PTY codificados em base64.
                            // Decodificar para obter os bytes raw e enviar como
                            // frame BINÁRIO (type=2) para o xterm.js no navegador.
                            $rawPty = base64_decode($json['data'] ?? '');
                            echo "[DBG] term_output from router: termId={$termId}, raw_bytes=" . strlen($rawPty) . "\n";
                            if ($termId && isset($clients[$termId])) {
                                echo "[DBG] forwarding term_output (binary) to terminal client {$termId}\n";
                                sendToClient($clients[$termId], $rawPty, 2); // type=2 → frame binário
                            } else {
                                echo "[DBG] client {$termId} NOT FOUND in clients list!\n";
                            }
                        } elseif (in_array($json['type'], ['file_upload_ready', 'file_upload_ack', 'file_upload_done'], true)) {
                            $termId = (int)($json['term_id'] ?? 0);
                            if ($termId && isset($clients[$termId])) {
                                sendToClient($clients[$termId], json_encode($json));
                            }
                        } elseif ($json['type'] === 'tcp_tunnel_data') {
                            $tSeq = (int)($json['tunnel_id'] ?? 0);
                            $rMac = $clientMeta[$clientId]['mac'] ?? '';
                            $rawBytes = base64_decode($json['data'] ?? '');
                            if ($rMac && isset($macTunnelMap[$rMac][$tSeq])) {
                                $bCid = $macTunnelMap[$rMac][$tSeq];
                                if (isset($clients[$bCid])) {
                                    $isHttp = ($clientMeta[$bCid]['type'] ?? '') === 'http_tunnel';
                                    $isHtml = !empty($clientMeta[$bCid]['is_html']);
                                    $cleanMac = $clientMeta[$bCid]['clean_mac'] ?? cleanMac($rMac);

                                    if ($isHttp && $isHtml) {
                                        $clientMeta[$bCid]['resp_buf'] .= $rawBytes;
                                        $buf = $clientMeta[$bCid]['resp_buf'];
                                        $readyToSend = false;

                                        if (strpos($buf, "\r\n\r\n") !== false) {
                                            [$hPart, $bPart] = explode("\r\n\r\n", $buf, 2);
                                            if (preg_match('/Content-Length:\s*(\d+)/i', $hPart, $clm)) {
                                                $cl = (int)$clm[1];
                                                if (strlen($bPart) >= $cl) {
                                                    $readyToSend = true;
                                                }
                                            }
                                        }

                                        if ($readyToSend && empty($clientMeta[$bCid]['html_sent'])) {
                                            $clientMeta[$bCid]['html_sent'] = true;
                                            $clientMeta[$bCid]['headers_done'] = true;
                                            $processed = processHtmlTunnelResponse($buf, $cleanMac);
                                            $clientMeta[$bCid]['resp_buf'] = '';
                                            $wLen = strlen($processed);
                                            $wOff = 0;
                                            $retries = 0;
                                            while ($wOff < $wLen && $retries < 50) {
                                                $n = @fwrite($clients[$bCid], substr($processed, $wOff));
                                                if ($n === false) break;
                                                if ($n === 0) {
                                                    $retries++;
                                                    usleep(1000);
                                                    continue;
                                                }
                                                $wOff += $n;
                                            }
                                            // HTML 100% transmitido: encerra o túnel HTTP imediatamente
                                            // para liberar o slot de conexão do uhttpd no roteador e o socket no Cloud Run.
                                            closeClient($bCid);
                                        }
                                    } elseif ($isHttp) {
                                        // Tratamento de respostas HTTP binárias/JSON/assets com detecção precisa de fim de resposta
                                        if (empty($clientMeta[$bCid]['headers_done'])) {
                                            $clientMeta[$bCid]['resp_buf'] .= $rawBytes;
                                            $buf = $clientMeta[$bCid]['resp_buf'];
                                            $hdrPos = strpos($buf, "\r\n\r\n");
                                            if ($hdrPos === false) {
                                                // Cabeçalhos incompletos, aguarda próximo pacote
                                                continue;
                                            }

                                            $clientMeta[$bCid]['headers_done'] = true;
                                            $rawHeaders = substr($buf, 0, $hdrPos);
                                            $initialBody = substr($buf, $hdrPos + 4);
                                            $clientMeta[$bCid]['resp_buf'] = '';

                                            $statusCode = 200;
                                            if (preg_match('#^HTTP/1\.[01]\s+(\d{3})#i', $rawHeaders, $sm)) {
                                                $statusCode = (int)$sm[1];
                                            }

                                            $expectedLen = null;
                                            if (preg_match('/Content-Length:\s*(\d+)/i', $rawHeaders, $clm)) {
                                                $expectedLen = (int)$clm[1];
                                            }

                                            $isChunked = false;
                                            if (stripos($rawHeaders, 'Transfer-Encoding:') !== false && stripos($rawHeaders, 'chunked') !== false) {
                                                $isChunked = true;
                                            }

                                            $tHost = "192.168.0.1";
                                            if (isset($routers[$rMac]) && isset($clientMeta[$routers[$rMac]]['telemetry']['lan_ip'])) {
                                                $lip = trim($clientMeta[$routers[$rMac]]['telemetry']['lan_ip']);
                                                if (!empty($lip) && $lip !== '—') $tHost = $lip;
                                            }
                                            // Normaliza Location se uhttpd devolver com IP local (ex: http://192.168.0.1/webpages/index.html -> /webpages/index.html)
                                            $rawHeaders = preg_replace(
                                                '/Location:\s*https?:\/\/(?:' . preg_quote($tHost, '/') . '|192\.168\.0\.1|127\.0\.0\.1)(?::[0-9]+)?/i',
                                                'Location: ',
                                                $rawHeaders
                                            );

                                            // Força Connection: close para sinalizar encerramento após resposta única
                                            if (stripos($rawHeaders, 'Connection:') !== false) {
                                                $rawHeaders = preg_replace('/Connection:\s*[^\r\n]+/i', 'Connection: close', $rawHeaders);
                                            } else {
                                                $rawHeaders .= "\r\nConnection: close";
                                            }

                                            $outData = $rawHeaders . "\r\n\r\n" . $initialBody;
                                            $clientMeta[$bCid]['expected_len'] = $expectedLen;
                                            $clientMeta[$bCid]['is_chunked'] = $isChunked;
                                            $clientMeta[$bCid]['body_sent'] = strlen($initialBody);
                                            $clientMeta[$bCid]['status_code'] = $statusCode;

                                            $wLen = strlen($outData);
                                            $wOff = 0;
                                            $retries = 0;
                                            while ($wOff < $wLen && $retries < 50) {
                                                $n = @fwrite($clients[$bCid], substr($outData, $wOff));
                                                if ($n === false) break;
                                                if ($n === 0) {
                                                    $retries++;
                                                    usleep(1000);
                                                    continue;
                                                }
                                                $wOff += $n;
                                            }

                                            $isComplete = false;
                                            if ($statusCode === 204 || $statusCode === 304 || ($statusCode >= 100 && $statusCode < 200)) {
                                                $isComplete = true;
                                            } elseif ($expectedLen !== null && $clientMeta[$bCid]['body_sent'] >= $expectedLen) {
                                                $isComplete = true;
                                            } elseif ($isChunked && (substr($initialBody, -5) === "0\r\n\r\n" || substr($initialBody, -7) === "\r\n0\r\n\r\n")) {
                                                $isComplete = true;
                                            }

                                            if ($isComplete) {
                                                closeClient($bCid);
                                            }
                                        } else {
                                            // Headers já enviados em pacote anterior; transmite dados adicionais do corpo
                                            $wLen = strlen($rawBytes);
                                            $wOff = 0;
                                            $retries = 0;
                                            while ($wOff < $wLen && $retries < 50) {
                                                $n = @fwrite($clients[$bCid], substr($rawBytes, $wOff));
                                                if ($n === false) break;
                                                if ($n === 0) {
                                                    $retries++;
                                                    usleep(1000);
                                                    continue;
                                                }
                                                $wOff += $n;
                                            }

                                            $clientMeta[$bCid]['body_sent'] += strlen($rawBytes);

                                            $isComplete = false;
                                            $expectedLen = $clientMeta[$bCid]['expected_len'];
                                            $isChunked = $clientMeta[$bCid]['is_chunked'];

                                            if ($expectedLen !== null && $clientMeta[$bCid]['body_sent'] >= $expectedLen) {
                                                $isComplete = true;
                                            } elseif ($isChunked && (substr($rawBytes, -5) === "0\r\n\r\n" || substr($rawBytes, -7) === "\r\n0\r\n\r\n")) {
                                                $isComplete = true;
                                            }

                                            if ($isComplete) {
                                                closeClient($bCid);
                                            }
                                        }
                                    } else {
                                        // Túnel TCP não-HTTP puro (ex: proxy de portas)
                                        $wLen = strlen($rawBytes);
                                        $wOff = 0;
                                        $retries = 0;
                                        while ($wOff < $wLen && $retries < 50) {
                                            $n = @fwrite($clients[$bCid], substr($rawBytes, $wOff));
                                            if ($n === false) break;
                                            if ($n === 0) {
                                                $retries++;
                                                usleep(1000);
                                                continue;
                                            }
                                            $wOff += $n;
                                        }
                                    }
                                }
                            }
                        } elseif ($json['type'] === 'tcp_tunnel_close') {
                            $tSeq = (int)($json['tunnel_id'] ?? 0);
                            $rMac = $clientMeta[$clientId]['mac'] ?? '';
                            if ($rMac && isset($macTunnelMap[$rMac][$tSeq])) {
                                $bCid = $macTunnelMap[$rMac][$tSeq];
                                if (isset($clients[$bCid])) {
                                    $isHttp = ($clientMeta[$bCid]['type'] ?? '') === 'http_tunnel';
                                    $isHtml = !empty($clientMeta[$bCid]['is_html']);
                                    $cleanMac = $clientMeta[$bCid]['clean_mac'] ?? cleanMac($rMac);

                                    if ($isHttp && $isHtml && empty($clientMeta[$bCid]['html_sent'])) {
                                        $buf = $clientMeta[$bCid]['resp_buf'] ?? '';
                                        if (!empty($buf)) {
                                            $processed = processHtmlTunnelResponse($buf, $cleanMac);
                                            $wLen = strlen($processed);
                                            $wOff = 0;
                                            $retries = 0;
                                            while ($wOff < $wLen && $retries < 50) {
                                                $n = @fwrite($clients[$bCid], substr($processed, $wOff));
                                                if ($n === false) break;
                                                if ($n === 0) {
                                                    $retries++;
                                                    usleep(1000);
                                                    continue;
                                                }
                                                $wOff += $n;
                                            }
                                        }
                                    }

                                    closeClient($bCid, false);
                                }
                                unset($macTunnelMap[$rMac][$tSeq]);
                            }
                        } elseif ($json['type'] === 'cmd_res') {
                            $cmdId = (string)($json['cmd_id'] ?? '');
                            $rMac = $clientMeta[$clientId]['mac'] ?? '';
                            // Auto-recuperação da lista de bloqueio DNS gravada na Flash do roteador
                            if (strpos($cmdId, 'boot_dns_get_') === 0 && isset($json['res']['domains']) && is_array($json['res']['domains'])) {
                                $recoveredDomains = array_values(array_unique($json['res']['domains']));
                                if (!empty($recoveredDomains) && $rMac && isset($adoptedDevices[$rMac])) {
                                    $adoptedDevices[$rMac]['dns_blocklist'] = $recoveredDomains;
                                    saveAdoptedDevices($adoptedDevices);
                                    echo "[✓] RECUPERADOS " . count($recoveredDomains) . " DOMINIOS BLOQUEADOS DIRETAMENTE DA FLASH DO ROTEADOR: {$rMac}\n";
                                    broadcastToAdmins([
                                        'event' => 'router_dns_blocklist_updated',
                                        'mac' => $rMac,
                                        'domains' => $recoveredDomains,
                                        'online' => true,
                                        'synced' => true
                                    ]);
                                }
                            }
                            if (strpos($cmdId, 'boot_dns_') !== 0) {
                                broadcastToAdmins([
                                    'event' => 'cmd_result',
                                    'mac' => $clientMeta[$clientId]['mac'] ?? '',
                                    'cmd_id' => $json['cmd_id'] ?? null,
                                    'res' => $json['res'] ?? null
                                ]);
                            }
                        }
                    }
                }
                // TERMINAL NAVEGADOR -> ROTEADOR
                elseif ($type === 'terminal') {
                    if (!wsSocketHasRole($clientId, 'operator')) {
                        closeClient($clientId);
                        break;
                    }
                    $mac = $clientMeta[$clientId]['mac'] ?? '';
                    if ($mac && isset($routers[$mac]) && isset($clients[$routers[$mac]])) {
                        $upJson = @json_decode($payload, true);
                        if (is_array($upJson) && isset($upJson['type']) && in_array($upJson['type'], ['file_upload_start', 'file_upload_chunk', 'file_upload_end', 'fast_file_download'], true)) {
                            $upJson['term_id'] = $clientId;
                            sendToClient($clients[$routers[$mac]], json_encode($upJson));
                        } else {
                            sendToClient($clients[$routers[$mac]], json_encode([
                                'type' => 'term_input',
                                'term_id' => $clientId,
                                'data' => $payload
                            ]));
                        }
                    } else {
                        echo "[DBG] router {$mac} NOT FOUND in routers list for terminal {$clientId}!\n";
                        $upJson = @json_decode($payload, true);
                        if (is_array($upJson) && isset($upJson['type']) && in_array($upJson['type'], ['file_upload_start', 'file_upload_chunk', 'file_upload_end', 'fast_file_download'], true)) {
                            sendToClient($conn, json_encode([
                                'type' => 'file_upload_ready',
                                'upload_id' => $upJson['upload_id'] ?? '',
                                'success' => false,
                                'error' => "Roteador {$mac} não está conectado no momento. Aguarde reconexão."
                            ]));
                        }
                    }
                }
                // ADMIN DASHBOARD -> SERVIDOR
                elseif ($type === 'admin') {
                    $cmd = @json_decode($payload, true);
                    if ($cmd && isset($cmd['action']) && authorizeWsAction($conn, $clientId, (string)$cmd['action'])) {
                        // HEARTBEAT / PING (Mantém conexão ativa no Cloud Run sem desconexões por ociosidade)
                        if ($cmd['action'] === 'ping') {
                            sendToClient($conn, json_encode([
                                'event' => 'pong',
                                'time' => time()
                            ]));
                        }
                        // ADOTAR DISPOSITIVO
                        elseif ($cmd['action'] === 'adopt_device') {
                            $targetMac = normalizeMac($cmd['mac'] ?? '');
                            $name = safeUtf8(trim($cmd['name'] ?? '') ?: 'Aldeia / Roteador BE220');
                            if ($targetMac) {
                                if (!isset($adoptedDevices[$targetMac])) {
                                    $adoptedDevices[$targetMac] = [
                                        'adopted_at' => time()
                                    ];
                                }
                                $adoptedDevices[$targetMac]['name'] = $name;
                                saveAdoptedDevices($adoptedDevices);
                                echo "[✓] ROTEADOR ADOTADO: {$targetMac} -> {$name}\n";

                                if (isset($routers[$targetMac]) && isset($clientMeta[$routers[$targetMac]])) {
                                    $clientMeta[$routers[$targetMac]]['adopted'] = true;
                                    $clientMeta[$routers[$targetMac]]['name'] = $name;
                                }

                                // NOTIFICA O ROTEADOR QUE ELE FOI ADOTADO (grava na Flash permanentemente)
                                if (isset($routers[$targetMac]) && isset($clients[$routers[$targetMac]])) {
                                    sendToClient($clients[$routers[$targetMac]], safeJsonEncode([
                                        'type' => 'set_adopted',
                                        'adopted' => true,
                                        'name' => $name
                                    ]));
                                }

                                broadcastToAdmins([
                                    'event' => 'router_adopted',
                                    'mac' => $targetMac,
                                    'name' => $name,
                                    'online' => isset($routers[$targetMac])
                                ]);
                            }
                        }
                        // RENOMEAR DISPOSITIVO
                        elseif ($cmd['action'] === 'rename_device') {
                            $targetMac = normalizeMac($cmd['mac'] ?? '');
                            $name = safeUtf8(trim($cmd['name'] ?? ''));
                            if ($targetMac && $name) {
                                if (!isset($adoptedDevices[$targetMac])) {
                                    $adoptedDevices[$targetMac] = [
                                        'adopted_at' => time()
                                    ];
                                }
                                $adoptedDevices[$targetMac]['name'] = $name;
                                saveAdoptedDevices($adoptedDevices);
                                echo "[✓] ROTEADOR RENOMEADO: {$targetMac} -> {$name}\n";

                                if (isset($routers[$targetMac]) && isset($clientMeta[$routers[$targetMac]])) {
                                    $clientMeta[$routers[$targetMac]]['name'] = $name;
                                }

                                if (isset($routers[$targetMac]) && isset($clients[$routers[$targetMac]])) {
                                    sendToClient($clients[$routers[$targetMac]], safeJsonEncode([
                                        'type' => 'set_adopted',
                                        'adopted' => true,
                                        'name' => $name
                                    ]));
                                }

                                broadcastToAdmins([
                                    'event' => 'router_renamed',
                                    'mac' => $targetMac,
                                    'name' => $name
                                ]);
                            }
                        }
                        // ESQUECER DISPOSITIVO (DESADOTAR)
                        elseif ($cmd['action'] === 'forget_device') {
                            $targetMac = normalizeMac($cmd['mac'] ?? '');
                            if ($targetMac && isset($adoptedDevices[$targetMac])) {
                                unset($adoptedDevices[$targetMac]);
                                saveAdoptedDevices($adoptedDevices);
                                echo "[x] ROTEADOR ESQUECIDO: {$targetMac}\n";

                                if (isset($routers[$targetMac]) && isset($clientMeta[$routers[$targetMac]])) {
                                    $clientMeta[$routers[$targetMac]]['adopted'] = false;
                                }

                                // NOTIFICA O ROTEADOR QUE ELE FOI DESADOTADO (reseta na Flash)
                                if (isset($routers[$targetMac]) && isset($clients[$routers[$targetMac]])) {
                                    sendToClient($clients[$routers[$targetMac]], json_encode([
                                        'type' => 'set_adopted',
                                        'adopted' => false
                                    ]));
                                }

                                broadcastToAdmins([
                                    'event' => 'router_forgotten',
                                    'mac' => $targetMac
                                ]);
                            }
                        }
                        elseif ($cmd['action'] === 'start_web_tunnel') {
                            $targetMac = normalizeMac($cmd['mac'] ?? '');
                            $res = startWebTunnel($targetMac);
                            if ($res['ok']) {
                                broadcastToAdmins([
                                    'event' => 'web_tunnel_ready',
                                    'mac' => $targetMac,
                                    'port' => $res['port'],
                                    'url' => $res['url'] ?? ("/select-router?mac=" . cleanMac($targetMac))
                                ]);
                            } else {
                                sendToClient($conn, json_encode([
                                    'event' => 'web_tunnel_error',
                                    'mac' => $targetMac,
                                    'error' => $res['error']
                                ]));
                            }
                        }
                        elseif ($cmd['action'] === 'stop_web_tunnel') {
                            $targetMac = normalizeMac($cmd['mac'] ?? '');
                            stopWebTunnel($targetMac);
                            broadcastToAdmins([
                                'event' => 'web_tunnel_stopped',
                                'mac' => $targetMac
                            ]);
                        }
                        // GESTÃO DE BLOQUEIO DNS (GLOBAL E POR ROTEADOR)
                        elseif ($cmd['action'] === 'save_default_dns_blocklist') {
                            $rawDomains = $cmd['domains'] ?? [];
                            $cleanDomains = [];
                            if (is_array($rawDomains)) {
                                foreach ($rawDomains as $d) {
                                    if (is_string($d)) {
                                        $cd = strtolower(trim($d));
                                        $cd = preg_replace('#^https?://#i', '', $cd);
                                        $cd = preg_replace('#^www\.#i', '', $cd);
                                        $cd = preg_replace('#/.*$#', '', $cd);
                                        $cd = preg_replace('#:.*$#', '', $cd);
                                        $cd = trim($cd);
                                        if (strlen($cd) > 2 && strpos($cd, '.') !== false) {
                                            $cleanDomains[] = $cd;
                                        }
                                    }
                                }
                            }
                            $defaultDnsBlocklist['domains'] = array_values(array_unique($cleanDomains));
                            $defaultDnsBlocklist['updated_at'] = time();
                            saveDefaultDnsBlocklist($defaultDnsBlocklist);
                            echo "[✓] LISTA PADRAO DNS ATUALIZADA: " . count($defaultDnsBlocklist['domains']) . " dominios\n";
                            broadcastToAdmins([
                                'event' => 'default_dns_blocklist_updated',
                                'domains' => $defaultDnsBlocklist['domains']
                            ]);
                        }
                        elseif ($cmd['action'] === 'get_default_dns_blocklist') {
                            sendToClient($conn, safeJsonEncode([
                                'event' => 'default_dns_blocklist',
                                'domains' => $defaultDnsBlocklist['domains'] ?? []
                            ]));
                        }
                        elseif ($cmd['action'] === 'apply_default_to_all_routers') {
                            $domains = $defaultDnsBlocklist['domains'] ?? [];
                            $countSynced = 0;
                            foreach ($adoptedDevices as $amac => &$ainfo) {
                                $ainfo['dns_blocklist'] = $domains;
                                if (isset($routers[$amac]) && isset($clients[$routers[$amac]])) {
                                    sendToClient($clients[$routers[$amac]], safeJsonEncode([
                                        'type' => 'command',
                                        'cmd_id' => uniqid('dns_all_'),
                                        'action' => 'dns_block_update',
                                        'params' => ['domains' => $domains]
                                    ]));
                                    $countSynced++;
                                }
                            }
                            unset($ainfo);
                            saveAdoptedDevices($adoptedDevices);
                            echo "[✓] LISTA PADRAO APLICADA A TODOS OS ROTEADORES: {$countSynced} online\n";
                            broadcastToAdmins([
                                'event' => 'all_routers_dns_synced',
                                'domains' => $domains,
                                'online_count' => $countSynced
                            ]);
                        }
                        elseif ($cmd['action'] === 'save_router_dns_blocklist') {
                            $targetMac = normalizeMac($cmd['mac'] ?? '');
                            $rawDomains = $cmd['domains'] ?? [];
                            $syncNow = !empty($cmd['sync_now']);
                            $cleanDomains = [];
                            if (is_array($rawDomains)) {
                                foreach ($rawDomains as $d) {
                                    if (is_string($d)) {
                                        $cd = strtolower(trim($d));
                                        $cd = preg_replace('#^https?://#i', '', $cd);
                                        $cd = preg_replace('#^www\.#i', '', $cd);
                                        $cd = preg_replace('#/.*$#', '', $cd);
                                        $cd = preg_replace('#:.*$#', '', $cd);
                                        $cd = trim($cd);
                                        if (strlen($cd) > 2 && strpos($cd, '.') !== false) {
                                            $cleanDomains[] = $cd;
                                        }
                                    }
                                }
                            }
                            $cleanDomains = array_values(array_unique($cleanDomains));
                            if ($targetMac && isset($adoptedDevices[$targetMac])) {
                                $adoptedDevices[$targetMac]['dns_blocklist'] = $cleanDomains;
                                saveAdoptedDevices($adoptedDevices);
                            }
                            echo "[✓] BLOQUEIO DNS SALVO PARA {$targetMac}: " . count($cleanDomains) . " dominios (syncNow: " . ($syncNow ? 'sim' : 'nao') . ")\n";

                            $isOnline = isset($routers[$targetMac]) && isset($clients[$routers[$targetMac]]);
                            if ($syncNow && $isOnline) {
                                sendToClient($clients[$routers[$targetMac]], safeJsonEncode([
                                    'type' => 'command',
                                    'cmd_id' => $cmd['cmd_id'] ?? uniqid('dns_sync_'),
                                    'action' => 'dns_block_update',
                                    'params' => ['domains' => $cleanDomains]
                                ]));
                            }

                            broadcastToAdmins([
                                'event' => 'router_dns_blocklist_updated',
                                'mac' => $targetMac,
                                'domains' => $cleanDomains,
                                'online' => $isOnline,
                                'synced' => ($syncNow && $isOnline)
                            ]);
                        }
                        // COMANDOS DIRETOS PARA O ROTEADOR (QoS, Kick, Reboot)
                        elseif (isset($cmd['mac'])) {
                            $targetCmdMac = normalizeMac($cmd['mac']);
                            if (isset($routers[$targetCmdMac])) {
                                $targetRouterId = $routers[$targetCmdMac];
                                if (isset($clients[$targetRouterId])) {
                                    sendToClient($clients[$targetRouterId], safeJsonEncode([
                                        'type' => 'command',
                                        'cmd_id' => $cmd['cmd_id'] ?? uniqid('cmd_'),
                                        'action' => $cmd['action'] ?? '',
                                        'params' => $cmd['params'] ?? []
                                    ]));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
