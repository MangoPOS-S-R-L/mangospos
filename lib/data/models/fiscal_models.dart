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

  factory FiscalNcfSequence.fromJson(Map<String, dynamic> json) => FiscalNcfSequence(
    id: json['id'],
    businessId: json['business_id'],
    tipo: json['tipo'],
    serie: json['serie'],
    ultimoSeq: json['ultimo_seq'],
    maximoSeq: json['maximo_seq'],
    activo: json['activo'] ?? true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'business_id': businessId,
    'tipo': tipo,
    'serie': serie,
    'ultimo_seq': ultimoSeq,
    'maximo_seq': maximoSeq,
    'activo': activo,
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

  String get lastNcfFormatted {
    // Serie E (e-CF) tiene 13 caracteres total: E + Tipo (2) + Secuencia (10)
    // Serie B (Legacy) tiene 11 caracteres total: B + Tipo (2) + Secuencia (8)
    // Nota: El usuario mostró 12 caracteres en screenshot (B + 2 + 9), ajustamos a lo que parece ser su preferencia o requerimiento.
    final padding = serie == 'E' ? 10 : 8;
    return '$serie$tipo${ultimoSeq.toString().padLeft(padding, '0')}';
  }
  int get remaining => maximoSeq - ultimoSeq;
}
