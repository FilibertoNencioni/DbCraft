// Editing session of a view: the definition in the database (null for a
// new view), the wanted one and the DDL that applies the difference.

import 'package:flutter/foundation.dart';

import '../../services/sql_dialect.dart';
import 'ddl/object_ddl.dart';
import 'model/object_defs.dart';

class ViewDesign extends ChangeNotifier {
  ViewDesign._(this.dialect, this.original, this._working);

  factory ViewDesign.existing(SqlDialect dialect, ViewDef view) =>
      ViewDesign._(dialect, view, view.copyWith(originalName: view.name));

  /// A new view in [catalog].[schema]; [definition] defaults to a template.
  factory ViewDesign.create(SqlDialect dialect, {String? catalog, String? schema, String? definition}) => ViewDesign._(
    dialect,
    null,
    ViewDef(
      catalog: catalog,
      schema: schema,
      name: '',
      definition: definition?.trim().isNotEmpty == true ? definition!.trim() : 'SELECT\n  *\nFROM tabella\nWHERE 1 = 1',
    ),
  );

  final SqlDialect dialect;
  ViewDef? original;
  ViewDef _working;

  ViewDef get working => _working;
  bool get isNew => original == null;

  void update(ViewDef v) {
    if (identical(v, _working)) return;
    _working = v;
    notifyListeners();
  }

  List<String> get statements {
    final ddl = ObjectDdl(dialect);
    final o = original;
    if (o == null) return ddl.createView(_working.copyWith(originalName: null));
    final out = ddl.alterView(o, _working);
    if (dialect.family == DbFamily.postgres && out.any((s) => s.startsWith('CREATE OR REPLACE'))) {
      return [
        '-- PostgreSQL: OR REPLACE non toglie, rinomina né cambia il tipo delle colonne; '
            'in quel caso elimina la vista e creala di nuovo',
        ...out,
      ];
    }
    return out;
  }

  bool get isDirty => isNew || statements.isNotEmpty;

  List<String> get errors => [
    if (_working.name.trim().isEmpty) 'Inserisci il nome della vista',
    if (_working.definition.trim().isEmpty) 'Scrivi la query della vista',
  ];

  void discard() {
    final o = original;
    if (o == null) return;
    _working = o.copyWith(originalName: o.name);
    notifyListeners();
  }

  /// [view], read again after the script ran, is the new starting point.
  void saved(ViewDef view) {
    original = view;
    _working = view.copyWith(originalName: view.name);
    notifyListeners();
  }
}
