# floinsights-deploy — Orchestration de production

Descripteur de déploiement de FloInsights sur **un VPS Hetzner unique** (Docker Compose).
Ce repo ne contient **aucun** code applicatif : il orchestre les images de
`floinsights-api` et `floinsights-web`, avec Caddy en frontal, PostgreSQL et Redis.

```
Internet ──▶ Cloudflare ──▶ Caddy (80/443)
                              ├─ /v1/*  ──▶ api  (NestJS, 3008)
                              └─ /*     ──▶ web  (Next.js, 3000)
                                            api ──▶ postgres · redis
```

## Layout serveur

```
/opt/floinsights/
├── deploy/   ← ce repo
├── api/      ← clone de floinsights-api
└── web/      ← clone de floinsights-web
```

Le compose référence `../api` et `../web` comme contextes de build (build-on-server,
aucun registry). Le navigateur ne voit qu'une origine (`app.floinsights.io`) → le
refresh token peut être un cookie `HttpOnly` (pas de stockage cross-origin).

## Première installation

```bash
# sur un VPS neuf, en root
git clone <URL_de_ce_repo> /opt/floinsights/deploy
cd /opt/floinsights/deploy
API_REPO=<url-api> WEB_REPO=<url-web> bash setup.sh   # docker + firewall + clones
cp .env.prod.example .env.prod                        # puis remplir TOUS les secrets
bash ../api/scripts/generate-keys.sh                  # clés RS256 → base64 dans .env.prod
make deploy
```

Génération de secrets forts : `openssl rand -base64 32`.

## Exploitation courante

| Commande | Effet |
|----------|-------|
| `make deploy` | git pull (api+web+deploy) → build → up -d |
| `make ps` / `make logs` | état / logs |
| `make logs-api` / `make logs-web` | logs d'un service |
| `make backup` | dump PostgreSQL immédiat |
| `make restore FILE=backups/pg_XXXX.sql.gz` | restauration |
| `make migrate` | migrations Prisma manuelles |
| `make shell-db` | psql |

## TLS / Cloudflare

1. Enregistrement DNS **A** `app.floinsights.io` → IP du VPS.
2. **1re émission** du certificat : laisser le DNS en *DNS only* (nuage gris) le temps
   que Caddy obtienne le certificat Let's Encrypt (HTTP-01), puis repasser en *Proxied*.
3. Cloudflare SSL/TLS : mode **Full (strict)**.
4. Alternative sans ACME public : décommenter `local_certs` dans le `Caddyfile` +
   Cloudflare Origin Certificate.

## Sauvegardes

- `backup.sh` : `pg_dump` gzippé dans `backups/`, envoi distant optionnel (rclone), purge à J+`BACKUP_RETENTION_DAYS`.
- Cron conseillé :
  ```
  0 3 * * *  cd /opt/floinsights/deploy && ./backup.sh >> /var/log/floinsights-backup.log 2>&1
  ```
- **Tester une restauration réelle** au moins une fois (un backup non restauré ne vaut rien) :
  ```bash
  make restore FILE=backups/pg_YYYYMMDD_HHMMSS.sql.gz
  ```

## Restauration complète (disaster recovery, RTO < 2h)

1. Nouveau VPS → `setup.sh`.
2. Restaurer `.env.prod` depuis le gestionnaire de secrets.
3. `make deploy`.
4. `make restore FILE=<dernier dump>`.
5. Vérifier `https://<DOMAIN>/v1/health` + un login.
6. Repointer le DNS Cloudflare vers la nouvelle IP.

## Rotation des clés JWT (RS256)

1. `bash ../api/scripts/generate-keys.sh` → nouvelles clés.
2. Mettre `JWT_PRIVATE_KEY` / `JWT_PUBLIC_KEY` (base64) dans `.env.prod`.
3. `make up` (recrée l'API). ⚠ invalide les access tokens en cours — les refresh
   tokens survivent selon la stratégie de validation.

## Notes de scaling (à ne PAS anticiper)

- Les crons tournent **dans le process API** (`@nestjs/schedule`). Valable pour **1 seule**
  instance API. Avant de passer à 2+ instances : verrou distribué Redis ou worker dédié,
  sinon chaque cron s'exécute en double.
- `postgres:15-alpine` (natif) suffit au palier P0. Passer à l'image pg_duckdb quand
  les requêtes analytics dépassent ~5 s (> 1M transactions).
