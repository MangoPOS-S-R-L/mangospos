/// Operación pendiente para sincronización offline
class PendingOperation {
  final String id;
  final OperationType type;
  final String module;
  final Map<String, dynamic> data;
  final DateTime timestamp;
  final QueuePriority priority;
  final int retryCount;
  final int maxRetries;
  final String? errorMessage;
  final OperationStatus status;

  const PendingOperation({
    required this.id,
    required this.type,
    required this.module,
    required this.data,
    required this.timestamp,
    required this.priority,
    this.retryCount = 0,
    this.maxRetries = 5,
    this.errorMessage,
    this.status = OperationStatus.pending,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'module': module,
      'data': data,
      'timestamp': timestamp.toIso8601String(),
      'priority': priority.name,
      'retryCount': retryCount,
      'maxRetries': maxRetries,
      'errorMessage': errorMessage,
      'status': status.name,
    };
  }

  factory PendingOperation.fromJson(Map<String, dynamic> json) {
    return PendingOperation(
      id: json['id'] as String,
      type: OperationType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => OperationType.create,
      ),
      module: json['module'] as String,
      data: json['data'] as Map<String, dynamic>,
      timestamp: DateTime.parse(json['timestamp'] as String),
      priority: QueuePriority.values.firstWhere(
        (e) => e.name == json['priority'],
        orElse: () => QueuePriority.normal,
      ),
      retryCount: json['retryCount'] as int? ?? 0,
      maxRetries: json['maxRetries'] as int? ?? 5,
      errorMessage: json['errorMessage'] as String?,
      status: OperationStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => OperationStatus.pending,
      ),
    );
  }

  PendingOperation copyWith({
    String? id,
    OperationType? type,
    String? module,
    Map<String, dynamic>? data,
    DateTime? timestamp,
    QueuePriority? priority,
    int? retryCount,
    int? maxRetries,
    String? errorMessage,
    OperationStatus? status,
  }) {
    return PendingOperation(
      id: id ?? this.id,
      type: type ?? this.type,
      module: module ?? this.module,
      data: data ?? this.data,
      timestamp: timestamp ?? this.timestamp,
      priority: priority ?? this.priority,
      retryCount: retryCount ?? this.retryCount,
      maxRetries: maxRetries ?? this.maxRetries,
      errorMessage: errorMessage ?? this.errorMessage,
      status: status ?? this.status,
    );
  }

  bool get canRetry => retryCount < maxRetries;
  bool get hasFailed => status == OperationStatus.failed;
  bool get isCompleted => status == OperationStatus.completed;
  bool get isPending => status == OperationStatus.pending;
}

enum OperationType { create, update, delete, custom }

enum QueuePriority {
  critical, // Procesar inmediatamente
  high, // Procesar pronto
  normal, // Procesar en orden
  low, // Procesar cuando haya capacidad
}

enum OperationStatus { pending, processing, completed, failed, cancelled }
