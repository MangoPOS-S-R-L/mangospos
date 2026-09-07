// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'hub_state_db.dart';

// ignore_for_file: type=lint
class $HubOpsTable extends HubOps with TableInfo<$HubOpsTable, HubOpRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HubOpsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _businessIdMeta = const VerificationMeta(
    'businessId',
  );
  @override
  late final GeneratedColumn<String> businessId = GeneratedColumn<String>(
    'business_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _opIdMeta = const VerificationMeta('opId');
  @override
  late final GeneratedColumn<String> opId = GeneratedColumn<String>(
    'op_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _orderIdMeta = const VerificationMeta(
    'orderId',
  );
  @override
  late final GeneratedColumn<String> orderId = GeneratedColumn<String>(
    'order_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _payloadJsonMeta = const VerificationMeta(
    'payloadJson',
  );
  @override
  late final GeneratedColumn<String> payloadJson = GeneratedColumn<String>(
    'payload_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _receivedAtMeta = const VerificationMeta(
    'receivedAt',
  );
  @override
  late final GeneratedColumn<DateTime> receivedAt = GeneratedColumn<DateTime>(
    'received_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    businessId,
    seq,
    opId,
    orderId,
    payloadJson,
    receivedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'hub_ops';
  @override
  VerificationContext validateIntegrity(
    Insertable<HubOpRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('business_id')) {
      context.handle(
        _businessIdMeta,
        businessId.isAcceptableOrUnknown(data['business_id']!, _businessIdMeta),
      );
    } else if (isInserting) {
      context.missing(_businessIdMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    } else if (isInserting) {
      context.missing(_seqMeta);
    }
    if (data.containsKey('op_id')) {
      context.handle(
        _opIdMeta,
        opId.isAcceptableOrUnknown(data['op_id']!, _opIdMeta),
      );
    }
    if (data.containsKey('order_id')) {
      context.handle(
        _orderIdMeta,
        orderId.isAcceptableOrUnknown(data['order_id']!, _orderIdMeta),
      );
    }
    if (data.containsKey('payload_json')) {
      context.handle(
        _payloadJsonMeta,
        payloadJson.isAcceptableOrUnknown(
          data['payload_json']!,
          _payloadJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_payloadJsonMeta);
    }
    if (data.containsKey('received_at')) {
      context.handle(
        _receivedAtMeta,
        receivedAt.isAcceptableOrUnknown(data['received_at']!, _receivedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_receivedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {businessId, seq};
  @override
  HubOpRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HubOpRow(
      businessId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}business_id'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      )!,
      opId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op_id'],
      ),
      orderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}order_id'],
      ),
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      receivedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}received_at'],
      )!,
    );
  }

  @override
  $HubOpsTable createAlias(String alias) {
    return $HubOpsTable(attachedDatabase, alias);
  }
}

class HubOpRow extends DataClass implements Insertable<HubOpRow> {
  final String businessId;
  final int seq;

  /// Id de la operación. Nullable a propósito: hay ops sin `op_id` y esas NO se
  /// deduplican (mismo comportamiento que antes). SQLite permite varios NULL en
  /// un índice único, así que el índice de abajo las deja pasar.
  final String? opId;

  /// Se extrae del payload al insertar para poder podar por orden
  /// (`retainOrders`) sin deserializar el log entero.
  final String? orderId;

