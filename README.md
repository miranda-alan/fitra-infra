# FITRA - Infra

Infraestrutura para subir API, view, Postgres e Redis em conjunto.
Os repositorios `api`, `view` e `infra` precisam ser diretorios irmaos:

```text
fitra/
  api/
  view/
  infra/   <- este repositorio
```

Na VPS, o caminho esperado e `/opt/fitra/{api,view,infra}`.

Observacao: em producao na Hostinger, este projeto usa o Traefik ja existente
na VPS. O compose de producao nao sobe Caddy.

## Deploy em um comando

No diretorio `infra`:

```bash
./deploy.sh dev
```

Com seed:

```bash
./deploy.sh dev seed
```

Producao:

```bash
cp .env.production.example .env.production
./deploy.sh prod
```

## 1) Subir ambiente local

```bash
cd /Users/alan/projects/fitra/infra
cp ../api/.env.example ../api/.env
./deploy.sh dev seed
```

Acessos locais:

- Frontend: `http://localhost:8080`
- API (via proxy): `http://localhost:8080/v1`
- Swagger (via proxy): `http://localhost:8080/doc`

O Caddy local usa a porta `8080` para nao conflitar com outras stacks (por exemplo AFM na `80`).
Postgres e Redis ficam so na rede Docker. Para `make dev` na API, use o container
avulso `fitra-postgres` na porta `5433` ou publique as portas no compose.

Somente banco e redis:

```bash
docker compose up -d fitra-pg fitra-redis
```

## 2) Rodar migrations e seed

O `deploy.sh` ja aplica migrations. Para rodar de novo:

```bash
docker compose exec api npm run apply-db-migrations
docker compose exec api npm run apply-db-seeds
```

Usuario admin criado pelo seed: `admin@admin.com` / `12345`.

## 3) Producao (VPS)

1. Clone os tres repositorios como irmaos:

```bash
mkdir -p /opt/fitra
cd /opt/fitra
git clone git@github.com:miranda-alan/fitra-api.git api
git clone git@github.com:miranda-alan/fitra-view.git view
git clone git@github.com:miranda-alan/fitra-infra.git infra
```

2. Copie o template de producao:

```bash
cd /opt/fitra/infra
cp .env.production.example .env.production
```

3. Confirme `APP_DOMAIN` e ajuste senhas e `JWT_SECRET`.

4. Garanta que o Traefik da VPS esteja ativo com Docker provider habilitado e
   `certresolver` com nome `letsencrypt`.

5. Suba os servicos:

```bash
./deploy.sh prod seed
```

## 3.1) Adminer (gerenciar o banco pelo navegador)

O Postgres continua acessivel so na rede Docker. O Adminer entra pelo Traefik em
`https://db.<APP_DOMAIN>`, sem publicar `5432` no host.

1. Crie o DNS `db.<APP_DOMAIN>` apontando para o IP da VPS.
2. Suba (ou recrie) o servico:

```bash
cd /opt/fitra/infra
docker compose -f docker-compose.prod.yml --env-file .env.production up -d adminer
```

3. Acesse `https://db.<APP_DOMAIN>` e entre com:

- Sistema: `PostgreSQL`
- Servidor: `fitra-pg`
- Usuario: valor de `DATABASE_USER`
- Senha: valor de `DATABASE_PASSWORD`
- Base: valor de `DATABASE_NAME`

Nao use `127.0.0.1` nem o IP publico no campo servidor.

## 4) Logs e status

```bash
docker compose ps
docker compose logs -f api
docker compose logs -f view
```

Em producao:

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production ps
docker compose -f docker-compose.prod.yml --env-file .env.production logs -f api view
```

## 5) Parar e limpar

```bash
docker compose down
# com volumes (cuidado: apaga banco e redis)
docker compose down -v
```

## 6) Checklist de go-live seguro

1. DNS resolvendo para a VPS

```bash
dig +short SEU_DOMINIO
```

2. Certificado TLS valido e emitido pelo Let's Encrypt

```bash
echo | openssl s_client -connect SEU_DOMINIO:443 -servername SEU_DOMINIO 2>/dev/null | openssl x509 -noout -issuer -dates
```

3. Redirecionamento HTTP -> HTTPS funcionando

```bash
curl -I http://SEU_DOMINIO
```

4. Containers da aplicacao saudaveis

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production ps
```

5. Login funcionando via dominio publico

```bash
curl -i -s -X POST https://SEU_DOMINIO/v1/auth/login \
	-H 'Content-Type: application/json' \
	-d '{"email":"admin@admin.com","password":"SENHA_ADMIN"}'
```

6. Swagger publico respondendo

```bash
curl -I https://SEU_DOMINIO/doc
```

7. Verificacao de logs sem erro recorrente

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production logs --tail=200 api view
```

8. Validacao de migrations (nao deve haver pendencias)

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production exec -T api npm run apply-db-migrations
```

9. Backup manual de banco gerado com sucesso

```bash
docker compose -f docker-compose.prod.yml --env-file .env.production exec -T fitra-pg \
	pg_dump -U "$DATABASE_USER" "$DATABASE_NAME" | gzip > /opt/backups/fitra-$(date +%F).sql.gz
```

Se qualquer item falhar, nao avance para abertura oficial do sistema.

## 7) Preflight automatizado (PASS/FAIL)

```bash
cd /Users/alan/projects/fitra/infra
./preflight-prod.sh --admin-password "SUA_SENHA_ADMIN"
```

Opcoes uteis:

```bash
./preflight-prod.sh --skip-login
./preflight-prod.sh --admin-password "SUA_SENHA_ADMIN" --with-backup
```

O script retorna codigo 0 quando todos os testes passam, e codigo 1 quando ha falhas.

## 8) Dominio apex e www

O compose de producao atende `APP_DOMAIN` e `www.APP_DOMAIN`.
O Traefik pede um certificado Let's Encrypt com os dois nomes (SAN).

Apos atualizar os labels, recrie `api` e `view`:

```bash
cd /opt/fitra/infra
docker compose -f docker-compose.prod.yml --env-file .env.production up -d --force-recreate api view
```
