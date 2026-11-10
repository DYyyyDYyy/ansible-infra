#!/usr/bin/env bash
# Generate the secrets for one environment and encrypt them with Ansible Vault.
#
#   scripts/vault-init.sh <env>
#
# Creates .vault_pass (if missing) and inventories/<env>/group_vars/all/vault.yml.
# Both are git-ignored, so every clone gets its own random secrets. In a team
# you would commit the encrypted vault.yml and keep the vault password in a
# password manager or a CI secret instead.
set -euo pipefail

env_name=${1:?usage: $0 <env>}
pass_file=.vault_pass
vault_file=inventories/${env_name}/group_vars/all/vault.yml

random() { python3 -c 'import secrets; print(secrets.token_urlsafe(24))'; }

if [[ ! -f $pass_file ]]; then
    (umask 077 && random > "$pass_file")
    echo "created $pass_file"
fi

if [[ -f $vault_file ]]; then
    echo "$vault_file already exists, leaving it alone"
    exit 0
fi

mkdir -p "$(dirname "$vault_file")"
printf -- '---\nvault_db_password: "%s"\n' "$(random)" |
    ansible-vault encrypt --vault-password-file "$pass_file" --output "$vault_file"
echo "created $vault_file (view with: ansible-vault view --vault-password-file $pass_file $vault_file)"
