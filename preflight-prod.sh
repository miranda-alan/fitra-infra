#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env.production"
COMPOSE_FILE="$ROOT_DIR/docker-compose.prod.yml"
FAILURES=0
RUN_BACKUP=false

usage() {
  cat <<'EOF'
Uso:
  ./preflight-prod.sh [--admin-password "senha"] [--skip-login] [--with-backup]

Opcoes:
  --admin-password   Senha do admin para teste de login publico.
  --skip-login       Pula o teste de login (quando nao quiser informar senha).
  --with-backup      Executa backup de banco como ultimo teste.
EOF
}

ADMIN_PASSWORD=""
SKIP_LOGIN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --admin-password)
      if [[ $# -lt 2 ]]; then
        echo "Erro: --admin-password requer valor." >&2
        exit 1
      fi
      ADMIN_PASSWORD="$2"
      shift 2
      ;;
    --skip-login)
      SKIP_LOGIN=true
      shift
      ;;
    --with-backup)
      RUN_BACKUP=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Erro: opcao desconhecida: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Erro: arquivo $ENV_FILE nao encontrado." >&2
  echo "Execute: cp .env.production.example .env.production" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Erro: docker nao encontrado no PATH." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Erro: curl nao encontrado no PATH." >&2
  exit 1
fi

APP_DOMAIN="$(grep '^APP_DOMAIN=' "$ENV_FILE" | head -n1 | cut -d'=' -f2-)"
if [[ -z "$APP_DOMAIN" ]]; then
  echo "Erro: APP_DOMAIN vazio em $ENV_FILE" >&2
  exit 1
fi

if [[ "$APP_DOMAIN" == "app.seudominio.com" ]]; then
  echo "Erro: APP_DOMAIN ainda com valor de exemplo em $ENV_FILE" >&2
  exit 1
fi

cd "$ROOT_DIR"

pass() {
  echo "[PASS] $1"
}

fail() {
  echo "[FAIL] $1"
  FAILURES=$((FAILURES + 1))
}

echo "Iniciando preflight de producao para dominio: $APP_DOMAIN"

# 1) Containers no ar
if docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" ps >/tmp/fitra-preflight-ps.out 2>&1; then
  if grep -Eq "(Up|healthy)" /tmp/fitra-preflight-ps.out; then
    pass "Containers da aplicacao respondendo"
  else
    fail "Containers sem status esperado (Up/healthy)"
  fi
else
  fail "Falha ao consultar containers (docker compose ps)"
fi

# 2) DNS resolvendo
if command -v dig >/dev/null 2>&1; then
  DNS_IP="$(dig +short "$APP_DOMAIN" | tail -n1)"
  if [[ -n "$DNS_IP" ]]; then
    pass "DNS resolve para $DNS_IP"
  else
    fail "DNS nao resolveu para $APP_DOMAIN"
  fi
else
  echo "[WARN] dig nao encontrado; teste de DNS pulado"
fi

# 3) HTTP -> HTTPS
HTTP_HEADERS="$(curl -sSI "http://$APP_DOMAIN" || true)"
if echo "$HTTP_HEADERS" | grep -qiE '^location: https://'; then
  pass "Redirecionamento HTTP -> HTTPS ativo"
else
  fail "Sem redirecionamento HTTP -> HTTPS"
fi

# 4) TLS valido
if command -v openssl >/dev/null 2>&1; then
  TLS_INFO="$(echo | openssl s_client -connect "$APP_DOMAIN:443" -servername "$APP_DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -dates 2>/dev/null || true)"
  if [[ -n "$TLS_INFO" ]]; then
    pass "Certificado TLS apresentado"
  else
    fail "Falha ao validar certificado TLS"
  fi
else
  echo "[WARN] openssl nao encontrado; teste de TLS pulado"
fi

# 5) Swagger
SWAGGER_CODE="$(curl -s -o /tmp/fitra-swagger.out -w "%{http_code}" "https://$APP_DOMAIN/doc" || true)"
if [[ "$SWAGGER_CODE" == "200" || "$SWAGGER_CODE" == "301" || "$SWAGGER_CODE" == "302" ]]; then
  pass "Swagger publico responde (status $SWAGGER_CODE)"
else
  fail "Swagger nao respondeu como esperado (status $SWAGGER_CODE)"
fi

# 6) Migrations sem pendencias
MIGR_OUT="$(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec -T api npm run apply-db-migrations 2>&1 || true)"
if echo "$MIGR_OUT" | grep -qi "No migrations are pending"; then
  pass "Migrations sem pendencias"
else
  if echo "$MIGR_OUT" | grep -qi "has been executed successfully"; then
    pass "Migrations aplicadas durante preflight"
  else
    fail "Falha em migrations"
  fi
fi

# 7) Login publico
if [[ "$SKIP_LOGIN" == true ]]; then
  echo "[WARN] teste de login pulado (--skip-login)"
else
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    echo "[WARN] senha de admin nao informada; use --admin-password ou --skip-login"
    fail "Teste de login nao executado"
  else
    LOGIN_CODE="$(curl -s -o /tmp/fitra-login.out -w "%{http_code}" \
      -X POST "https://$APP_DOMAIN/v1/auth/login" \
      -H 'Content-Type: application/json' \
      -d "{\"email\":\"admin@admin.com\",\"password\":\"$ADMIN_PASSWORD\"}" || true)"
    if [[ "$LOGIN_CODE" == "201" || "$LOGIN_CODE" == "200" ]]; then
      pass "Login publico funcionando (status $LOGIN_CODE)"
    else
      fail "Login publico falhou (status $LOGIN_CODE)"
    fi
  fi
fi

# 8) Backup opcional
if [[ "$RUN_BACKUP" == true ]]; then
  if docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" exec -T fitra-pg pg_dump -U "$(grep '^DATABASE_USER=' "$ENV_FILE" | cut -d'=' -f2-)" "$(grep '^DATABASE_NAME=' "$ENV_FILE" | cut -d'=' -f2-)" >/dev/null 2>&1; then
    pass "Backup basico (pg_dump) executado"
  else
    fail "Falha ao executar backup basico"
  fi
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "Preflight finalizado: PASS"
  exit 0
else
  echo "Preflight finalizado: FAIL ($FAILURES falha(s))"
  exit 1
fi
