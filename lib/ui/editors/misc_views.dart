import 'package:flutter/material.dart';

import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../../state/editor_tabs.dart';
import '../actions.dart';
import '../widgets/common.dart';
import 'er_diagram_view.dart';

/// Procedure / function editor: properties and parameters.
class ProcedureView extends StatefulWidget {
  const ProcedureView({super.key, required this.tab});
  final ProcedureEditorTab tab;

  @override
  State<ProcedureView> createState() => _ProcedureViewState();
}

class _ProcedureViewState extends State<ProcedureView> {
  Future<List<DbProcedureParam>>? _params;

  @override
  void initState() {
    super.initState();
    _params = widget.tab.connection.metadata?.procedureParams(widget.tab.procedure);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.tab.procedure;
    final c = widget.tab.connection;
    final theme = Theme.of(context);
    return FutureBuilder<List<DbProcedureParam>>(
      future: _params,
      builder: (context, snap) {
        final params = snap.data ?? const <DbProcedureParam>[];
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Icon(
                  p.type == 2 ? Icons.functions : Icons.settings_applications_outlined,
                  color: const Color(0xFF8E24AA),
                  size: 28,
                ),
                const SizedBox(width: 10),
                Text(p.cleanName, style: theme.textTheme.titleLarge),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: () =>
                      AppScope.read(context).sqlEditorWith(c, c.dialect.procedureCall(p, params)),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Genera chiamata in editor SQL'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            PropertyTable(
              entries: [
                ('Nome', p.cleanName),
                ('Tipo', p.kindLabel),
                ('Catalogo', p.catalog ?? ''),
                ('Schema', p.schema ?? ''),
                ('Commento', p.remarks ?? ''),
              ],
            ),
            const SizedBox(height: 20),
            Text('Parametri', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (snap.connectionState != ConnectionState.done)
              const LinearProgressIndicator()
            else
              SizedBox(
                height: 400,
                child: SimpleGrid(
                  headers: const ['#', 'Nome', 'Modo', 'Tipo', 'Dimensione'],
                  rows: [
                    for (final x in params)
                      ['${x.position}', x.name, x.modeLabel, x.typeName, '${x.size ?? ''}'],
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Nota: il corpo della procedura non è esposto dalle API ODBC standard; '
              'usa le viste di sistema del DBMS (es. sys.sql_modules, pg_proc, information_schema.routines).',
              style: TextStyle(color: theme.hintColor, fontSize: 12),
            ),
          ],
        );
      },
    );
  }
}

/// ER diagram editor tab wrapper.
class ErDiagramTabView extends StatelessWidget {
  const ErDiagramTabView({super.key, required this.tab});
  final ErDiagramTab tab;

  @override
  Widget build(BuildContext context) {
    if (!tab.connection.isConnected) {
      return Center(
        child: FilledButton(
          onPressed: () => ensureConnected(context, tab.connection),
          child: const Text('Connetti'),
        ),
      );
    }
    return ErDiagramView(
      connection: tab.connection,
      catalog: tab.catalog,
      schema: tab.schema,
      focus: tab.focus,
      positions: tab.positions,
    );
  }
}

/// Connection / driver information (SQLGetInfo) and supported data types.
class ConnectionInfoView extends StatefulWidget {
  const ConnectionInfoView({super.key, required this.tab});
  final ConnectionInfoTab tab;

  @override
  State<ConnectionInfoView> createState() => _ConnectionInfoViewState();
}

class _ConnectionInfoViewState extends State<ConnectionInfoView> {
  Future<ResultPage>? _types;

  @override
  Widget build(BuildContext context) {
    final c = widget.tab.connection;
    final i = c.info;
    final theme = Theme.of(context);
    String s(String k) => i[k]?.toString() ?? '';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Icon(c.config.template.icon, color: c.config.template.color, size: 28),
            const SizedBox(width: 10),
            Text(c.config.name, style: theme.textTheme.titleLarge),
            const SizedBox(width: 12),
            Chip(
              avatar: CircleAvatar(backgroundColor: c.config.type.color, radius: 5),
              label: Text(c.config.type.label),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Server', style: theme.textTheme.titleMedium),
        PropertyTable(
          entries: [
            ('DBMS', '${s('dbmsName')} ${s('dbmsVersion')}'),
            ('Server', s('serverName')),
            ('Database corrente', s('databaseName')),
            ('Utente', s('userName')),
            ('Connesso dal', c.connectedAt?.toString() ?? ''),
            ('Stringa di connessione', c.config.maskedConnectionString),
          ],
        ),
        const SizedBox(height: 16),
        Text('Driver ODBC', style: theme.textTheme.titleMedium),
        PropertyTable(
          entries: [
            ('Driver', '${s('driverName')} ${s('driverVersion')}'),
            ('Versione ODBC driver', s('driverOdbcVersion')),
            ('Versione Driver Manager', s('odbcVersion')),
            ('DSN', s('dataSourceName')),
          ],
        ),
        const SizedBox(height: 16),
        Text('Capacità', style: theme.textTheme.titleMedium),
        PropertyTable(
          entries: [
            ('Termine catalogo', s('catalogTerm')),
            ('Termine schema', s('schemaTerm')),
            ('Termine procedura', s('procedureTerm')),
            ('Carattere di quoting', s('identifierQuote')),
            ('Separatore catalogo', s('catalogSeparator')),
            ('Cataloghi supportati', c.metadata?.supportsCatalogs ?? false ? 'sì' : 'no'),
            ('Schemi supportati', c.metadata?.supportsSchemas ?? false ? 'sì' : 'no'),
            ('Procedure supportate', c.metadata?.supportsProcedures ?? false ? 'sì' : 'no'),
            (
              'Transazioni',
              switch (i['txnCapable']) {
                0 => 'non supportate',
                1 => 'solo DML',
                2 => 'DML e DDL',
                3 => 'DDL causa commit',
                4 => 'DDL ignorato',
                _ => '',
              },
            ),
            ('Lunghezza max identificatore', s('maxIdentifierLength')),
            ('Parole chiave aggiuntive', s('keywords')),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('Tipi di dato (SQLGetTypeInfo)', style: theme.textTheme.titleMedium),
            const SizedBox(width: 12),
            if (_types == null)
              TextButton(
                onPressed: () => setState(() {
                  _types = c.metadata?.typeInfo();
                }),
                child: const Text('Carica'),
              ),
          ],
        ),
        if (_types != null)
          FutureBuilder<ResultPage>(
            future: _types,
            builder: (context, snap) {
              if (snap.hasError) return Text('${snap.error}');
              if (!snap.hasData) return const LinearProgressIndicator();
              final r = snap.data!;
              return SizedBox(
                height: 420,
                child: SimpleGrid(
                  headers: r.columns.take(6).map((e) => e.name).toList(),
                  rows: [for (final row in r.rows) row.take(6).map((v) => v?.toString() ?? '').toList()],
                ),
              );
            },
          ),
      ],
    );
  }
}
