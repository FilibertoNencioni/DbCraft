#!/usr/bin/env bash
# Test matrix dataset for Redis: every type, TTLs, Unicode and 100k keys in db 1.
set -euo pipefail
R="docker exec -i dbcraft-design-redis-1 redis-cli -a DbCraft_Test1 --no-auth-warning"
$R FLUSHALL >/dev/null
$R <<'CMDS' >/dev/null
SET stringa "valore semplice"
SET unicode "accenti àèé — 漢字 — 😀"
SET contatore 41
INCR contatore
SET con_ttl "scade" EX 3600
HSET cliente:1 nome "Mario Rossi" email "mario@esempio.it" citta "Forlì"
HSET cliente:2 nome "Anna Bianchi" citta "Città di Castello"
RPUSH coda a b c d e
SADD insieme rosso verde blu
ZADD classifica 10 alice 20 bob 15 carla
XADD eventi * tipo login utente mario
XADD eventi * tipo logout utente mario
SET "chiave con spazi" "ok"
SET binario "\x00\xff\x10"
CMDS
docker exec dbcraft-design-redis-1 sh -c 'for i in $(seq 1 100000); do echo "SET k:$i v$i"; done | redis-cli -a DbCraft_Test1 --no-auth-warning -n 1 --pipe' >/dev/null
$R DBSIZE; $R -n 1 DBSIZE
