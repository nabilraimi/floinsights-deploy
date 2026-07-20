#!/usr/bin/env bash
# FloInsights — provisionnement initial d'un VPS Hetzner (Debian/Ubuntu).
# À lancer UNE fois en root sur un serveur neuf.
set -euo pipefail

BASE_DIR="/opt/floinsights"
API_REPO="${API_REPO:-git@github.com:VOTRE_ORG/floinsights-api.git}"
WEB_REPO="${WEB_REPO:-git@github.com:VOTRE_ORG/floinsights-web.git}"

echo "═══ 1. Paquets de base ═══"
apt-get update -y
apt-get install -y ca-certificates curl git ufw

echo "═══ 2. Docker (si absent) ═══"
if ! command -v docker >/dev/null 2>&1; then
	curl -fsSL https://get.docker.com | sh
fi
docker --version && docker compose version

echo "═══ 3. Pare-feu (SSH + HTTP + HTTPS uniquement) ═══"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "═══ 4. Clonage des repos sous $BASE_DIR ═══"
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"
[ -d api ]    || git clone "$API_REPO" api
[ -d web ]    || git clone "$WEB_REPO" web
# deploy = ce repo, déjà présent si vous lancez ce script depuis lui.

echo ""
echo "✅ Provisionnement terminé."
echo "➡ Étapes suivantes :"
echo "   1) cd $BASE_DIR/deploy"
echo "   2) cp .env.prod.example .env.prod   (puis remplir TOUS les secrets)"
echo "   3) bash ../api/scripts/generate-keys.sh   (clés RS256 → coller en base64 dans .env.prod)"
echo "   4) make deploy"
echo "   5) Vérifier : make logs-api  puis  https://<DOMAIN>/v1/health"
echo ""
echo "⚠ DNS Cloudflare : créer l'enregistrement A <DOMAIN> → IP du VPS."
echo "   Pour la 1re émission du certificat Let's Encrypt, mettre l'enregistrement"
echo "   en 'DNS only' (nuage gris), puis repasser en 'Proxied' + SSL 'Full (strict)'."
