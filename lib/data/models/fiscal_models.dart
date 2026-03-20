class FiscalNcfSequence {
  final String? id;
  final String? businessId;
  final String tipo;
  final String serie;
  final int ultimoSeq;
  final int maximoSeq;
  final bool activo;

  FiscalNcfSequence({
    this.id,
    this.businessId,
    required this.tipo,
    required this.serie,
    required this.ultimoSeq,
    required this.maximoSeq,
    this.activo = true,
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
  };

  FiscalNcfSequence copyWith({
    String? id,
    String? businessId,
    String? tipo,
    String? serie,
    int? ultimoSeq,
    int? maximoSeq,
    bool? activo,
  }) {
    return FiscalNcfSequence(
      id: id ?? this.id,
      businessId: businessId ?? this.businessId,
      tipo: tipo ?? this.tipo,
      serie: serie ?? this.serie,
      ultimoSeq: ultimoSeq ?? this.ultimoSeq,
      maximoSeq: maximoSeq ?? this.maximoSeq,
      activo: activo ?? this.activo,
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
}
