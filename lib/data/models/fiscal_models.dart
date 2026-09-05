class FiscalNcfSequence {
  final String? id;
  final String? businessId;
  final String tipo;
  final String serie;
  final int ultimoSeq;
  final int maximoSeq;
  final bool activo;

  /// Fecha de vencimiento de la secuencia, tal como la autorizó la DGII
  /// (`ncf_sequences.expiration_date`). En e-CF viaja en el comprobante y la
  /// DGII la valida contra la autorización del rango: si no cuadra devuelve el
  /// código 145 y rechaza. Los tipos e-CF distintos de E32 no se pueden emitir
  /// sin ella. En NCF de papel (serie B) no aplica y queda en null.
  final DateTime? expirationDate;

  FiscalNcfSequence({
    this.id,
    this.businessId,
    required this.tipo,
    required this.serie,
    required this.ultimoSeq,
    required this.maximoSeq,
    this.activo = true,
    this.expirationDate,
  });

  factory FiscalNcfSequence.fromJson(Map<String, dynamic> json) {
    final rawType = (json['tipo'] ?? json['ncf_type'] ?? '').toString();
    final normalizedType = rawType.length >= 3 ? rawType.substring(1) : rawType;
    final derivedSerie = (json['serie'] ?? '').toString().isNotEmpty
        ? json['serie'].toString()
        : (rawType.isNotEmpty ? rawType.substring(0, 1) : 'B');

    return FiscalNcfSequence(
      id: json['id']?.toString(),
      businessId: json['business_id']?.toString(),
      tipo: normalizedType,
      serie: derivedSerie,
      ultimoSeq: (json['ultimo_seq'] ?? json['current_number'] ?? 0) as int,
      maximoSeq: (json['maximo_seq'] ?? json['range_end'] ?? 0) as int,
      activo: (json['activo'] ?? json['is_active'] ?? true) as bool,
      expirationDate: DateTime.tryParse(
        (json['expiration_date'] ?? '').toString(),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'business_id': businessId,
    'ncf_type': '$serie$tipo',
    'serie': serie,
    'current_number': ultimoSeq,
    'range_end': maximoSeq,
    'is_active': activo,
    'expiration_date': expirationDate?.toIso8601String().substring(0, 10),
  };

  FiscalNcfSequence copyWith({
    String? id,
    String? businessId,
    String? tipo,
    String? serie,
    int? ultimoSeq,
    int? maximoSeq,
    bool? activo,
    // Sentinela: `null` conserva la fecha actual, así que para borrarla hay que
    // pedirlo explícitamente.
    bool clearExpirationDate = false,
    DateTime? expirationDate,
  }) {
    return FiscalNcfSequence(
      id: id ?? this.id,
      businessId: businessId ?? this.businessId,
      tipo: tipo ?? this.tipo,
      serie: serie ?? this.serie,
      ultimoSeq: ultimoSeq ?? this.ultimoSeq,
      maximoSeq: maximoSeq ?? this.maximoSeq,
      activo: activo ?? this.activo,
      expirationDate: clearExpirationDate
          ? null
          : (expirationDate ?? this.expirationDate),
    );
  }

  String get ncfType => '$serie$tipo';

  String get lastNcfFormatted {
    return '$ncfType${ultimoSeq.toString().padLeft(8, '0')}';
  }

  String get nextNcfFormatted {
    final next = ultimoSeq + 1;
    return '$ncfType${next.toString().padLeft(8, '0')}';
  }

  int get remaining => maximoSeq - ultimoSeq;

  /// e-CF sin fecha de vencimiento cargada: `emit-document` bloquea la emisión
  /// de estos tipos porque la DGII los rechazaría con el código 145. E32 es la
  /// excepción — la DGII no le asigna vencimiento.
  bool get needsExpirationDate =>
      serie == 'E' && tipo != '32' && expirationDate == null;
}
