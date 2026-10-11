import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Versión publicada de la app para una plataforma (`app_releases`,
/// 20261010_0025).
class AppRelease {
  final String platform;
  final String version;
  final int build;

  /// Instalador (Windows/Mac) o ficha de la tienda (Android/iOS).
  final String? downloadUrl;
  final String? notes;
  final DateTime? publishedAt;

  const AppRelease({
    required this.platform,
    required this.version,
    required this.build,
    this.downloadUrl,
    this.notes,
    this.publishedAt,
  });

  factory AppRelease.fromRow(Map<String, dynamic> row) => AppRelease(
    platform: row['platform'].toString(),
    version: row['version'].toString(),
    build: (row['build'] as num).toInt(),
    downloadUrl: _text(row['download_url']),
    notes: _text(row['notes']),
    publishedAt: DateTime.tryParse('${row['published_at'] ?? ''}')?.toLocal(),
  );

  static String? _text(Object? v) {
    final t = v?.toString().trim();
    return t == null || t.isEmpty ? null : t;
  }
}

/// Plataforma con la que se publica en `app_releases`.
String currentReleasePlatform() {
  if (kIsWeb) return 'web';
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  return 'linux';
}

/// ¿[latest] es más nueva que lo instalado? Manda el número de build
/// (`version: 2.0.21+20021` → 20021); si el instalado no lo trae, se compara
/// la versión por partes (2.0.10 > 2.0.9).
bool isNewerRelease({
  required AppRelease latest,
  required String installedVersion,
  required String installedBuild,
}) {
  final build = int.tryParse(installedBuild.trim());
  if (build != null && build > 0) return latest.build > build;
  return compareVersions(latest.version, installedVersion) > 0;
}

/// Compara «2.0.21» con «2.0.9» por partes numéricas (positivo si [a] > [b]).
int compareVersions(String a, String b) {
  List<int> parts(String v) => v
      .split('+')
      .first
      .split('.')
      .map((p) => int.tryParse(p.trim()) ?? 0)
      .toList();
  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < (pa.length > pb.length ? pa.length : pb.length); i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

class AppReleaseRepository {
  final SupabaseClient _client;

  AppReleaseRepository(this._client);

  /// La versión más nueva publicada para [platform], o null si no hay.
  Future<AppRelease?> latest(String platform) async {
    final row = await _client
        .from('app_releases')
        .select()
        .eq('platform', platform)
        .order('build', ascending: false)
        .limit(1)
        .maybeSingle();
    return row == null ? null : AppRelease.fromRow(row);
  }
}
