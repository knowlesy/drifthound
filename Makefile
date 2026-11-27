# Makefile for DriftHound

# ── Local ─────────────────────────────────────────────────────────────────────

setup:
	@bundle install
	@bin/rails db:drop db:create db:migrate db:seed

setup-demo:
	@bundle install
	@bin/rails db:drop db:create db:migrate db:seed:demo

start:
	@bin/rails server

# ── Docker ────────────────────────────────────────────────────────────────────

docker-setup:
	@docker compose up -d --build postgres
	@echo "Waiting for postgres..."
	@until docker compose exec postgres pg_isready -U drifthound > /dev/null 2>&1; do sleep 1; done
	@docker compose run --rm app bin/rails db:drop db:create db:migrate db:seed
	@docker compose up -d app
	@echo "Waiting for app to be ready..."
	@until docker compose exec app curl -sf http://localhost:3000/up > /dev/null 2>&1; do sleep 1; done
	@echo "App is ready!"

docker-setup-demo:
	@docker compose up -d --build postgres
	@echo "Waiting for postgres..."
	@until docker compose exec postgres pg_isready -U drifthound > /dev/null 2>&1; do sleep 1; done
	@docker compose run --rm app bin/rails db:drop db:create db:migrate db:seed:demo
	@docker compose up -d app
	@echo "Waiting for app to be ready..."
	@until docker compose exec app curl -sf http://localhost:3000/up > /dev/null 2>&1; do sleep 1; done
	@echo "App is ready!"

docker-start:
	@docker compose up -d

docker-stop:
	@docker compose down

docker-destroy:
	@docker compose down -v

docker-token:
	@docker compose exec app bin/rails api_tokens:generate[my-ci-token]

# OIDC login against a local mock identity provider (see docker-compose.oidc.yml).
# Run docker-setup (or docker-setup-demo) once first to create the database.
OIDC_COMPOSE = docker compose -f docker-compose.yml -f docker-compose.oidc.yml

docker-oidc-start:
	@$(OIDC_COMPOSE) build app
	@$(OIDC_COMPOSE) up -d
	@echo "Waiting for app and mock identity provider..."
	@until curl -sf http://localhost:3000/up > /dev/null 2>&1; do sleep 1; done
	@until curl -sf http://localhost:8090/default/.well-known/openid-configuration > /dev/null 2>&1; do sleep 1; done
	@echo "Ready: open http://localhost:3000/login and click \"Sign in with SSO\"."
	@echo "Mock users: admin, editor, viewer, multi, nogroups, unverified, clash, clash-demo (dev/oidc/mock-oauth2-server.json)"

docker-oidc-stop:
	@$(OIDC_COMPOSE) down

# Prometheus and Grafana next to the app (see docker-compose.monitoring.yml).
# Run docker-setup-demo (or docker-setup) once first to create the database.
MONITORING_COMPOSE = docker compose -f docker-compose.yml -f docker-compose.monitoring.yml
MONITORING_TOKEN = dev/monitoring/.token

docker-monitoring-start:
	@$(MONITORING_COMPOSE) build app
	@$(MONITORING_COMPOSE) up -d postgres app
	@echo "Waiting for app..."
	@until curl -sf http://localhost:3000/up > /dev/null 2>&1; do sleep 1; done
	@$(MONITORING_COMPOSE) exec -T app bin/rails api_tokens:monitoring_token > $(MONITORING_TOKEN).tmp \
		&& grep -Eq '^[A-Za-z0-9]+$$' $(MONITORING_TOKEN).tmp \
		&& mv $(MONITORING_TOKEN).tmp $(MONITORING_TOKEN) \
		|| { rm -f $(MONITORING_TOKEN).tmp; echo "Could not create the scrape token"; exit 1; }
	@$(MONITORING_COMPOSE) up -d prometheus grafana
	@echo "Waiting for Grafana..."
	@until curl -sf http://localhost:3001/api/health > /dev/null 2>&1; do sleep 1; done
	@echo "Ready: Grafana at http://localhost:3001 (DriftHound dashboard), Prometheus at http://localhost:9090"
	@echo "The read API token for the scrape is in $(MONITORING_TOKEN) (git-ignored)."

docker-monitoring-stop:
	@$(MONITORING_COMPOSE) down

# ── Testing ───────────────────────────────────────────────────────────────────

prepare-test-db:
	@docker compose up -d
	@RAILS_ENV=test bin/rails db:create db:migrate

run-tests:
	@RAILS_ENV=test bin/rails test
	@RAILS_ENV=test bin/rails test:system
