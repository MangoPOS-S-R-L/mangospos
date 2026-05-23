// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'offline_queue_db.dart';

// ignore_for_file: type=lint
class $QueueActionsTable extends QueueActions
    with TableInfo<$QueueActionsTable, QueueActionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $QueueActionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
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
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _queuedAtMeta = const VerificationMeta(
    'queuedAt',
  );
  @override
  late final GeneratedColumn<DateTime> queuedAt = GeneratedColumn<DateTime>(
    'queued_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _completedAtMeta = const VerificationMeta(
    'completedAt',
  );
  @override
  late final GeneratedColumn<DateTime> completedAt = GeneratedColumn<DateTime>(
    'completed_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _nextRetryAtMeta = const VerificationMeta(
    'nextRetryAt',
  );
  @override
  late final GeneratedColumn<DateTime> nextRetryAt = GeneratedColumn<DateTime>(
    'next_retry_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _processingStartedAtMeta =
      const VerificationMeta('processingStartedAt');
  @override
  late final GeneratedColumn<DateTime> processingStartedAt =
      GeneratedColumn<DateTime>(
        'processing_started_at',
        aliasedName,
        true,
        type: DriftSqlType.dateTime,
        requiredDuringInsert: false,
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    businessId,
    type,
    payloadJson,
    status,
    attempts,
    queuedAt,
    completedAt,
    fingerprint,
    lastError,
    nextRetryAt,
    processingStartedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'queue_actions';
  @override
  VerificationContext validateIntegrity(
    Insertable<QueueActionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('business_id')) {
      context.handle(
        _businessIdMeta,
        businessId.isAcceptableOrUnknown(data['business_id']!, _businessIdMeta),
      );
    } else if (isInserting) {
      context.missing(_businessIdMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
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
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    if (data.containsKey('queued_at')) {
      context.handle(
        _queuedAtMeta,
        queuedAt.isAcceptableOrUnknown(data['queued_at']!, _queuedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_queuedAtMeta);
    }
    if (data.containsKey('completed_at')) {
      context.handle(
        _completedAtMeta,
        completedAt.isAcceptableOrUnknown(
          data['completed_at']!,
          _completedAtMeta,
        ),
      );
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    if (data.containsKey('next_retry_at')) {
      context.handle(
        _nextRetryAtMeta,
        nextRetryAt.isAcceptableOrUnknown(
          data['next_retry_at']!,
          _nextRetryAtMeta,
        ),
      );
    }
    if (data.containsKey('processing_started_at')) {
      context.handle(
        _processingStartedAtMeta,
        processingStartedAt.isAcceptableOrUnknown(
          data['processing_started_at']!,
          _processingStartedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  QueueActionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return QueueActionRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      businessId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}business_id'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      payloadJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}payload_json'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
      queuedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}queued_at'],
      )!,
      completedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}completed_at'],
      ),
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      ),
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
      nextRetryAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}next_retry_at'],
      ),
      processingStartedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}processing_started_at'],
      ),
    );
  }

  @override
  $QueueActionsTable createAlias(String alias) {
    return $QueueActionsTable(attachedDatabase, alias);
  }
}

