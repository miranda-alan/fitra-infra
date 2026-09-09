#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$(cd "$ROOT_DIR/../api" && pwd)"
VIEW_DIR="$(cd "$ROOT_DIR/../view" && pwd)"
MODE="${1:-dev}"
SEED="${2:-}"

usage() {
  cat <<'EOF'
Uso:
  ./deploy.sh dev
  ./deploy.sh dev seed
  ./deploy.sh prod
  ./deploy.sh prod seed

Comportamento:
  - Confere que api e view estao como repositorios irmaos
  - Sobe os containers com build
  - Aplica migrations automaticamente
  - Executa seed apenas se passar o argumento "seed"
EOF
}

if [[ "$MODE" != "dev" && "$MODE" != "prod" ]]; then
  usage
  exit 1
fi

cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "Erro: docker nao encontrado no PATH." >&2
  exit 1
fi

if [[ ! -f "$API_DIR/Dockerfile" ]]; then
  echo "Erro: Dockerfile da API nao encontrado em $API_DIR" >&2
  echo "Clone api, view e infra como diretorios irmaos." >&2
  exit 1
fi

if [[ ! -f "$VIEW_DIR/Dockerfile" ]]; then
  echo "Erro: Dockerfile da view nao encontrado em $VIEW_DIR" >&2
  echo "Clone api, view e infra como diretorios irmaos." >&2
  exit 1
fi

if [[ "$MODE" == "dev" && ! -f "$API_DIR/.env" ]]; then
  echo "Erro: arquivo .env nao encontrado em $API_DIR" >&2
  echo "Copie o template e preencha os valores antes de continuar:" >&2
  echo "  cp $API_DIR/.env.example $API_DIR/.env" >&2
  exit 1
fi

if [[ "$MODE" == "prod" ]]; then
  if [[ ! -f ".env.production" ]]; then
    echo "Erro: arquivo .env.production nao encontrado em $ROOT_DIR" >&2
    echo "Copie o template e preencha os valores antes de continuar:" >&2
    echo "  cp .env.production.example .env.production" >&2
    exit 1
  fi

  if ! grep -q '^APP_DOMAIN=' .env.production; then
    echo "Erro: APP_DOMAIN nao definido em .env.production" >&2
    exit 1
  fi

  if grep -q '^APP_DOMAIN=app\.seudominio\.com$' .env.production; then
    echo "Erro: APP_DOMAIN ainda esta com valor de exemplo." >&2
    exit 1
  fi
fi

compose() {
  if [[ "$MODE" == "prod" ]]; then
    docker compose -f docker-compose.prod.yml --env-file .env.production "$@"
  else
    docker compose "$@"
  fi
}

echo "[1/3] Subindo stack ($MODE)..."
compose up -d --build

echo "[2/3] Aplicando migrations..."
compose exec -T api npm run apply-db-migrations

if [[ "$SEED" == "seed" ]]; then
  echo "[3/3] Aplicando seeds..."
  compose exec -T api npm run apply-db-seeds
else
  echo "[3/3] Seed ignorado. Use: ./deploy.sh $MODE seed"
fi

echo "Deploy concluido com sucesso."
