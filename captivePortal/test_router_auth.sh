#!/bin/sh
COOKIE_JAR="/tmp/login_test_cookies.txt"
rm -f "$COOKIE_JAR"

LOGIN_HTML=$(/usr/bin/curl -s -k -c "$COOKIE_JAR" "https://apidev.conexaopovosdafloresta.org.br/login")
CSRF=$(printf '%s\n' "$LOGIN_HTML" | grep -o 'name="_token" value="[^"]*"' | head -1 | cut -d'"' -f4)

echo "CSRF token: $CSRF"

POST_RES=$(/usr/bin/curl -s -k -b "$COOKIE_JAR" -c "$COOKIE_JAR" -L \
    -d "_token=$CSRF" \
    --data-urlencode "email=user@example.com" \
    --data-urlencode "password=<ROOT_PASSWORD>" \
    "https://apidev.conexaopovosdafloresta.org.br/login")

if echo "$POST_RES" | grep -q "Credenciais inválidas"; then
    echo "RESULT: INVALID_CREDENTIALS"
elif echo "$POST_RES" | grep -q "Confirmar acesso" || echo "$POST_RES" | grep -q "Solved"; then
    echo "RESULT: SUCCESS_LOGGED_IN"
else
    echo "RESULT: UNKNOWN"
fi
