import 'package:flutter/material.dart';

import '../../features/design/catalog/code.dart';
import '../../features/design/catalog/design_catalog.dart';
import '../../features/design/ui/object_actions.dart';
import '../../model/db_objects.dart';
import '../../odbc/odbc_types.dart';
import '../../state/app_state.dart';
import '../../state/editor_tabs.dart';
import '../actions.dart';
import '../widgets/common.dart';
import 'er_diagram_view.dart';
import 'sql_code_editor.dart';

/// Procedure / function editor: properties and parameters.
class ProcedureView extends StatefulWidget {
  const ProcedureView({super.key, required this.tab});
  final ProcedureEditorTab tab;

  @override
  State<ProcedureView> createState() => _ProcedureViewState();
}

class _ProcedureViewState extends State<ProcedureView> {
  Future<List<DbProcedureParam>>? _params;
  Future<RoutineSource?>? _source;

  @override
  void initState() {
    super.initState();
    _params = widget.tab.connection.metadata?.procedureParams(widget.tab.procedure);
    final cat = DesignCatalog.of(widget.tab.connection);
    if (cat != null && widget.tab.connection.dialect.isSql) {
      _source = cat.routineSource(widget.tab.procedure).then<RoutineSource?>((s) => s, onError: (_) => null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.tab.procedure;
    final c = widget.tab.connection;
    final colors = DbColors.of(context);
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
                  p.type == 2 ? AppIcons.function : AppIcons.procedure,
                  color: colors.accent,
                  size: 28,
                ),
                const SizedBox(width: 10),
                Text(p.cleanName, style: uiText(TypeSize.sheetTitle, weight: FontWeight.w700, color: colors.text)),
                const Spacer(),
                PushButton(
                  label: 'Genera chiamata in editor SQL',
                  icon: AppIcons.run,
                  onPressed: () => AppScope.read(context).sqlEditorWith(c, c.dialect.procedureCall(p, params)),
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
            const SectionLabel('Parametri', padding: EdgeInsets.only(bottom: Gap.sm)),
            if (snap.connectionState != ConnectionState.done)
              const ProgressBar()
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
            const SizedBox(height: 20),
            FutureBuilder<RoutineSource?>(
              future: _source,
              builder: (context, src) {
                final source = src.data;
                final simple = AppScope.read(context).settings.simpleMode;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SectionLabel(
                      'Sorgente',
                      padding: const EdgeInsets.only(bottom: Gap.sm),
                      trailing: source == null || simple
                          ? null
                          : ToolButton(
                              icon: AppIcons.edit,
                              label: 'Modifica sorgente',
                              tooltip: 'Apri il sorgente in un editor',
                              onPressed: () => editRoutine(context, c, p),
                            ),
                    ),
                    if (src.connectionState != ConnectionState.done)
                      const ProgressBar()
                    else if (source == null)
                      Text(
                        'Il catalogo di ${c.dialect.dbmsName} non espone il sorgente di questa ${p.type == 2 ? 'funzione' : 'procedura'}.',
                        style: uiText(TypeSize.small, color: colors.textSecondary),
                      )
                    else
                      SizedBox(height: 360, child: SqlCodeView(text: source.source)),
                  ],
                );
              },
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
      return EmptyState(
        icon: AppIcons.erDiagram,
        title: 'Connessione non attiva',
        message: 'Connettiti a ${tab.connection.config.name} per vedere il diagramma.',
        action: PushButton.primary(label: 'Connetti', onPressed: () => ensureConnected(context, tab.connection)),
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
    final colors = DbColors.of(context);
    String s(String k) => i[k]?.toString() ?? '';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Icon(c.config.template.icon, color: c.config.template.color, size: 28),
            const SizedBox(width: 10),
            Text(c.config.name, style: uiText(TypeSize.sheetTitle, weight: FontWeight.w700, color: colors.text)),
            const SizedBox(width: 12),
            Tag(c.config.type.label, color: c.config.type.colorOf(colors)),
          ],
        ),
        const SizedBox(height: 16),
        PropertyTable(
          title: 'Server',
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
        PropertyTable(
          title: 'Driver ODBC',
          entries: [
            ('Driver', '${s('driverName')} ${s('driverVersion')}'),
            ('Versione ODBC driver', s('driverOdbcVersion')),
            ('Versione Driver Manager', s('odbcVersion')),
            ('DSN', s('dataSourceName')),
          ],
        ),
        const SizedBox(height: 16),
        PropertyTable(
          title: 'Capacità',
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
        SectionLabel(
          'Tipi di dato (SQLGetTypeInfo)',
          padding: const EdgeInsets.only(bottom: Gap.sm),
          trailing: _types != null
              ? null
              : LinkButton(
                  label: 'Carica',
                  small: true,
                  onPressed: () => setState(() {
                    _types = c.metadata?.typeInfo();
                  }),
                ),
        ),
        if (_types != null)
          FutureBuilder<ResultPage>(
            future: _types,
            builder: (context, snap) {
              if (snap.hasError) {
                return Notice(
                  kind: NoticeKind.danger,
                  title: 'Impossibile leggere i tipi',
                  message: describeError(snap.error!),
                );
              }
              if (!snap.hasData) return const ProgressBar();
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