  /// La op completa como JSON, ya enriquecida con `seq` y `hub_received_at`.
  final String payloadJson;
  final DateTime receivedAt;
  const HubOpRow({
    required this.businessId,
    required this.seq,
    this.opId,
    this.orderId,
    required this.payloadJson,
    required this.receivedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['business_id'] = Variable<String>(businessId);
    map['seq'] = Variable<int>(seq);
    if (!nullToAbsent || opId != null) {
      map['op_id'] = Variable<String>(opId);
    }
    if (!nullToAbsent || orderId != null) {
      map['order_id'] = Variable<String>(orderId);
    }
    map['payload_json'] = Variable<String>(payloadJson);
    map['received_at'] = Variable<DateTime>(receivedAt);
    return map;
  }

  HubOpsCompanion toCompanion(bool nullToAbsent) {
    return HubOpsCompanion(
      businessId: Value(businessId),
      seq: Value(seq),
      opId: opId == null && nullToAbsent ? const Value.absent() : Value(opId),
      orderId: orderId == null && nullToAbsent
          ? const Value.absent()
          : Value(orderId),
      payloadJson: Value(payloadJson),
      receivedAt: Value(receivedAt),
    );
  }

  factory HubOpRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HubOpRow(
      businessId: serializer.fromJson<String>(json['businessId']),
      seq: serializer.fromJson<int>(json['seq']),
      opId: serializer.fromJson<String?>(json['opId']),
      orderId: serializer.fromJson<String?>(json['orderId']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      receivedAt: serializer.fromJson<DateTime>(json['receivedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'businessId': serializer.toJson<String>(businessId),
      'seq': serializer.toJson<int>(seq),
      'opId': serializer.toJson<String?>(opId),
      'orderId': serializer.toJson<String?>(orderId),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'receivedAt': serializer.toJson<DateTime>(receivedAt),
    };
  }

  HubOpRow copyWith({
    String? businessId,
    int? seq,
    Value<String?> opId = const Value.absent(),
    Value<String?> orderId = const Value.absent(),
    String? payloadJson,
    DateTime? receivedAt,
  }) => HubOpRow(
    businessId: businessId ?? this.businessId,
    seq: seq ?? this.seq,
    opId: opId.present ? opId.value : this.opId,
    orderId: orderId.present ? orderId.value : this.orderId,
    payloadJson: payloadJson ?? this.payloadJson,
    receivedAt: receivedAt ?? this.receivedAt,
  );
  HubOpRow copyWithCompanion(HubOpsCompanion data) {
    return HubOpRow(
      businessId: data.businessId.present
          ? data.businessId.value
          : this.businessId,
      seq: data.seq.present ? data.seq.value : this.seq,
      opId: data.opId.present ? data.opId.value : this.opId,
      orderId: data.orderId.present ? data.orderId.value : this.orderId,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      receivedAt: data.receivedAt.present
          ? data.receivedAt.value
          : this.receivedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HubOpRow(')
          ..write('businessId: $businessId, ')
          ..write('seq: $seq, ')
          ..write('opId: $opId, ')
          ..write('orderId: $orderId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('receivedAt: $receivedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(businessId, seq, opId, orderId, payloadJson, receivedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HubOpRow &&
          other.businessId == this.businessId &&
          other.seq == this.seq &&
          other.opId == this.opId &&
          other.orderId == this.orderId &&
          other.payloadJson == this.payloadJson &&
          other.receivedAt == this.receivedAt);
}

class HubOpsCompanion extends UpdateCompanion<HubOpRow> {
  final Value<String> businessId;
  final Value<int> seq;
  final Value<String?> opId;
  final Value<String?> orderId;
  final Value<String> payloadJson;
  final Value<DateTime> receivedAt;
  final Value<int> rowid;
  const HubOpsCompanion({
    this.businessId = const Value.absent(),
    this.seq = const Value.absent(),
    this.opId = const Value.absent(),
    this.orderId = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.receivedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HubOpsCompanion.insert({
    required String businessId,
    required int seq,
    this.opId = const Value.absent(),
    this.orderId = const Value.absent(),
    required String payloadJson,
    required DateTime receivedAt,
    this.rowid = const Value.absent(),
  }) : businessId = Value(businessId),
       seq = Value(seq),
       payloadJson = Value(payloadJson),
       receivedAt = Value(receivedAt);
  static Insertable<HubOpRow> custom({
    Expression<String>? businessId,
    Expression<int>? seq,
    Expression<String>? opId,
    Expression<String>? orderId,
    Expression<String>? payloadJson,
    Expression<DateTime>? receivedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (businessId != null) 'business_id': businessId,
      if (seq != null) 'seq': seq,
      if (opId != null) 'op_id': opId,
      if (orderId != null) 'order_id': orderId,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (receivedAt != null) 'received_at': receivedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HubOpsCompanion copyWith({
    Value<String>? businessId,
    Value<int>? seq,
    Value<String?>? opId,
    Value<String?>? orderId,
    Value<String>? payloadJson,
    Value<DateTime>? receivedAt,
    Value<int>? rowid,
  }) {
    return HubOpsCompanion(
      businessId: businessId ?? this.businessId,
      seq: seq ?? this.seq,
      opId: opId ?? this.opId,
      orderId: orderId ?? this.orderId,
      payloadJson: payloadJson ?? this.payloadJson,
      receivedAt: receivedAt ?? this.receivedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (businessId.present) {
      map['business_id'] = Variable<String>(businessId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (opId.present) {
      map['op_id'] = Variable<String>(opId.value);
    }
    if (orderId.present) {
      map['order_id'] = Variable<String>(orderId.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (receivedAt.present) {
      map['received_at'] = Variable<DateTime>(receivedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HubOpsCompanion(')
          ..write('businessId: $businessId, ')
          ..write('seq: $seq, ')
          ..write('opId: $opId, ')
          ..write('orderId: $orderId, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('receivedAt: $receivedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HubMetaTable extends HubMeta with TableInfo<$HubMetaTable, HubMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HubMetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _businessIdMeta = const VerificationMeta(
    'businessId',
  );
  @override
  late final GeneratedColumn<String> businessId = GeneratedColumn<String>(
    'business_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastSeqMeta = const VerificationMeta(
    'lastSeq',
  );
  @override
  late final GeneratedColumn<int> lastSeq = GeneratedColumn<int>(
    'last_seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [businessId, lastSeq];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'hub_meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<HubMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('business_id')) {
      context.handle(
        _businessIdMeta,
        businessId.isAcceptableOrUnknown(data['business_id']!, _businessIdMeta),
      );
    } else if (isInserting) {
      context.missing(_businessIdMeta);
    }
    if (data.containsKey('last_seq')) {
      context.handle(
        _lastSeqMeta,
        lastSeq.isAcceptableOrUnknown(data['last_seq']!, _lastSeqMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {businessId};
  @override
  HubMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HubMetaRow(
      businessId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}business_id'],
      )!,
      lastSeq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_seq'],
      )!,
    );
  }

  @override
  $HubMetaTable createAlias(String alias) {
    return $HubMetaTable(attachedDatabase, alias);
  }
}

class HubMetaRow extends DataClass implements Insertable<HubMetaRow> {
  final String businessId;

  /// Último `seq` ENTREGADO, aunque su fila ya se haya podado.
  final int lastSeq;
  const HubMetaRow({required this.businessId, required this.lastSeq});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['business_id'] = Variable<String>(businessId);
    map['last_seq'] = Variable<int>(lastSeq);
    return map;
  }

  HubMetaCompanion toCompanion(bool nullToAbsent) {
    return HubMetaCompanion(
      businessId: Value(businessId),
      lastSeq: Value(lastSeq),
    );
  }

  factory HubMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HubMetaRow(
      businessId: serializer.fromJson<String>(json['businessId']),
      lastSeq: serializer.fromJson<int>(json['lastSeq']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'businessId': serializer.toJson<String>(businessId),
      'lastSeq': serializer.toJson<int>(lastSeq),
    };
  }

  HubMetaRow copyWith({String? businessId, int? lastSeq}) => HubMetaRow(
    businessId: businessId ?? this.businessId,
    lastSeq: lastSeq ?? this.lastSeq,
  );
  HubMetaRow copyWithCompanion(HubMetaCompanion data) {
    return HubMetaRow(
      businessId: data.businessId.present
          ? data.businessId.value
          : this.businessId,
      lastSeq: data.lastSeq.present ? data.lastSeq.value : this.lastSeq,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HubMetaRow(')
          ..write('businessId: $businessId, ')
          ..write('lastSeq: $lastSeq')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(businessId, lastSeq);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HubMetaRow &&
          other.businessId == this.businessId &&
          other.lastSeq == this.lastSeq);
}

class HubMetaCompanion extends UpdateCompanion<HubMetaRow> {
  final Value<String> businessId;
  final Value<int> lastSeq;
  final Value<int> rowid;
  const HubMetaCompanion({
    this.businessId = const Value.absent(),
    this.lastSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HubMetaCompanion.insert({
    required String businessId,
    this.lastSeq = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : businessId = Value(businessId);
  static Insertable<HubMetaRow> custom({
    Expression<String>? businessId,
    Expression<int>? lastSeq,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (businessId != null) 'business_id': businessId,
      if (lastSeq != null) 'last_seq': lastSeq,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HubMetaCompanion copyWith({
    Value<String>? businessId,
    Value<int>? lastSeq,
    Value<int>? rowid,
  }) {
    return HubMetaCompanion(
      businessId: businessId ?? this.businessId,
      lastSeq: lastSeq ?? this.lastSeq,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (businessId.present) {
      map['business_id'] = Variable<String>(businessId.value);
    }
    if (lastSeq.present) {
      map['last_seq'] = Variable<int>(lastSeq.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HubMetaCompanion(')
          ..write('businessId: $businessId, ')
          ..write('lastSeq: $lastSeq, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$HubStateDb extends GeneratedDatabase {
  _$HubStateDb(QueryExecutor e) : super(e);
  $HubStateDbManager get managers => $HubStateDbManager(this);
  late final $HubOpsTable hubOps = $HubOpsTable(this);
  late final $HubMetaTable hubMeta = $HubMetaTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [hubOps, hubMeta];
}

typedef $$HubOpsTableCreateCompanionBuilder =
    HubOpsCompanion Function({
      required String businessId,
      required int seq,
      Value<String?> opId,
      Value<String?> orderId,
      required String payloadJson,
      required DateTime receivedAt,
      Value<int> rowid,
    });
typedef $$HubOpsTableUpdateCompanionBuilder =
    HubOpsCompanion Function({
      Value<String> businessId,
      Value<int> seq,
      Value<String?> opId,
      Value<String?> orderId,
      Value<String> payloadJson,
      Value<DateTime> receivedAt,
      Value<int> rowid,
    });

class $$HubOpsTableFilterComposer extends Composer<_$HubStateDb, $HubOpsTable> {
  $$HubOpsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get orderId => $composableBuilder(
    column: $table.orderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HubOpsTableOrderingComposer
    extends Composer<_$HubStateDb, $HubOpsTable> {
  $$HubOpsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get orderId => $composableBuilder(
    column: $table.orderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HubOpsTableAnnotationComposer
    extends Composer<_$HubStateDb, $HubOpsTable> {
  $$HubOpsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get opId =>
      $composableBuilder(column: $table.opId, builder: (column) => column);

  GeneratedColumn<String> get orderId =>
      $composableBuilder(column: $table.orderId, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get receivedAt => $composableBuilder(
    column: $table.receivedAt,
    builder: (column) => column,
  );
}

class $$HubOpsTableTableManager
    extends
        RootTableManager<
          _$HubStateDb,
          $HubOpsTable,
          HubOpRow,
          $$HubOpsTableFilterComposer,
          $$HubOpsTableOrderingComposer,
          $$HubOpsTableAnnotationComposer,
          $$HubOpsTableCreateCompanionBuilder,
          $$HubOpsTableUpdateCompanionBuilder,
          (HubOpRow, BaseReferences<_$HubStateDb, $HubOpsTable, HubOpRow>),
          HubOpRow,
          PrefetchHooks Function()
        > {
  $$HubOpsTableTableManager(_$HubStateDb db, $HubOpsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HubOpsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HubOpsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HubOpsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> businessId = const Value.absent(),
                Value<int> seq = const Value.absent(),
                Value<String?> opId = const Value.absent(),
                Value<String?> orderId = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<DateTime> receivedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HubOpsCompanion(
                businessId: businessId,
                seq: seq,
                opId: opId,
                orderId: orderId,
                payloadJson: payloadJson,
                receivedAt: receivedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String businessId,
                required int seq,
                Value<String?> opId = const Value.absent(),
                Value<String?> orderId = const Value.absent(),
                required String payloadJson,
                required DateTime receivedAt,
                Value<int> rowid = const Value.absent(),
              }) => HubOpsCompanion.insert(
                businessId: businessId,
                seq: seq,
                opId: opId,
                orderId: orderId,
                payloadJson: payloadJson,
                receivedAt: receivedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HubOpsTableProcessedTableManager =
    ProcessedTableManager<
      _$HubStateDb,
      $HubOpsTable,
      HubOpRow,
      $$HubOpsTableFilterComposer,
      $$HubOpsTableOrderingComposer,
      $$HubOpsTableAnnotationComposer,
      $$HubOpsTableCreateCompanionBuilder,
      $$HubOpsTableUpdateCompanionBuilder,
      (HubOpRow, BaseReferences<_$HubStateDb, $HubOpsTable, HubOpRow>),
      HubOpRow,
      PrefetchHooks Function()
    >;
typedef $$HubMetaTableCreateCompanionBuilder =
    HubMetaCompanion Function({
      required String businessId,
      Value<int> lastSeq,
      Value<int> rowid,
    });
typedef $$HubMetaTableUpdateCompanionBuilder =
    HubMetaCompanion Function({
      Value<String> businessId,
      Value<int> lastSeq,
      Value<int> rowid,
    });

class $$HubMetaTableFilterComposer
    extends Composer<_$HubStateDb, $HubMetaTable> {
  $$HubMetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastSeq => $composableBuilder(
    column: $table.lastSeq,
    builder: (column) => ColumnFilters(column),
  );
}

class $$HubMetaTableOrderingComposer
    extends Composer<_$HubStateDb, $HubMetaTable> {
  $$HubMetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastSeq => $composableBuilder(
    column: $table.lastSeq,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$HubMetaTableAnnotationComposer
    extends Composer<_$HubStateDb, $HubMetaTable> {
  $$HubMetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastSeq =>
      $composableBuilder(column: $table.lastSeq, builder: (column) => column);
}

class $$HubMetaTableTableManager
    extends
        RootTableManager<
          _$HubStateDb,
          $HubMetaTable,
          HubMetaRow,
          $$HubMetaTableFilterComposer,
          $$HubMetaTableOrderingComposer,
          $$HubMetaTableAnnotationComposer,
          $$HubMetaTableCreateCompanionBuilder,
          $$HubMetaTableUpdateCompanionBuilder,
          (HubMetaRow, BaseReferences<_$HubStateDb, $HubMetaTable, HubMetaRow>),
          HubMetaRow,
          PrefetchHooks Function()
        > {
  $$HubMetaTableTableManager(_$HubStateDb db, $HubMetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HubMetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HubMetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HubMetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> businessId = const Value.absent(),
                Value<int> lastSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HubMetaCompanion(
                businessId: businessId,
                lastSeq: lastSeq,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String businessId,
                Value<int> lastSeq = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HubMetaCompanion.insert(
                businessId: businessId,
                lastSeq: lastSeq,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$HubMetaTableProcessedTableManager =
    ProcessedTableManager<
      _$HubStateDb,
      $HubMetaTable,
      HubMetaRow,
      $$HubMetaTableFilterComposer,
      $$HubMetaTableOrderingComposer,
      $$HubMetaTableAnnotationComposer,
      $$HubMetaTableCreateCompanionBuilder,
      $$HubMetaTableUpdateCompanionBuilder,
      (HubMetaRow, BaseReferences<_$HubStateDb, $HubMetaTable, HubMetaRow>),
      HubMetaRow,
      PrefetchHooks Function()
    >;

class $HubStateDbManager {
  final _$HubStateDb _db;
  $HubStateDbManager(this._db);
  $$HubOpsTableTableManager get hubOps =>
      $$HubOpsTableTableManager(_db, _db.hubOps);
  $$HubMetaTableTableManager get hubMeta =>
      $$HubMetaTableTableManager(_db, _db.hubMeta);
}
