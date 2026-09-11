#!/usr/bin/env bash
set -euo pipefail

export DOCKER_BUILDKIT=1
export COMPOSE_DOCKER_CLI_BUILD=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$(cd "$ROOT_DIR/../api" && pwd)"
VIEW_DIR="$(cd "$ROOT_DIR/../view" && pwd)"
ARGS=("$@")
MODE="${1:-dev}"
SEED="${2:-}"
DEPLOY_BRANCH="main"

usage() {
  cat <<'EOF'
Uso:
  ./deploy.sh dev
  ./deploy.sh dev seed
  ./deploy.sh prod
  ./deploy.sh prod seed

Comportamento:
  - Confere que api e view estao como repositorios irmaos
  - Em producao: atualiza api, view e infra na branch main
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

update_repo() {
  local dir="$1"
  local name="$2"

  if [[ ! -d "$dir/.git" ]]; then
    echo "Erro: $name nao e um repositorio git: $dir" >&2
    exit 1
  fi

  if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    echo "Erro: $name tem alteracoes locais em $dir." >&2
    echo "Commit, stash ou descarte antes de rodar o deploy." >&2
    exit 1
  fi

  echo "  - $name: $DEPLOY_BRANCH"
  git -C "$dir" fetch origin
  git -C "$dir" checkout "$DEPLOY_BRANCH"
  git -C "$dir" pull --ff-only origin "$DEPLOY_BRANCH"
}

if [[ "$MODE" == "prod" && -z "${FITRA_DEPLOY_REEXEC:-}" ]]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "Erro: git nao encontrado no PATH." >&2
    exit 1
  fi

  echo "[1/4] Atualizando repositorios ($DEPLOY_BRANCH)..."
  infra_before="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  update_repo "$API_DIR" "api"
  update_repo "$VIEW_DIR" "view"
  update_repo "$ROOT_DIR" "infra"
  infra_after="$(git -C "$ROOT_DIR" rev-parse HEAD)"

  if [[ "$infra_before" != "$infra_after" ]]; then
    echo "infra atualizado; reiniciando o deploy com o script novo..."
    exec env FITRA_DEPLOY_REEXEC=1 "$ROOT_DIR/deploy.sh" "${ARGS[@]}"
  fi
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

if [[ "$MODE" == "prod" ]]; then
  echo "[2/4] Subindo stack ($MODE)..."
else
  echo "[1/3] Subindo stack ($MODE)..."
fi
compose up -d --build --remove-orphans

if [[ "$MODE" == "prod" ]]; then
  echo "[3/4] Aplicando migrations..."
else
  echo "[2/3] Aplicando migrations..."
fi
compose exec -T api npm run apply-db-migrations

if [[ "$SEED" == "seed" ]]; then
  if [[ "$MODE" == "prod" ]]; then
    echo "[4/4] Aplicando seeds..."
  else
    echo "[3/3] Aplicando seeds..."
  fi
  compose exec -T api npm run apply-db-seeds
else
  if [[ "$MODE" == "prod" ]]; then
    echo "[4/4] Seed ignorado. Use: ./deploy.sh $MODE seed"
  else
    echo "[3/3] Seed ignorado. Use: ./deploy.sh $MODE seed"
  fi
fi

echo "Deploy concluido com sucesso."
