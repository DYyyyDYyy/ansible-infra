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
PLAYBOOK = ansible-playbook -i $(INVENTORY) --vault-password-file $(VAULT_PASS)
ROLES := $(notdir $(wildcard roles/*))
SCRIPTS := $(wildcard scripts/*.sh)

.PHONY: help venv lint test

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
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
