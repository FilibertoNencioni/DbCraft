#!/usr/bin/env bash
# Starts the database servers of the design tool integration tests and waits
# until every one is healthy. Extra arguments go to `docker compose`
# (e.g. --profile db2). See docs/design-testing.md.
set -euo pipefail
cd "$(dirname "$0")"

docker compose -f compose.yml "$@" up -d --wait --wait-timeout 900

# SQL Server has no "create database" environment variable.
docker compose -f compose.yml exec -T mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P DbCraft_Test1 \
  -Q "IF DB_ID('dbcraft') IS NULL CREATE DATABASE dbcraft" >/dev/null

docker compose -f compose.yml "$@" ps
echo
echo "Pronto. Esegui ad esempio:"
echo "  flutter test integration_test/design_db_test.dart -d macos \\"
echo "    --dart-define=DESIGN_TARGETS=sqlite,pg,mssql,mysql,mariadb,oracle,firebird"
