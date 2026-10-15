import 'package:flutter/material.dart';

import '../../model/db_objects.dart';
import '../../state/db_connection.dart';
import '../../state/editor_tabs.dart';
import '../../state/result_set_model.dart';
import 'query_builder_view.dart';
import 'query_model.dart';

/// Bottom pane of the builder.
enum QueryBuilderPane { columns, results }

/// Visual Query Builder editor (DBeaver PRO "Visual Query Builder").
///
/// All the builder state lives here so that boxes, joins, the grid and the
/// last result survive switching editor tabs.
class QueryBuilderTab extends FeatureTab {
  QueryBuilderTab(this.dc, {this.catalog, this.schema, this.initialTable});

  final DbConnection dc;

  /// Catalog / schema shown in the table list.
  String? catalog;
  String? schema;

  /// Table added when the builder opens (navigator "Query builder" on a table).
  final DbTable? initialTable;
  bool initialTableAdded = false;

  final QueryModel model = QueryModel();

  /// Canvas pan / zoom.
  Matrix4? viewTransform;
  String tableSearch = '';
  QueryBuilderPane pane = QueryBuilderPane.columns;

  /// Last execution.
  ResultSetModel? result;
  String? error;
  String? message;
  bool running = false;

  @override
  DbConnection get connection => dc;

  @override
  String get title => 'Query builder';

  @override
  String get tooltip => '${dc.config.name}: query builder visuale';

  @override
  IconData get icon => Icons.join_inner_rounded;

  @override
  Widget buildView(BuildContext context) => QueryBuilderView(key: ValueKey(id), tab: this);

  @override
  Future<bool> canClose(BuildContext context) async => true;

  @override
  void dispose() {
    result?.close();
    super.dispose();
  }
}
