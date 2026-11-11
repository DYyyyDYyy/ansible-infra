# Runbook: a deploy failed

**What happens automatically:** if anything fails after a host was taken out
of nginx, `deploy.yml` points `current` back to the previous release,
restarts it, checks `/health/ready` (process up and database reachable), puts the host back into nginx and stops. Hosts
after it are never touched, so the site keeps running on the old version.

## 1. Read the failure

The last lines of the playbook say which host and task failed:

```
fd3fea5... failed on app1 (Smoke-test the new release on /...). Rolled back to def475a...
```

## 2. Check that the rollback left everything healthy

Do not run `site.yml` or `make check-idempotence` now: they deploy the
`app_version` from the code, which may be the version that just failed.

```bash
ansible app -i inventories/vagrant -m command -a 'readlink /opt/transport-api/current'
ansible lb -i inventories/vagrant -b -m command -a 'grep server /etc/nginx/conf.d/upstream.conf'
curl -s http://10.10.10.10/health
```

No `down` should be left in the upstream file. If one is (the play was killed
mid-way), put the host back with:

```bash
ansible-playbook -i inventories/vagrant --vault-password-file .vault_pass playbooks/site.yml --limit lb
```

## 3. Find the cause on the failed host

```bash
sudo journalctl -u transport-api -n 100 --no-pager
sudo -u transport /opt/transport-api/releases/<version>/.venv/bin/python -c 'import app.main'
```

## 4. Roll back the whole tier by hand

Deploy the previous version explicitly; the same rolling procedure applies:

```bash
make deploy VERSION=<previous sha>
```
