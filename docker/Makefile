# Run this Makefile from the docker/ directory: make <target>
# Default targets use the dev environment (docker-compose.yml)
# Use 'make prod-<target>' for production (docker-compose.prod.yml)
.PHONY: build up down logs shell test clean init prod-build prod-up prod-down prod-init

build:
	docker compose build

up:
	docker compose up -d --wait

down:
	docker compose down -v

logs:
	docker compose logs -f

shell:
	docker compose exec app bash

test: test-install test-ldap test-username-guard test-cron test-worker test-cache test-apikey

test-install:
	./tests/test_install.sh

test-ldap:
	./tests/test_ldap.sh

test-username-guard:
	./tests/test_username_guard.sh

test-cron:
	./tests/test_cron.sh

test-worker:
	./tests/test_worker.sh

test-cache:
	./tests/test_cache.sh

test-apikey:
	./tests/test_apikey.sh

clean:
	docker compose down -v --rmi all

init: build up

# Production targets
prod-build:
	docker compose -f docker-compose.prod.yml build

prod-up:
	docker compose -f docker-compose.prod.yml up -d --wait

prod-down:
	docker compose -f docker-compose.prod.yml down -v

prod-init: prod-build prod-up
