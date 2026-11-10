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
VAULT_FILE := $(INVENTORY)/group_vars/all/vault.yml
PLAYBOOK_ARGS = -i $(INVENTORY) --vault-password-file $(VAULT_PASS)
PLAYBOOK = ansible-playbook $(PLAYBOOK_ARGS)
ROLES := $(notdir $(wildcard roles/*))
SCRIPTS := $(wildcard scripts/*.sh)

# Load balancer URL from the host running make
LB_URL_vagrant := http://10.10.10.10
LB_URL_docker := http://127.0.0.1:8080
LB_URL := $(LB_URL_$(ENV))

# Two real commits of rest-api-transport-firm, used by the deploy demo/tests
APP_OLD := def475af343b98ff25ab5b253d328745f3378a20
APP_NEW := fd3fea549ecb92ee7ff98fd5638e0ccfcbc4aabc

.PHONY: help venv lint test vault-init up provision deploy check-idempotence \
	zero-downtime test-rollback e2e lab-up lab-down down

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

test: venv ## Run Molecule for every role, or one: make test ROLE=firewall
	@for role in $(or $(ROLE),$(ROLES)); do \
		echo "==> molecule test: $$role"; \
		(cd roles/$$role && molecule test) || exit 1; \
	done

## --- Environments -----------------------------------------------------------

$(VAULT_FILE):
	scripts/vault-init.sh $(ENV)

vault-init: venv $(VAULT_FILE) ## Generate and encrypt this environment's secrets

up: venv $(VAULT_FILE) ## Create the machines and provision everything
ifeq ($(ENV),vagrant)
	vagrant up --no-provision
else
	$(MAKE) lab-up
endif
	$(MAKE) provision

provision: venv $(VAULT_FILE) ## Run playbooks/site.yml
	$(PLAYBOOK) playbooks/site.yml

deploy: venv $(VAULT_FILE) ## Rolling deploy: make deploy VERSION=<sha|tag>
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

check-idempotence: venv $(VAULT_FILE) ## Re-run site.yml and fail if anything changes
	scripts/check-idempotence.sh $(PLAYBOOK_ARGS) playbooks/site.yml

zero-downtime: venv $(VAULT_FILE) ## Deploy APP_OLD then APP_NEW under load, fail on any error
	$(PLAYBOOK) playbooks/deploy.yml -e app_version=$(APP_OLD)
	scripts/zero-downtime.sh $(LB_URL)/vehicles -- \
		$(PLAYBOOK) playbooks/deploy.yml -e app_version=$(APP_NEW)

test-rollback: venv $(VAULT_FILE) ## Deploy a release whose smoke test fails, expect a rollback
	scripts/rollback-test.sh $(LB_URL) $(APP_OLD) $(APP_NEW) $(PLAYBOOK_ARGS)

e2e: ## Full CI run on the docker lab: up, idempotence, zero-downtime, rollback
	$(MAKE) up ENV=docker
	$(MAKE) check-idempotence ENV=docker
	$(MAKE) zero-downtime ENV=docker
	$(MAKE) test-rollback ENV=docker
