/// Modelo de entrada de caché
class CacheEntry<T> {
  final String key;
  final T data;
  final CacheMetadata metadata;

  const CacheEntry({
    required this.key,
    required this.data,
    required this.metadata,
  });

  Map<String, dynamic> toJson(Map<String, dynamic> Function(T) toJsonT) {
    return {'key': key, 'data': toJsonT(data), 'metadata': metadata.toJson()};
  }

  factory CacheEntry.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic) fromJsonT,
  ) {
    return CacheEntry(
      key: json['key'] as String,
      data: fromJsonT(json['data']),
      metadata: CacheMetadata.fromJson(
        json['metadata'] as Map<String, dynamic>,
      ),
    );
  }

  bool get isExpired => metadata.isExpired;
  bool get isStale => metadata.isStale;

  CacheEntry<T> copyWith({String? key, T? data, CacheMetadata? metadata}) {
    return CacheEntry(
      key: key ?? this.key,
      data: data ?? this.data,
      metadata: metadata ?? this.metadata,
    );
  }
}

/// Metadata de una entrada de caché
class CacheMetadata {
  final DateTime cachedAt;
  final DateTime? expiresAt;
  final DateTime? lastSyncedAt;
  final String? hash;
  final int sizeInBytes;
  final bool compressed;
  final String module;
  final int version;

  const CacheMetadata({
    required this.cachedAt,
    this.expiresAt,
    this.lastSyncedAt,
    this.hash,
    required this.sizeInBytes,
    this.compressed = false,
    required this.module,
    this.version = 1,
  });

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  bool get isStale {
    if (expiresAt == null) return false;
    final halfLife = expiresAt!.difference(cachedAt) ~/ 2;
    return DateTime.now().isAfter(cachedAt.add(halfLife));
  }

  Duration? get timeUntilExpiration {
    if (expiresAt == null) return null;
    final now = DateTime.now();
    if (now.isAfter(expiresAt!)) return Duration.zero;
    return expiresAt!.difference(now);
  }

  Map<String, dynamic> toJson() {
    return {
      'cachedAt': cachedAt.toIso8601String(),
      'expiresAt': expiresAt?.toIso8601String(),
      'lastSyncedAt': lastSyncedAt?.toIso8601String(),
      'hash': hash,
      'sizeInBytes': sizeInBytes,
      'compressed': compressed,
      'module': module,
      'version': version,
    };
  }

  factory CacheMetadata.fromJson(Map<String, dynamic> json) {
    return CacheMetadata(
      cachedAt: DateTime.parse(json['cachedAt'] as String),
      expiresAt: json['expiresAt'] != null
          ? DateTime.parse(json['expiresAt'] as String)
          : null,
      lastSyncedAt: json['lastSyncedAt'] != null
          ? DateTime.parse(json['lastSyncedAt'] as String)
          : null,
      hash: json['hash'] as String?,
      sizeInBytes: json['sizeInBytes'] as int,
      compressed: json['compressed'] as bool? ?? false,
      module: json['module'] as String,
      version: json['version'] as int? ?? 1,
    );
  }

  CacheMetadata copyWith({
    DateTime? cachedAt,
    DateTime? expiresAt,
    DateTime? lastSyncedAt,
    String? hash,
    int? sizeInBytes,
    bool? compressed,
    String? module,
    int? version,
  }) {
    return CacheMetadata(
      cachedAt: cachedAt ?? this.cachedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      hash: hash ?? this.hash,
      sizeInBytes: sizeInBytes ?? this.sizeInBytes,
      compressed: compressed ?? this.compressed,
      module: module ?? this.module,
      version: version ?? this.version,
    );
  }
}
