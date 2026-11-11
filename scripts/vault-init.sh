#!/usr/bin/env bash
# Generate the secrets for one environment and encrypt them with Ansible Vault.
#
#   scripts/vault-init.sh <env>
#
# Creates .vault_pass (if missing) and inventories/<env>/group_vars/all/vault.yml.
# If vault.yml already exists, only the keys it is missing are added, so a
# clone made before a new secret was introduced keeps its old secrets and
# gains the new ones. Existing values are never changed.
#
# Both files are git-ignored, so every clone gets its own random secrets. In a
# team you would commit the encrypted vault.yml and keep the vault password in
# a password manager or a CI secret instead.
set -euo pipefail

env_name=${1:?usage: $0 <env>}
pass_file=.vault_pass
vault_file=inventories/${env_name}/group_vars/all/vault.yml

random() { python3 -c 'import secrets; print(secrets.token_urlsafe(24))'; }

# Every secret the playbooks expect. "random" gets a generated value; "empty"
# is an optional secret the user fills in later with `ansible-vault edit`.
secrets=(
    vault_db_password:random
    vault_restic_password:random          # encrypts the backup repository
    vault_backup_password:random          # db -> rest-server HTTP login
    vault_telegram_bot_token:empty        # empty: alerts are not sent anywhere
    vault_telegram_chat_id:empty
)

if [[ ! -f $pass_file ]]; then
    (umask 077 && random >"$pass_file")
    echo "created $pass_file"
fi

current=---
if [[ -f $vault_file ]]; then
    current=$(ansible-vault view --vault-password-file "$pass_file" "$vault_file")
fi

missing=()
additions=
for entry in "${secrets[@]}"; do
    key=${entry%%:*}
    kind=${entry#*:}
    grep -qE "^${key}:" <<<"$current" && continue
    missing+=("$key")
    value=
    [[ $kind == random ]] && value=$(random)
    additions+=$(printf '%s: "%s"' "$key" "$value")$'\n'
done

if ((${#missing[@]} == 0)); then
    echo "$vault_file has every secret, leaving it alone"
    exit 0
fi

# Encrypt to a temporary file next to the target and rename it, so an
# interrupted run never leaves a half-written vault behind.
mkdir -p "$(dirname "$vault_file")"
tmp=$(mktemp "$vault_file.XXXXXX")
trap 'rm -f "$tmp"' EXIT
printf '%s\n%s' "$current" "$additions" |
    ansible-vault encrypt --vault-password-file "$pass_file" --output - >"$tmp"
mv "$tmp" "$vault_file"
trap - EXIT

echo "$vault_file: added ${missing[*]}"
echo "view with: ansible-vault view --vault-password-file $pass_file $vault_file"
