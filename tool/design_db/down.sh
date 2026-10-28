#!/usr/bin/env bash
# Stops the test database servers and deletes their data.
set -euo pipefail
cd "$(dirname "$0")"
docker compose -f compose.yml --profile db2 down -v
