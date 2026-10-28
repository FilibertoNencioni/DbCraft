#!/usr/bin/env bash
# Test matrix dataset for Cassandra: keyspace negozio, collections, UDT, clustering, 100k rows.
set -euo pipefail
C="docker exec -i dbcraft-design-cassandra-1 cqlsh -u cassandra -p cassandra"
$C <<'CQL'
DROP KEYSPACE IF EXISTS negozio;
CREATE KEYSPACE negozio WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1};
USE negozio;
CREATE TYPE indirizzo (via text, cap text, citta text);
CREATE TABLE clienti (id int PRIMARY KEY, nome text, email text, tag set<text>, telefoni list<text>, attributi map<text, text>, residenza frozen<indirizzo>);
INSERT INTO clienti (id, nome, email, tag, telefoni, attributi, residenza) VALUES (1, 'Mario Rossi', 'mario@esempio.it', {'vip', 'nord'}, ['051 1', '333 2'], {'lingua': 'it'}, {via: 'Via Roma 1', cap: '47121', citta: 'Forlì'});
INSERT INTO clienti (id, nome) VALUES (2, 'Anna Bianchi');
INSERT INTO clienti (id, nome, attributi) VALUES (3, '東京 太郎', {'note': 'emoji 😀'});
CREATE TABLE letture (sensore text, giorno date, ora timestamp, valore double, PRIMARY KEY ((sensore, giorno), ora)) WITH CLUSTERING ORDER BY (ora DESC);
INSERT INTO letture (sensore, giorno, ora, valore) VALUES ('s1', '2024-01-01', '2024-01-01 10:00:00+0000', 21.5);
INSERT INTO letture (sensore, giorno, ora, valore) VALUES ('s1', '2024-01-01', '2024-01-01 11:00:00+0000', 22.0);
CREATE TABLE tipi (id int PRIMARY KEY, a ascii, b bigint, bl blob, bo boolean, d date, de decimal, do double, du duration, f float, i inet, sm smallint, ti tinyint, t time, ts timestamp, tu timeuuid, u uuid, vi varint, tx text, tp tuple<int, text>);
INSERT INTO tipi (id, a, b, bl, bo, d, de, do, du, f, i, sm, ti, t, ts, tu, u, vi, tx, tp) VALUES (1, 'ascii', 9223372036854775807, 0x00ff10ab, true, '2024-02-29', 1234567890.0123456789, 3.141592653589793, 1y2mo3d4h5m6s, 1.5, '192.168.1.1', 32767, 127, '23:59:59.123', '2024-02-29 23:59:59.123+0000', now(), 0b5f6c1e-7d4a-4c3e-9b1a-2f6e8d9c0a11, 123456789012345678901234567890, 'accenti àèé — 漢字 — 😀', (1, 'uno'));
CREATE TABLE grande (id int PRIMARY KEY, gruppo int, testo text);
CQL
docker exec dbcraft-design-cassandra-1 sh -c 'seq 1 100000 | awk "{print \$1\",\"\$1%100\",riga \"\$1}" > /tmp/grande.csv && cqlsh -u cassandra -p cassandra -e "COPY negozio.grande (id, gruppo, testo) FROM '"'"'/tmp/grande.csv'"'"'" >/dev/null'
$C -e "SELECT COUNT(*) FROM negozio.grande" | sed -n 4p
