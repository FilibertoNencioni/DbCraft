#!/usr/bin/env bash
# Loads the test matrix dataset into one target: pg | mssql | mysql | mariadb.
set -euo pipefail
cd "$(dirname "$0")"
P=DbCraft_Test1
case "$1" in
  pg)      docker exec -i dbcraft-matrix-pg-1 psql -q -v ON_ERROR_STOP=1 -U dbcraft -d dbcraft < pg.sql >/dev/null ;;
  mssql)   docker exec -i dbcraft-design-mssql-1 /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P $P -I -b -f 65001 < mssql.sql >/dev/null ;;
  mysql)   docker exec -i dbcraft-design-mysql-1 mysql -uroot -p$P --default-character-set=utf8mb4 < mysql.sql 2>/dev/null ;;
  mariadb) sed "s/cte_max_recursion_depth/max_recursive_iterations/" mysql.sql | docker exec -i dbcraft-design-mariadb-1 mariadb -uroot -p$P --default-character-set=utf8mb4 ;;
  *) echo "target sconosciuto: $1" >&2; exit 2 ;;
esac
