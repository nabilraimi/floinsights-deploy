#!/usr/bin/env bash
# FloInsights — sauvegarde PostgreSQL.
# Dump gzippé local + envoi distant (Cloudflare R2 via rclone) + purge.
# À lancer depuis /opt/floinsights/deploy. Cron conseillé : tous les jours 03h.
#   0 3 * * *  cd /opt/floinsights/deploy && ./backup.sh >> /var/log/floinsights-backup.log 2>&1
set -euo pipefail

cd "$(dirname "$0")"
ENV_FILE=".env.prod"
[ -f "$ENV_FILE" ] || { echo "❌ $ENV_FILE introuvable"; exit 1; }

# Charge les variables nécessaires
POSTGRES_USER=$(grep ^POSTGRES_USER "$ENV_FILE" | cut -d= -f2)
POSTGRES_DB=$(grep ^POSTGRES_DB "$ENV_FILE" | cut -d= -f2)
RETENTION=$(grep ^BACKUP_RETENTION_DAYS "$ENV_FILE" | cut -d= -f2 || echo 7)
REMOTE=$(grep ^BACKUP_REMOTE "$ENV_FILE" | cut -d= -f2 || echo "")
RETENTION=${RETENTION:-7}

COMPOSE="docker compose --env-file $ENV_FILE -f docker-compose.prod.yml"
STAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="backups"
OUT_FILE="$OUT_DIR/pg_${STAMP}.sql.gz"
mkdir -p "$OUT_DIR"

echo "▶ Dump de $POSTGRES_DB → $OUT_FILE"
$COMPOSE exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --clean --if-exists \
	| gzip > "$OUT_FILE"

SIZE=$(du -h "$OUT_FILE" | cut -f1)
echo "✅ Dump local OK ($SIZE)"

# Envoi distant (optionnel : nécessite rclone configuré, cf. README)
if [ -n "$REMOTE" ] && command -v rclone >/dev/null 2>&1; then
	echo "▶ Envoi vers $REMOTE"
	rclone copy "$OUT_FILE" "$REMOTE" && echo "✅ Copie distante OK"
	rclone delete --min-age "${RETENTION}d" "$REMOTE" 2>/dev/null || true
else
	echo "⚠ Envoi distant ignoré (BACKUP_REMOTE vide ou rclone absent)."
fi

# Purge locale
find "$OUT_DIR" -name 'pg_*.sql.gz' -mtime +"$RETENTION" -delete
echo "✅ Purge locale (> ${RETENTION}j) terminée"
