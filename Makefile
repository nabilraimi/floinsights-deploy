# FloInsights — commandes d'exploitation (à lancer depuis /opt/floinsights/deploy)
# Toujours passer --env-file : env_file: alimente le conteneur, PAS l'interpolation ${...} du compose.

COMPOSE := docker compose --env-file .env.prod -f docker-compose.prod.yml
API_DIR := ../api
WEB_DIR := ../web

.DEFAULT_GOAL := help
.PHONY: help deploy pull build up down restart ps logs logs-api logs-web \
        migrate backup restore shell-api shell-db check

help: ## Affiche cette aide
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

deploy: pull build up ## Déploiement complet : git pull + build + up -d (migrations au boot de l'API)
	@echo "✅ Déploiement terminé. Vérifier : make logs-api puis https://$$(grep ^DOMAIN .env.prod | cut -d= -f2)"

pull: ## git pull des 3 repos (api, web, deploy)
	cd $(API_DIR) && git pull --ff-only
	cd $(WEB_DIR) && git pull --ff-only
	git pull --ff-only

build: ## (Re)build des images api + web
	$(COMPOSE) build

up: ## Démarre/actualise la stack en arrière-plan
	$(COMPOSE) up -d

down: ## Arrête la stack (conserve les volumes)
	$(COMPOSE) down

restart: ## Redémarre tous les services
	$(COMPOSE) restart

ps: ## État des conteneurs
	$(COMPOSE) ps

logs: ## Logs de tous les services (suivi)
	$(COMPOSE) logs -f --tail=100

logs-api: ## Logs de l'API
	$(COMPOSE) logs -f --tail=200 api

logs-web: ## Logs du web
	$(COMPOSE) logs -f --tail=200 web

migrate: ## Applique les migrations Prisma manuellement (normalement fait au boot)
	$(COMPOSE) exec api npx prisma migrate deploy

backup: ## Sauvegarde immédiate de la base
	./backup.sh

restore: ## Restaure un dump : make restore FILE=backups/pg_YYYYMMDD.sql.gz
	@test -n "$(FILE)" || (echo "Usage: make restore FILE=backups/pg_XXXX.sql.gz" && exit 1)
	gunzip < $(FILE) | $(COMPOSE) exec -T postgres psql -U $$(grep ^POSTGRES_USER .env.prod | cut -d= -f2) -d $$(grep ^POSTGRES_DB .env.prod | cut -d= -f2)

shell-api: ## Shell dans le conteneur API
	$(COMPOSE) exec api sh

shell-db: ## psql dans la base
	$(COMPOSE) exec postgres psql -U $$(grep ^POSTGRES_USER .env.prod | cut -d= -f2) -d $$(grep ^POSTGRES_DB .env.prod | cut -d= -f2)

check: ## Vérifie le healthcheck de l'API depuis le conteneur web
	$(COMPOSE) exec web wget -qO- http://api:3008/v1/health || true
