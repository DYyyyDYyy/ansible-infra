SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

# vagrant = real VMs (default), docker = systemd containers (CI, machines without libvirt)
ENV ?= vagrant

VENV := .venv
export PATH := $(CURDIR)/$(VENV)/bin:$(PATH)
export ANSIBLE_COLLECTIONS_PATH := $(CURDIR)/.collections

INVENTORY := inventories/$(ENV)
VAULT_PASS := .vault_pass
PLAYBOOK_ARGS = -i $(INVENTORY) --vault-password-file $(VAULT_PASS)
PLAYBOOK = ansible-playbook $(PLAYBOOK_ARGS)
ROLES := $(notdir $(wildcard roles/*))
SCRIPTS := $(wildcard scripts/*.sh)

# Load balancer URL from the host running make
LB_URL_vagrant := http://10.10.10.10
LB_URL_docker := http://127.0.0.1:8080
LB_URL := $(LB_URL_$(ENV))

# Two real commits of rest-api-transport-firm, used by the deploy demo/tests
APP_OLD := 700b12e56f410f06d7c0112628b74b1ae2dd4c37
APP_NEW := a07d9d0b7e4ea729bc5110a26d96b1424e6fb964

.PHONY: help venv lint test vault-init up provision deploy check-idempotence \
	zero-downtime test-rollback restore-test alert-test e2e lab-up lab-down down

help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  ENV=$(ENV)  (override: make up ENV=docker)"

$(VENV)/.installed: requirements-dev.txt requirements.yml
	uv venv --allow-existing --python 3.13 $(VENV)
	uv pip install --python $(VENV)/bin/python -r requirements-dev.txt
	ansible-galaxy collection install -r requirements.yml -p .collections
	touch $@

venv: $(VENV)/.installed ## Install pinned tooling and collections into .venv

lint: venv ## Run yamllint, ansible-lint and shellcheck
	yamllint .
	ansible-lint
	$(if $(SCRIPTS),shellcheck $(SCRIPTS))

test: venv ## Molecule for every role, or: make test ROLE=firewall PLATFORM=rocky10
	@for role in $(or $(ROLE),$(ROLES)); do \
		echo "==> molecule test: $$role $(PLATFORM)"; \
		(cd roles/$$role && molecule test $(if $(PLATFORM),--platform-name $(PLATFORM))) || exit 1; \
	done

## --- Environments -----------------------------------------------------------

# Always runs: the script only adds the secrets this vault is missing, so an
# old clone picks up secrets introduced later (and nothing else changes).
vault-init: venv ## Generate and encrypt this environment's secrets (adds missing ones)
	@scripts/vault-init.sh $(ENV)

up: venv vault-init ## Create the machines and provision everything
ifeq ($(ENV),vagrant)
	vagrant up
else
	$(MAKE) lab-up
endif
	$(MAKE) provision

provision: venv vault-init ## Run playbooks/site.yml
	$(PLAYBOOK) playbooks/site.yml

deploy: venv vault-init ## Rolling deploy: make deploy VERSION=<sha|tag>
	$(PLAYBOOK) playbooks/deploy.yml $(if $(VERSION),-e app_version=$(VERSION))

down: ## Destroy the machines
ifeq ($(ENV),vagrant)
	vagrant destroy -f
else
	$(MAKE) lab-down
endif

# The lab is always described by the docker inventory, whatever ENV says.
LAB_ARGS := -i inventories/docker --vault-password-file $(VAULT_PASS)

lab-up: venv ## Start the docker lab containers
	@$(MAKE) vault-init ENV=docker >/dev/null
	ansible-playbook $(LAB_ARGS) playbooks/lab.yml

lab-down: venv ## Remove the docker lab containers
	@$(MAKE) vault-init ENV=docker >/dev/null
	ansible-playbook $(LAB_ARGS) playbooks/lab.yml -e lab_state=absent

## --- Checks against a running environment ---------------------------------

check-idempotence: venv vault-init ## Re-run site.yml and fail if anything changes
	scripts/check-idempotence.sh $(PLAYBOOK_ARGS) playbooks/site.yml

zero-downtime: venv vault-init ## Deploy APP_OLD then APP_NEW under load, fail on any error
	$(PLAYBOOK) playbooks/deploy.yml -e app_version=$(APP_OLD)
	scripts/zero-downtime.sh $(LB_URL)/vehicles -- \
		$(PLAYBOOK) playbooks/deploy.yml -e app_version=$(APP_NEW)

test-rollback: venv vault-init ## Deploy a release whose smoke test fails, expect a rollback
	scripts/rollback-test.sh $(LB_URL) $(APP_OLD) $(APP_NEW) $(PLAYBOOK_ARGS)

restore-test: venv vault-init ## Back up now, restore into a scratch database, compare row counts
	$(PLAYBOOK) playbooks/restore-test.yml

alert-test: venv vault-init ## Stop the API and an exporter, expect the alerts in Alertmanager
	$(PLAYBOOK) playbooks/alert-test.yml

e2e: ## Full CI run on the docker lab: up, idempotence, deploys, restore, alerts
	$(MAKE) up ENV=docker
	$(MAKE) check-idempotence ENV=docker
	$(MAKE) zero-downtime ENV=docker
	$(MAKE) test-rollback ENV=docker
	$(MAKE) restore-test ENV=docker
	$(MAKE) alert-test ENV=docker
