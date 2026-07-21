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

## Monitoring (Grafana Cloud — free tier)

Stack de supervision **sans rien self-héberger** : métriques + logs + dashboards
+ alertes e-mail, sur le free tier de Grafana Cloud.

### Comment ça marche (architecture *push*)

```
VPS Hetzner (réseau Docker interne)
  api  ──/v1/metrics──┐
  logs conteneurs ────┤→  alloy (agent)  ──push HTTPS──▶  Grafana Cloud
  …                   ┘   scrape + tail                   (dashboards, alertes)
```

- L'API expose ses métriques sur `GET /v1/metrics` (Node/process : CPU, RAM,
  event-loop, GC). Endpoint **interne uniquement** : Caddy renvoie **404** pour
  `/v1/metrics` côté Internet ; seul l'agent le scrape via `api:3008` sur le
  réseau Docker.
- L'agent **Grafana Alloy** scrape ces métriques (30 s) + collecte les logs
  Docker, et **pousse** le tout vers Grafana Cloud (rien n'entre depuis Internet).
- Le jour où le volume l'exige, on self-héberge Prometheus+Loki+Grafana **sans
  changer une ligne de code** (mêmes métriques).

### Déjà livré dans ce repo (aucune action requise)

| Élément | Emplacement |
|---|---|
| Endpoint métriques | API `GET /v1/metrics` (module `metrics`) |
| Blocage public | `Caddyfile` (`/v1/metrics` → 404) |
| Agent (opt-in) | service `alloy` dans `docker-compose.prod.yml` (profil `monitoring`) |
| Config agent | `alloy/config.alloy` |
| Dashboard | `monitoring/grafana-dashboard.json` |
| Règles d'alerte | `monitoring/alerts.yml` |

### Mise en œuvre — pas à pas

**1. Créer le compte.** grafana.com → S'inscrire (gratuit) → créer une stack
Grafana Cloud.

**2. Récupérer les identifiants.** Dans Grafana Cloud :
- **Connections → Data sources → Prometheus** : note l'**URL de push**
  (`remote_write`, se termine par `/api/prom/push`) et le **username** (un
  identifiant numérique).
- **Connections → Data sources → Loki** : note l'**URL** (`…/loki/api/v1/push`)
  et le **username**.
- **Administration → Access Policies** → créer une *Access Policy* avec les
  scopes `metrics:write` **et** `logs:write`, puis générer un **token**. Ce token
  sert de mot de passe pour les deux (Prometheus et Loki).

**3. Renseigner `.env.prod`** (voir `.env.prod.example`) :
```
GRAFANA_CLOUD_API_KEY=<token de l'access policy>
GRAFANA_CLOUD_PROM_URL=https://prometheus-prod-XX.grafana.net/api/prom/push
GRAFANA_CLOUD_PROM_USER=<username Prometheus>
GRAFANA_CLOUD_LOKI_URL=https://logs-prod-XX.grafana.net/loki/api/v1/push
GRAFANA_CLOUD_LOKI_USER=<username Loki>
```

**4. Démarrer l'agent** (profil opt-in ; `make deploy` ne le lance pas) :
```bash
make monitoring        # = docker compose --profile monitoring up -d alloy
```

**5. Vérifier** :
```bash
make logs-api           # (rien de spécial) — puis les logs de l'agent :
docker compose --env-file .env.prod -f docker-compose.prod.yml logs -f alloy
```
Dans Grafana Cloud → **Explore** (datasource Prometheus), lancer
`up{job="floinsights-api"}` → doit renvoyer **1** au bout de ~30–60 s.

**6. Importer le dashboard.** Grafana Cloud → **Dashboards → New → Import** →
coller `monitoring/grafana-dashboard.json` (ou l'uploader) → choisir la datasource
Prometheus quand c'est demandé. 8 panneaux : état `up`, uptime, RSS, event-loop
lag p99, CPU, mémoire (RSS vs heap), lag moyen/p99, handles/requests.

**7. Activer les alertes e-mail** :
- **Alerting → Contact points** → créer un point de contact *Email* (ton adresse).
- **Alerting → Alert rules → New alert rule** → pour chaque règle de
  `monitoring/alerts.yml`, coller l'`expr` PromQL, régler la durée (`for`) et le
  seuil, router vers le contact point e-mail. 4 règles : `APIDown` (critique),
  event-loop lag, mémoire, CPU — seuils à ajuster selon le VPS.
  *(Avancé : `mimirtool rules load monitoring/alerts.yml`.)*

### Compléments (gratuits, recommandés)

- **UptimeRobot** → ping `https://<DOMAIN>/v1/health` toutes les 5 min, e-mail si
  down. Le filet le plus simple — à mettre en premier.
- **Sentry** (`SENTRY_DSN` dans `.env.prod`) → e-mail sur les exceptions applicatives.

### Dépannage

| Symptôme | Piste |
|---|---|
| `up` reste absent / à 0 | l'agent tourne ? (`logs alloy`) · `api` est-il *healthy* ? · le réseau Docker relie-t-il alloy↔api ? |
| Logs de l'agent : `401/403` au push | token invalide ou scopes manquants (`metrics:write`/`logs:write`) · mauvais `*_USER` |
| Rien dans les dashboards | datasource Prometheus mal sélectionnée à l'import · attendre le 1er scrape (~1 min) |
| `/v1/metrics` renvoie 404 en local | normal en prod (bloqué par Caddy) ; en direct sur l'API : `http://localhost:3008/v1/metrics` |
| Pas de mails | contact point *Email* créé et **routé** dans la notification policy ? · alerte réellement en *Firing* ? |

> Les métriques et logs n'apparaissent qu'**après** le démarrage de l'agent et le
> 1er scrape. Sans `make monitoring`, la stack applicative tourne normalement,
> simplement sans supervision Grafana.

## Notes de scaling (à ne PAS anticiper)

- Les crons tournent **dans le process API** (`@nestjs/schedule`). Valable pour **1 seule**
  instance API. Avant de passer à 2+ instances : verrou distribué Redis ou worker dédié,
  sinon chaque cron s'exécute en double.
- `postgres:15-alpine` (natif) suffit au palier P0. Passer à l'image pg_duckdb quand
  les requêtes analytics dépassent ~5 s (> 1M transactions).
