# PostgreSQL 17.2 (same as tool/design_db) with the pldebugger extension for
# the PL/pgSQL debugger and pg_stat_statements for the performance dashboard.
FROM postgres:17.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-17-pldebugger \
 && rm -rf /var/lib/apt/lists/*
CMD ["postgres", "-c", "shared_preload_libraries=plugin_debugger,pg_stat_statements", "-c", "track_io_timing=on"]