class QueueActionRow extends DataClass implements Insertable<QueueActionRow> {
  final String id;
  final String businessId;
  final String type;
  final String payloadJson;
  final String status;
  final int attempts;
  final DateTime queuedAt;
  final DateTime? completedAt;
  final String? fingerprint;
  final String? lastError;
  final DateTime? nextRetryAt;
  final DateTime? processingStartedAt;
  const QueueActionRow({
    required this.id,
    required this.businessId,
    required this.type,
    required this.payloadJson,
    required this.status,
    required this.attempts,
    required this.queuedAt,
    this.completedAt,
    this.fingerprint,
    this.lastError,
    this.nextRetryAt,
    this.processingStartedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['business_id'] = Variable<String>(businessId);
    map['type'] = Variable<String>(type);
    map['payload_json'] = Variable<String>(payloadJson);
    map['status'] = Variable<String>(status);
    map['attempts'] = Variable<int>(attempts);
    map['queued_at'] = Variable<DateTime>(queuedAt);
    if (!nullToAbsent || completedAt != null) {
      map['completed_at'] = Variable<DateTime>(completedAt);
    }
    if (!nullToAbsent || fingerprint != null) {
      map['fingerprint'] = Variable<String>(fingerprint);
    }
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    if (!nullToAbsent || nextRetryAt != null) {
      map['next_retry_at'] = Variable<DateTime>(nextRetryAt);
    }
    if (!nullToAbsent || processingStartedAt != null) {
      map['processing_started_at'] = Variable<DateTime>(processingStartedAt);
    }
    return map;
  }

  QueueActionsCompanion toCompanion(bool nullToAbsent) {
    return QueueActionsCompanion(
      id: Value(id),
      businessId: Value(businessId),
      type: Value(type),
      payloadJson: Value(payloadJson),
      status: Value(status),
      attempts: Value(attempts),
      queuedAt: Value(queuedAt),
      completedAt: completedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(completedAt),
      fingerprint: fingerprint == null && nullToAbsent
          ? const Value.absent()
          : Value(fingerprint),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      nextRetryAt: nextRetryAt == null && nullToAbsent
          ? const Value.absent()
          : Value(nextRetryAt),
      processingStartedAt: processingStartedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(processingStartedAt),
    );
  }

  factory QueueActionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return QueueActionRow(
      id: serializer.fromJson<String>(json['id']),
      businessId: serializer.fromJson<String>(json['businessId']),
      type: serializer.fromJson<String>(json['type']),
      payloadJson: serializer.fromJson<String>(json['payloadJson']),
      status: serializer.fromJson<String>(json['status']),
      attempts: serializer.fromJson<int>(json['attempts']),
      queuedAt: serializer.fromJson<DateTime>(json['queuedAt']),
      completedAt: serializer.fromJson<DateTime?>(json['completedAt']),
      fingerprint: serializer.fromJson<String?>(json['fingerprint']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      nextRetryAt: serializer.fromJson<DateTime?>(json['nextRetryAt']),
      processingStartedAt: serializer.fromJson<DateTime?>(
        json['processingStartedAt'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'businessId': serializer.toJson<String>(businessId),
      'type': serializer.toJson<String>(type),
      'payloadJson': serializer.toJson<String>(payloadJson),
      'status': serializer.toJson<String>(status),
      'attempts': serializer.toJson<int>(attempts),
      'queuedAt': serializer.toJson<DateTime>(queuedAt),
      'completedAt': serializer.toJson<DateTime?>(completedAt),
      'fingerprint': serializer.toJson<String?>(fingerprint),
      'lastError': serializer.toJson<String?>(lastError),
      'nextRetryAt': serializer.toJson<DateTime?>(nextRetryAt),
      'processingStartedAt': serializer.toJson<DateTime?>(processingStartedAt),
    };
  }

  QueueActionRow copyWith({
    String? id,
    String? businessId,
    String? type,
    String? payloadJson,
    String? status,
    int? attempts,
    DateTime? queuedAt,
    Value<DateTime?> completedAt = const Value.absent(),
    Value<String?> fingerprint = const Value.absent(),
    Value<String?> lastError = const Value.absent(),
    Value<DateTime?> nextRetryAt = const Value.absent(),
    Value<DateTime?> processingStartedAt = const Value.absent(),
  }) => QueueActionRow(
    id: id ?? this.id,
    businessId: businessId ?? this.businessId,
    type: type ?? this.type,
    payloadJson: payloadJson ?? this.payloadJson,
    status: status ?? this.status,
    attempts: attempts ?? this.attempts,
    queuedAt: queuedAt ?? this.queuedAt,
    completedAt: completedAt.present ? completedAt.value : this.completedAt,
    fingerprint: fingerprint.present ? fingerprint.value : this.fingerprint,
    lastError: lastError.present ? lastError.value : this.lastError,
    nextRetryAt: nextRetryAt.present ? nextRetryAt.value : this.nextRetryAt,
    processingStartedAt: processingStartedAt.present
        ? processingStartedAt.value
        : this.processingStartedAt,
  );
  QueueActionRow copyWithCompanion(QueueActionsCompanion data) {
    return QueueActionRow(
      id: data.id.present ? data.id.value : this.id,
      businessId: data.businessId.present
          ? data.businessId.value
          : this.businessId,
      type: data.type.present ? data.type.value : this.type,
      payloadJson: data.payloadJson.present
          ? data.payloadJson.value
          : this.payloadJson,
      status: data.status.present ? data.status.value : this.status,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      queuedAt: data.queuedAt.present ? data.queuedAt.value : this.queuedAt,
      completedAt: data.completedAt.present
          ? data.completedAt.value
          : this.completedAt,
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      nextRetryAt: data.nextRetryAt.present
          ? data.nextRetryAt.value
          : this.nextRetryAt,
      processingStartedAt: data.processingStartedAt.present
          ? data.processingStartedAt.value
          : this.processingStartedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('QueueActionRow(')
          ..write('id: $id, ')
          ..write('businessId: $businessId, ')
          ..write('type: $type, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('status: $status, ')
          ..write('attempts: $attempts, ')
          ..write('queuedAt: $queuedAt, ')
          ..write('completedAt: $completedAt, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('lastError: $lastError, ')
          ..write('nextRetryAt: $nextRetryAt, ')
          ..write('processingStartedAt: $processingStartedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    businessId,
    type,
    payloadJson,
    status,
    attempts,
    queuedAt,
    completedAt,
    fingerprint,
    lastError,
    nextRetryAt,
    processingStartedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is QueueActionRow &&
          other.id == this.id &&
          other.businessId == this.businessId &&
          other.type == this.type &&
          other.payloadJson == this.payloadJson &&
          other.status == this.status &&
          other.attempts == this.attempts &&
          other.queuedAt == this.queuedAt &&
          other.completedAt == this.completedAt &&
          other.fingerprint == this.fingerprint &&
          other.lastError == this.lastError &&
          other.nextRetryAt == this.nextRetryAt &&
          other.processingStartedAt == this.processingStartedAt);
}

class QueueActionsCompanion extends UpdateCompanion<QueueActionRow> {
  final Value<String> id;
  final Value<String> businessId;
  final Value<String> type;
  final Value<String> payloadJson;
  final Value<String> status;
  final Value<int> attempts;
  final Value<DateTime> queuedAt;
  final Value<DateTime?> completedAt;
  final Value<String?> fingerprint;
  final Value<String?> lastError;
  final Value<DateTime?> nextRetryAt;
  final Value<DateTime?> processingStartedAt;
  final Value<int> rowid;
  const QueueActionsCompanion({
    this.id = const Value.absent(),
    this.businessId = const Value.absent(),
    this.type = const Value.absent(),
    this.payloadJson = const Value.absent(),
    this.status = const Value.absent(),
    this.attempts = const Value.absent(),
    this.queuedAt = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.lastError = const Value.absent(),
    this.nextRetryAt = const Value.absent(),
    this.processingStartedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  QueueActionsCompanion.insert({
    required String id,
    required String businessId,
    required String type,
    required String payloadJson,
    this.status = const Value.absent(),
    this.attempts = const Value.absent(),
    required DateTime queuedAt,
    this.completedAt = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.lastError = const Value.absent(),
    this.nextRetryAt = const Value.absent(),
    this.processingStartedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       businessId = Value(businessId),
       type = Value(type),
       payloadJson = Value(payloadJson),
       queuedAt = Value(queuedAt);
  static Insertable<QueueActionRow> custom({
    Expression<String>? id,
    Expression<String>? businessId,
    Expression<String>? type,
    Expression<String>? payloadJson,
    Expression<String>? status,
    Expression<int>? attempts,
    Expression<DateTime>? queuedAt,
    Expression<DateTime>? completedAt,
    Expression<String>? fingerprint,
    Expression<String>? lastError,
    Expression<DateTime>? nextRetryAt,
    Expression<DateTime>? processingStartedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (businessId != null) 'business_id': businessId,
      if (type != null) 'type': type,
      if (payloadJson != null) 'payload_json': payloadJson,
      if (status != null) 'status': status,
      if (attempts != null) 'attempts': attempts,
      if (queuedAt != null) 'queued_at': queuedAt,
      if (completedAt != null) 'completed_at': completedAt,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (lastError != null) 'last_error': lastError,
      if (nextRetryAt != null) 'next_retry_at': nextRetryAt,
      if (processingStartedAt != null)
        'processing_started_at': processingStartedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  QueueActionsCompanion copyWith({
    Value<String>? id,
    Value<String>? businessId,
    Value<String>? type,
    Value<String>? payloadJson,
    Value<String>? status,
    Value<int>? attempts,
    Value<DateTime>? queuedAt,
    Value<DateTime?>? completedAt,
    Value<String?>? fingerprint,
    Value<String?>? lastError,
    Value<DateTime?>? nextRetryAt,
    Value<DateTime?>? processingStartedAt,
    Value<int>? rowid,
  }) {
    return QueueActionsCompanion(
      id: id ?? this.id,
      businessId: businessId ?? this.businessId,
      type: type ?? this.type,
      payloadJson: payloadJson ?? this.payloadJson,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      queuedAt: queuedAt ?? this.queuedAt,
      completedAt: completedAt ?? this.completedAt,
      fingerprint: fingerprint ?? this.fingerprint,
      lastError: lastError ?? this.lastError,
      nextRetryAt: nextRetryAt ?? this.nextRetryAt,
      processingStartedAt: processingStartedAt ?? this.processingStartedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (businessId.present) {
      map['business_id'] = Variable<String>(businessId.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (payloadJson.present) {
      map['payload_json'] = Variable<String>(payloadJson.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (queuedAt.present) {
      map['queued_at'] = Variable<DateTime>(queuedAt.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<DateTime>(completedAt.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (nextRetryAt.present) {
      map['next_retry_at'] = Variable<DateTime>(nextRetryAt.value);
    }
    if (processingStartedAt.present) {
      map['processing_started_at'] = Variable<DateTime>(
        processingStartedAt.value,
      );
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('QueueActionsCompanion(')
          ..write('id: $id, ')
          ..write('businessId: $businessId, ')
          ..write('type: $type, ')
          ..write('payloadJson: $payloadJson, ')
          ..write('status: $status, ')
          ..write('attempts: $attempts, ')
          ..write('queuedAt: $queuedAt, ')
          ..write('completedAt: $completedAt, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('lastError: $lastError, ')
          ..write('nextRetryAt: $nextRetryAt, ')
          ..write('processingStartedAt: $processingStartedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CompletedOpsTable extends CompletedOps
    with TableInfo<$CompletedOpsTable, CompletedOpRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CompletedOpsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _opIdMeta = const VerificationMeta('opId');
  @override
  late final GeneratedColumn<String> opId = GeneratedColumn<String>(
    'op_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
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
  static const VerificationMeta _completedAtMeta = const VerificationMeta(
    'completedAt',
  );
  @override
  late final GeneratedColumn<DateTime> completedAt = GeneratedColumn<DateTime>(
    'completed_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [opId, businessId, completedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'completed_ops';
  @override
  VerificationContext validateIntegrity(
    Insertable<CompletedOpRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('op_id')) {
      context.handle(
        _opIdMeta,
        opId.isAcceptableOrUnknown(data['op_id']!, _opIdMeta),
      );
    } else if (isInserting) {
      context.missing(_opIdMeta);
    }
    if (data.containsKey('business_id')) {
      context.handle(
        _businessIdMeta,
        businessId.isAcceptableOrUnknown(data['business_id']!, _businessIdMeta),
      );
    } else if (isInserting) {
      context.missing(_businessIdMeta);
    }
    if (data.containsKey('completed_at')) {
      context.handle(
        _completedAtMeta,
        completedAt.isAcceptableOrUnknown(
          data['completed_at']!,
          _completedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_completedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {opId, businessId};
  @override
  CompletedOpRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CompletedOpRow(
      opId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op_id'],
      )!,
      businessId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}business_id'],
      )!,
      completedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}completed_at'],
      )!,
    );
  }

  @override
  $CompletedOpsTable createAlias(String alias) {
    return $CompletedOpsTable(attachedDatabase, alias);
  }
}

class CompletedOpRow extends DataClass implements Insertable<CompletedOpRow> {
  final String opId;
  final String businessId;
  final DateTime completedAt;
  const CompletedOpRow({
    required this.opId,
    required this.businessId,
    required this.completedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['op_id'] = Variable<String>(opId);
    map['business_id'] = Variable<String>(businessId);
    map['completed_at'] = Variable<DateTime>(completedAt);
    return map;
  }

  CompletedOpsCompanion toCompanion(bool nullToAbsent) {
    return CompletedOpsCompanion(
      opId: Value(opId),
      businessId: Value(businessId),
      completedAt: Value(completedAt),
    );
  }

  factory CompletedOpRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CompletedOpRow(
      opId: serializer.fromJson<String>(json['opId']),
      businessId: serializer.fromJson<String>(json['businessId']),
      completedAt: serializer.fromJson<DateTime>(json['completedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'opId': serializer.toJson<String>(opId),
      'businessId': serializer.toJson<String>(businessId),
      'completedAt': serializer.toJson<DateTime>(completedAt),
    };
  }

  CompletedOpRow copyWith({
    String? opId,
    String? businessId,
    DateTime? completedAt,
  }) => CompletedOpRow(
    opId: opId ?? this.opId,
    businessId: businessId ?? this.businessId,
    completedAt: completedAt ?? this.completedAt,
  );
  CompletedOpRow copyWithCompanion(CompletedOpsCompanion data) {
    return CompletedOpRow(
      opId: data.opId.present ? data.opId.value : this.opId,
      businessId: data.businessId.present
          ? data.businessId.value
          : this.businessId,
      completedAt: data.completedAt.present
          ? data.completedAt.value
          : this.completedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CompletedOpRow(')
          ..write('opId: $opId, ')
          ..write('businessId: $businessId, ')
          ..write('completedAt: $completedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(opId, businessId, completedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CompletedOpRow &&
          other.opId == this.opId &&
          other.businessId == this.businessId &&
          other.completedAt == this.completedAt);
}

class CompletedOpsCompanion extends UpdateCompanion<CompletedOpRow> {
  final Value<String> opId;
  final Value<String> businessId;
  final Value<DateTime> completedAt;
  final Value<int> rowid;
  const CompletedOpsCompanion({
    this.opId = const Value.absent(),
    this.businessId = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CompletedOpsCompanion.insert({
    required String opId,
    required String businessId,
    required DateTime completedAt,
    this.rowid = const Value.absent(),
  }) : opId = Value(opId),
       businessId = Value(businessId),
       completedAt = Value(completedAt);
  static Insertable<CompletedOpRow> custom({
    Expression<String>? opId,
    Expression<String>? businessId,
    Expression<DateTime>? completedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (opId != null) 'op_id': opId,
      if (businessId != null) 'business_id': businessId,
      if (completedAt != null) 'completed_at': completedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CompletedOpsCompanion copyWith({
    Value<String>? opId,
    Value<String>? businessId,
    Value<DateTime>? completedAt,
    Value<int>? rowid,
  }) {
    return CompletedOpsCompanion(
      opId: opId ?? this.opId,
      businessId: businessId ?? this.businessId,
      completedAt: completedAt ?? this.completedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (opId.present) {
      map['op_id'] = Variable<String>(opId.value);
    }
    if (businessId.present) {
      map['business_id'] = Variable<String>(businessId.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<DateTime>(completedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CompletedOpsCompanion(')
          ..write('opId: $opId, ')
          ..write('businessId: $businessId, ')
          ..write('completedAt: $completedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CompletedFingerprintsTable extends CompletedFingerprints
    with TableInfo<$CompletedFingerprintsTable, CompletedFingerprintRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CompletedFingerprintsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
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
  static const VerificationMeta _completedAtMeta = const VerificationMeta(
    'completedAt',
  );
  @override
  late final GeneratedColumn<DateTime> completedAt = GeneratedColumn<DateTime>(
    'completed_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [fingerprint, businessId, completedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'completed_fingerprints';
  @override
  VerificationContext validateIntegrity(
    Insertable<CompletedFingerprintRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    if (data.containsKey('business_id')) {
      context.handle(
        _businessIdMeta,
        businessId.isAcceptableOrUnknown(data['business_id']!, _businessIdMeta),
      );
    } else if (isInserting) {
      context.missing(_businessIdMeta);
    }
    if (data.containsKey('completed_at')) {
      context.handle(
        _completedAtMeta,
        completedAt.isAcceptableOrUnknown(
          data['completed_at']!,
          _completedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_completedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {fingerprint, businessId};
  @override
  CompletedFingerprintRow map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CompletedFingerprintRow(
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      )!,
      businessId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}business_id'],
      )!,
      completedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}completed_at'],
      )!,
    );
  }

  @override
  $CompletedFingerprintsTable createAlias(String alias) {
    return $CompletedFingerprintsTable(attachedDatabase, alias);
  }
}

class CompletedFingerprintRow extends DataClass
    implements Insertable<CompletedFingerprintRow> {
  final String fingerprint;
  final String businessId;
  final DateTime completedAt;
  const CompletedFingerprintRow({
    required this.fingerprint,
    required this.businessId,
    required this.completedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['fingerprint'] = Variable<String>(fingerprint);
    map['business_id'] = Variable<String>(businessId);
    map['completed_at'] = Variable<DateTime>(completedAt);
    return map;
  }

  CompletedFingerprintsCompanion toCompanion(bool nullToAbsent) {
    return CompletedFingerprintsCompanion(
      fingerprint: Value(fingerprint),
      businessId: Value(businessId),
      completedAt: Value(completedAt),
    );
  }

  factory CompletedFingerprintRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CompletedFingerprintRow(
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
      businessId: serializer.fromJson<String>(json['businessId']),
      completedAt: serializer.fromJson<DateTime>(json['completedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'fingerprint': serializer.toJson<String>(fingerprint),
      'businessId': serializer.toJson<String>(businessId),
      'completedAt': serializer.toJson<DateTime>(completedAt),
    };
  }

  CompletedFingerprintRow copyWith({
    String? fingerprint,
    String? businessId,
    DateTime? completedAt,
  }) => CompletedFingerprintRow(
    fingerprint: fingerprint ?? this.fingerprint,
    businessId: businessId ?? this.businessId,
    completedAt: completedAt ?? this.completedAt,
  );
  CompletedFingerprintRow copyWithCompanion(
    CompletedFingerprintsCompanion data,
  ) {
    return CompletedFingerprintRow(
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
      businessId: data.businessId.present
          ? data.businessId.value
          : this.businessId,
      completedAt: data.completedAt.present
          ? data.completedAt.value
          : this.completedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CompletedFingerprintRow(')
          ..write('fingerprint: $fingerprint, ')
          ..write('businessId: $businessId, ')
          ..write('completedAt: $completedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(fingerprint, businessId, completedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CompletedFingerprintRow &&
          other.fingerprint == this.fingerprint &&
          other.businessId == this.businessId &&
          other.completedAt == this.completedAt);
}

class CompletedFingerprintsCompanion
    extends UpdateCompanion<CompletedFingerprintRow> {
  final Value<String> fingerprint;
  final Value<String> businessId;
  final Value<DateTime> completedAt;
  final Value<int> rowid;
  const CompletedFingerprintsCompanion({
    this.fingerprint = const Value.absent(),
    this.businessId = const Value.absent(),
    this.completedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CompletedFingerprintsCompanion.insert({
    required String fingerprint,
    required String businessId,
    required DateTime completedAt,
    this.rowid = const Value.absent(),
  }) : fingerprint = Value(fingerprint),
       businessId = Value(businessId),
       completedAt = Value(completedAt);
  static Insertable<CompletedFingerprintRow> custom({
    Expression<String>? fingerprint,
    Expression<String>? businessId,
    Expression<DateTime>? completedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (businessId != null) 'business_id': businessId,
      if (completedAt != null) 'completed_at': completedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CompletedFingerprintsCompanion copyWith({
    Value<String>? fingerprint,
    Value<String>? businessId,
    Value<DateTime>? completedAt,
    Value<int>? rowid,
  }) {
    return CompletedFingerprintsCompanion(
      fingerprint: fingerprint ?? this.fingerprint,
      businessId: businessId ?? this.businessId,
      completedAt: completedAt ?? this.completedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (businessId.present) {
      map['business_id'] = Variable<String>(businessId.value);
    }
    if (completedAt.present) {
      map['completed_at'] = Variable<DateTime>(completedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CompletedFingerprintsCompanion(')
          ..write('fingerprint: $fingerprint, ')
          ..write('businessId: $businessId, ')
          ..write('completedAt: $completedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$OfflineQueueDb extends GeneratedDatabase {
  _$OfflineQueueDb(QueryExecutor e) : super(e);
  $OfflineQueueDbManager get managers => $OfflineQueueDbManager(this);
  late final $QueueActionsTable queueActions = $QueueActionsTable(this);
  late final $CompletedOpsTable completedOps = $CompletedOpsTable(this);
  late final $CompletedFingerprintsTable completedFingerprints =
      $CompletedFingerprintsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    queueActions,
    completedOps,
    completedFingerprints,
  ];
}

typedef $$QueueActionsTableCreateCompanionBuilder =
    QueueActionsCompanion Function({
      required String id,
      required String businessId,
      required String type,
      required String payloadJson,
      Value<String> status,
      Value<int> attempts,
      required DateTime queuedAt,
      Value<DateTime?> completedAt,
      Value<String?> fingerprint,
      Value<String?> lastError,
      Value<DateTime?> nextRetryAt,
      Value<DateTime?> processingStartedAt,
      Value<int> rowid,
    });
typedef $$QueueActionsTableUpdateCompanionBuilder =
    QueueActionsCompanion Function({
      Value<String> id,
      Value<String> businessId,
      Value<String> type,
      Value<String> payloadJson,
      Value<String> status,
      Value<int> attempts,
      Value<DateTime> queuedAt,
      Value<DateTime?> completedAt,
      Value<String?> fingerprint,
      Value<String?> lastError,
      Value<DateTime?> nextRetryAt,
      Value<DateTime?> processingStartedAt,
      Value<int> rowid,
    });

class $$QueueActionsTableFilterComposer
    extends Composer<_$OfflineQueueDb, $QueueActionsTable> {
  $$QueueActionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get queuedAt => $composableBuilder(
    column: $table.queuedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get nextRetryAt => $composableBuilder(
    column: $table.nextRetryAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get processingStartedAt => $composableBuilder(
    column: $table.processingStartedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$QueueActionsTableOrderingComposer
    extends Composer<_$OfflineQueueDb, $QueueActionsTable> {
  $$QueueActionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get queuedAt => $composableBuilder(
    column: $table.queuedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get nextRetryAt => $composableBuilder(
    column: $table.nextRetryAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get processingStartedAt => $composableBuilder(
    column: $table.processingStartedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$QueueActionsTableAnnotationComposer
    extends Composer<_$OfflineQueueDb, $QueueActionsTable> {
  $$QueueActionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get payloadJson => $composableBuilder(
    column: $table.payloadJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<DateTime> get queuedAt =>
      $composableBuilder(column: $table.queuedAt, builder: (column) => column);

  GeneratedColumn<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<DateTime> get nextRetryAt => $composableBuilder(
    column: $table.nextRetryAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get processingStartedAt => $composableBuilder(
    column: $table.processingStartedAt,
    builder: (column) => column,
  );
}

class $$QueueActionsTableTableManager
    extends
        RootTableManager<
          _$OfflineQueueDb,
          $QueueActionsTable,
          QueueActionRow,
          $$QueueActionsTableFilterComposer,
          $$QueueActionsTableOrderingComposer,
          $$QueueActionsTableAnnotationComposer,
          $$QueueActionsTableCreateCompanionBuilder,
          $$QueueActionsTableUpdateCompanionBuilder,
          (
            QueueActionRow,
            BaseReferences<
              _$OfflineQueueDb,
              $QueueActionsTable,
              QueueActionRow
            >,
          ),
          QueueActionRow,
          PrefetchHooks Function()
        > {
  $$QueueActionsTableTableManager(_$OfflineQueueDb db, $QueueActionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$QueueActionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$QueueActionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$QueueActionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> businessId = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> payloadJson = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<DateTime> queuedAt = const Value.absent(),
                Value<DateTime?> completedAt = const Value.absent(),
                Value<String?> fingerprint = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<DateTime?> nextRetryAt = const Value.absent(),
                Value<DateTime?> processingStartedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QueueActionsCompanion(
                id: id,
                businessId: businessId,
                type: type,
                payloadJson: payloadJson,
                status: status,
                attempts: attempts,
                queuedAt: queuedAt,
                completedAt: completedAt,
                fingerprint: fingerprint,
                lastError: lastError,
                nextRetryAt: nextRetryAt,
                processingStartedAt: processingStartedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String businessId,
                required String type,
                required String payloadJson,
                Value<String> status = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                required DateTime queuedAt,
                Value<DateTime?> completedAt = const Value.absent(),
                Value<String?> fingerprint = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<DateTime?> nextRetryAt = const Value.absent(),
                Value<DateTime?> processingStartedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => QueueActionsCompanion.insert(
                id: id,
                businessId: businessId,
                type: type,
                payloadJson: payloadJson,
                status: status,
                attempts: attempts,
                queuedAt: queuedAt,
                completedAt: completedAt,
                fingerprint: fingerprint,
                lastError: lastError,
                nextRetryAt: nextRetryAt,
                processingStartedAt: processingStartedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$QueueActionsTableProcessedTableManager =
    ProcessedTableManager<
      _$OfflineQueueDb,
      $QueueActionsTable,
      QueueActionRow,
      $$QueueActionsTableFilterComposer,
      $$QueueActionsTableOrderingComposer,
      $$QueueActionsTableAnnotationComposer,
      $$QueueActionsTableCreateCompanionBuilder,
      $$QueueActionsTableUpdateCompanionBuilder,
      (
        QueueActionRow,
        BaseReferences<_$OfflineQueueDb, $QueueActionsTable, QueueActionRow>,
      ),
      QueueActionRow,
      PrefetchHooks Function()
    >;
typedef $$CompletedOpsTableCreateCompanionBuilder =
    CompletedOpsCompanion Function({
      required String opId,
      required String businessId,
      required DateTime completedAt,
      Value<int> rowid,
    });
typedef $$CompletedOpsTableUpdateCompanionBuilder =
    CompletedOpsCompanion Function({
      Value<String> opId,
      Value<String> businessId,
      Value<DateTime> completedAt,
      Value<int> rowid,
    });

class $$CompletedOpsTableFilterComposer
    extends Composer<_$OfflineQueueDb, $CompletedOpsTable> {
  $$CompletedOpsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CompletedOpsTableOrderingComposer
    extends Composer<_$OfflineQueueDb, $CompletedOpsTable> {
  $$CompletedOpsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CompletedOpsTableAnnotationComposer
    extends Composer<_$OfflineQueueDb, $CompletedOpsTable> {
  $$CompletedOpsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get opId =>
      $composableBuilder(column: $table.opId, builder: (column) => column);

  GeneratedColumn<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => column,
  );
}

class $$CompletedOpsTableTableManager
    extends
        RootTableManager<
          _$OfflineQueueDb,
          $CompletedOpsTable,
          CompletedOpRow,
          $$CompletedOpsTableFilterComposer,
          $$CompletedOpsTableOrderingComposer,
          $$CompletedOpsTableAnnotationComposer,
          $$CompletedOpsTableCreateCompanionBuilder,
          $$CompletedOpsTableUpdateCompanionBuilder,
          (
            CompletedOpRow,
            BaseReferences<
              _$OfflineQueueDb,
              $CompletedOpsTable,
              CompletedOpRow
            >,
          ),
          CompletedOpRow,
          PrefetchHooks Function()
        > {
  $$CompletedOpsTableTableManager(_$OfflineQueueDb db, $CompletedOpsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CompletedOpsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CompletedOpsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CompletedOpsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> opId = const Value.absent(),
                Value<String> businessId = const Value.absent(),
                Value<DateTime> completedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CompletedOpsCompanion(
                opId: opId,
                businessId: businessId,
                completedAt: completedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String opId,
                required String businessId,
                required DateTime completedAt,
                Value<int> rowid = const Value.absent(),
              }) => CompletedOpsCompanion.insert(
                opId: opId,
                businessId: businessId,
                completedAt: completedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CompletedOpsTableProcessedTableManager =
    ProcessedTableManager<
      _$OfflineQueueDb,
      $CompletedOpsTable,
      CompletedOpRow,
      $$CompletedOpsTableFilterComposer,
      $$CompletedOpsTableOrderingComposer,
      $$CompletedOpsTableAnnotationComposer,
      $$CompletedOpsTableCreateCompanionBuilder,
      $$CompletedOpsTableUpdateCompanionBuilder,
      (
        CompletedOpRow,
        BaseReferences<_$OfflineQueueDb, $CompletedOpsTable, CompletedOpRow>,
      ),
      CompletedOpRow,
      PrefetchHooks Function()
    >;
typedef $$CompletedFingerprintsTableCreateCompanionBuilder =
    CompletedFingerprintsCompanion Function({
      required String fingerprint,
      required String businessId,
      required DateTime completedAt,
      Value<int> rowid,
    });
typedef $$CompletedFingerprintsTableUpdateCompanionBuilder =
    CompletedFingerprintsCompanion Function({
      Value<String> fingerprint,
      Value<String> businessId,
      Value<DateTime> completedAt,
      Value<int> rowid,
    });

class $$CompletedFingerprintsTableFilterComposer
    extends Composer<_$OfflineQueueDb, $CompletedFingerprintsTable> {
  $$CompletedFingerprintsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$CompletedFingerprintsTableOrderingComposer
    extends Composer<_$OfflineQueueDb, $CompletedFingerprintsTable> {
  $$CompletedFingerprintsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$CompletedFingerprintsTableAnnotationComposer
    extends Composer<_$OfflineQueueDb, $CompletedFingerprintsTable> {
  $$CompletedFingerprintsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<String> get businessId => $composableBuilder(
    column: $table.businessId,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get completedAt => $composableBuilder(
    column: $table.completedAt,
    builder: (column) => column,
  );
}

class $$CompletedFingerprintsTableTableManager
    extends
        RootTableManager<
          _$OfflineQueueDb,
          $CompletedFingerprintsTable,
          CompletedFingerprintRow,
          $$CompletedFingerprintsTableFilterComposer,
          $$CompletedFingerprintsTableOrderingComposer,
          $$CompletedFingerprintsTableAnnotationComposer,
          $$CompletedFingerprintsTableCreateCompanionBuilder,
          $$CompletedFingerprintsTableUpdateCompanionBuilder,
          (
            CompletedFingerprintRow,
            BaseReferences<
              _$OfflineQueueDb,
              $CompletedFingerprintsTable,
              CompletedFingerprintRow
            >,
          ),
          CompletedFingerprintRow,
          PrefetchHooks Function()
        > {
  $$CompletedFingerprintsTableTableManager(
    _$OfflineQueueDb db,
    $CompletedFingerprintsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CompletedFingerprintsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$CompletedFingerprintsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$CompletedFingerprintsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> fingerprint = const Value.absent(),
                Value<String> businessId = const Value.absent(),
                Value<DateTime> completedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => CompletedFingerprintsCompanion(
                fingerprint: fingerprint,
                businessId: businessId,
                completedAt: completedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String fingerprint,
                required String businessId,
                required DateTime completedAt,
                Value<int> rowid = const Value.absent(),
              }) => CompletedFingerprintsCompanion.insert(
                fingerprint: fingerprint,
                businessId: businessId,
                completedAt: completedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$CompletedFingerprintsTableProcessedTableManager =
    ProcessedTableManager<
      _$OfflineQueueDb,
      $CompletedFingerprintsTable,
      CompletedFingerprintRow,
      $$CompletedFingerprintsTableFilterComposer,
      $$CompletedFingerprintsTableOrderingComposer,
      $$CompletedFingerprintsTableAnnotationComposer,
      $$CompletedFingerprintsTableCreateCompanionBuilder,
      $$CompletedFingerprintsTableUpdateCompanionBuilder,
      (
        CompletedFingerprintRow,
        BaseReferences<
          _$OfflineQueueDb,
          $CompletedFingerprintsTable,
          CompletedFingerprintRow
        >,
      ),
      CompletedFingerprintRow,
      PrefetchHooks Function()
    >;

class $OfflineQueueDbManager {
  final _$OfflineQueueDb _db;
  $OfflineQueueDbManager(this._db);
  $$QueueActionsTableTableManager get queueActions =>
      $$QueueActionsTableTableManager(_db, _db.queueActions);
  $$CompletedOpsTableTableManager get completedOps =>
      $$CompletedOpsTableTableManager(_db, _db.completedOps);
  $$CompletedFingerprintsTableTableManager get completedFingerprints =>
      $$CompletedFingerprintsTableTableManager(_db, _db.completedFingerprints);
}
