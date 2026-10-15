// Database object model built from the ODBC catalog functions.

class DbTable {
  DbTable({
    required this.catalog,
    required this.schema,
    required this.name,
    required this.type,
    this.remarks,
  });

  final String? catalog;
  final String? schema;
  final String name;

  /// TABLE, VIEW, SYSTEM TABLE, SYNONYM, …
  final String type;
  final String? remarks;

  bool get isView => type.toUpperCase().contains('VIEW');

  String get key => '${catalog ?? ''}\u0001${schema ?? ''}\u0001$name';

  String get displayPath => [catalog, schema, name].where((e) => e != null && e.isNotEmpty).join('.');

  @override
  bool operator ==(Object other) => other is DbTable && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

class DbColumn {
  DbColumn({
    required this.name,
    required this.dataType,
    required this.typeName,
    required this.size,
    required this.decimals,
    required this.nullable,
    required this.position,
    this.defaultValue,
    this.remarks,
    this.autoIncrement = false,
  });

  final String name;
  final int dataType;
  final String typeName;
  final int? size;
  final int? decimals;
  final bool nullable;
  final int position;
  final String? defaultValue;
  final String? remarks;
  final bool autoIncrement;

  /// Type declaration usable in DDL (e.g. VARCHAR(50), DECIMAL(10,2)).
  String get fullType {
    final t = typeName.toUpperCase();
    if (t.contains('(')) return typeName;
    const sized = {
      'CHAR',
      'VARCHAR',
      'NCHAR',
      'NVARCHAR',
      'VARCHAR2',
      'NVARCHAR2',
      'BINARY',
      'VARBINARY',
      'CHARACTER',
      'CHARACTER VARYING',
      'BPCHAR',
    };
    const scaled = {'DECIMAL', 'NUMERIC', 'NUMBER'};
    if (sized.contains(t) && size != null && size! > 0) {
      if (size! >= 1073741823 || size! == 2147483647) return '$typeName(MAX)';
      return '$typeName($size)';
    }
    if (scaled.contains(t) && size != null && size! > 0) {
      return decimals != null && decimals! > 0 ? '$typeName($size,$decimals)' : '$typeName($size)';
    }
    return typeName;
  }
}

class DbPrimaryKey {
  DbPrimaryKey(this.name, this.columns);
  final String? name;
  final List<String> columns;
}

class DbForeignKey {
  DbForeignKey({
    required this.name,
    required this.pkCatalog,
    required this.pkSchema,
    required this.pkTable,
    required this.fkCatalog,
    required this.fkSchema,
    required this.fkTable,
    required this.columns,
    required this.refColumns,
    this.updateRule,
    this.deleteRule,
  });

  final String? name;
  final String? pkCatalog;
  final String? pkSchema;
  final String pkTable;
  final String? fkCatalog;
  final String? fkSchema;
  final String fkTable;
  final List<String> columns;
  final List<String> refColumns;
  final int? updateRule;
  final int? deleteRule;

  static String ruleName(int? r) => switch (r) {
    0 => 'CASCADE',
    1 => 'RESTRICT',
    2 => 'SET NULL',
    3 => 'NO ACTION',
    4 => 'SET DEFAULT',
    _ => '',
  };
}

class DbIndex {
  DbIndex({required this.name, required this.unique, required this.columns, this.type});

  final String name;
  final bool unique;
  final List<String> columns;
  final int? type;

  String get typeName => switch (type) {
    1 => 'CLUSTERED',
    2 => 'HASHED',
    3 => 'OTHER',
    _ => '',
  };
}

class DbProcedure {
  DbProcedure({
    required this.catalog,
    required this.schema,
    required this.name,
    required this.type,
    this.remarks,
  });

  final String? catalog;
  final String? schema;
  final String name;

  /// 1 = procedure, 2 = function, 0 = unknown.
  final int type;
  final String? remarks;

  /// SQL Server appends ";1" to procedure names.
  String get cleanName {
    final i = name.lastIndexOf(';');
    return i > 0 ? name.substring(0, i) : name;
  }

  String get key => '${catalog ?? ''}\u0001${schema ?? ''}\u0001$name';

  String get kindLabel => type == 2 ? 'Funzione' : 'Procedura';
}

class DbProcedureParam {
  DbProcedureParam({
    required this.name,
    required this.columnType,
    required this.typeName,
    required this.size,
    required this.position,
  });

  final String name;

  /// 1 IN, 2 INOUT, 3 RESULT COLUMN, 4 OUT, 5 RETURN VALUE.
  final int columnType;
  final String typeName;
  final int? size;
  final int position;

  String get modeLabel => switch (columnType) {
    1 => 'IN',
    2 => 'INOUT',
    3 => 'RESULT',
    4 => 'OUT',
    5 => 'RETURN',
    _ => '?',
  };
}

/// Everything known about a table (lazily filled by the metadata service).
class TableDetails {
  TableDetails({
    required this.table,
    required this.columns,
    required this.primaryKey,
    required this.foreignKeys,
    required this.referencedBy,
    required this.indexes,
  });

  final DbTable table;
  final List<DbColumn> columns;
  final DbPrimaryKey? primaryKey;
  final List<DbForeignKey> foreignKeys;
  final List<DbForeignKey> referencedBy;
  final List<DbIndex> indexes;
}
