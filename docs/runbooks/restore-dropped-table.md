# Runbook: a table was dropped or its rows deleted

**Symptoms:** the API returns 500 for one resource (`relation "orders" does
not exist`), or rows that should be there are gone.

**Do not** restore the backup over the live database: that throws away
everything written since the snapshot, in every table. Restore it next to
the live one and copy back only what is missing.

Commands below run on `db` as root (`vagrant ssh db`, then `sudo -i`).
`/etc/restic/backup.env` holds the repository credentials.

## 1. Stop the damage from growing (optional)

If something is still deleting rows, take the app out first. Both app
servers down means a full outage, so only do this if it is still happening:

```bash
# on your machine
ansible app -i inventories/vagrant -b -m systemd_service -a 'name=transport-api state=stopped'
```

## 2. Pick the snapshot

```bash
set -a; . /etc/restic/backup.env; set +a
restic snapshots --tag transport_firm
```

Snapshots are hourly and kept for 24 hours, then one a day for 7 days.
Choose the last one taken **before** the table was damaged and note its ID
(or use `latest`).

## 3. Restore it into a scratch database

```bash
runuser -u postgres -- createdb transport_firm_restore
restic dump <snapshot-id> /transport_firm.dump |
  runuser -u postgres -- pg_restore --no-owner --no-acl --exit-on-error -d transport_firm_restore
```

Always restore the whole dump here, even if only one table is damaged; the
next step explains why. `pg_restore` reads the dump as a stream, so nothing
is written to disk apart from the scratch database itself.

## 4. Put the data back

**The table is gone** (`DROP TABLE`): copy it from the scratch database with
`pg_dump -t`, which brings the table together with its sequence, primary
key, indexes and foreign keys.

```bash
runuser -u postgres -- pg_dump --no-owner --no-acl -t orders transport_firm_restore |
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 transport_firm
runuser -u postgres -- psql transport_firm \
  -c 'ALTER TABLE orders OWNER TO transport' -c 'ALTER SEQUENCE orders_id_seq OWNER TO transport'
```

Do **not** use `pg_restore -t orders` from the backup file for this. Tried
in the lab: it restores the columns and the rows, but no primary key, no
`id` default (the sequence is a separate object), no indexes and no
foreign keys. The API keeps working, and the next insert fails.

Foreign keys *from other tables* that pointed to the dropped table were
removed by `DROP TABLE ... CASCADE`; `\d+ <other table>` in the scratch
database shows them, recreate them with `ALTER TABLE ... ADD CONSTRAINT`.

**Rows were deleted** (the table still exists): load the old rows into a
staging table in the live database, then insert only the ones that are
missing. Rows that still exist (and may have changed since the snapshot)
are left alone.

```bash
runuser -u postgres -- psql transport_firm_restore -c "\copy orders TO '/tmp/orders.csv' CSV"
runuser -u postgres -- psql transport_firm <<'SQL'
CREATE TABLE orders_restored (LIKE orders);
\copy orders_restored FROM '/tmp/orders.csv' CSV
INSERT INTO orders
SELECT * FROM orders_restored r
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.id = r.id);
DROP TABLE orders_restored;
SQL
```

Insert parent rows before child rows (clients → orders → trip_details →
trip_logs), or the foreign keys reject them. If the sequence of an `id`
column is now behind the highest id, move it:

```bash
runuser -u postgres -- psql transport_firm \
  -c "SELECT setval(pg_get_serial_sequence('orders', 'id'), (SELECT max(id) FROM orders))"
```

## 5. Check and clean up

```bash
curl -s http://10.10.10.10/orders | head -c 300      # from your machine
runuser -u postgres -- dropdb transport_firm_restore
rm -f /tmp/*.csv
```

Start the app again if you stopped it in step 1 (`state=started`), then
trigger a fresh backup so the next snapshot contains the repaired data:

```bash
systemctl start backup.service
```

## Why this works

`make restore-test` does steps 3 and 5 on every CI run and compares the row
count of every table with the live database, so a backup that cannot be
restored is caught long before it is needed.
