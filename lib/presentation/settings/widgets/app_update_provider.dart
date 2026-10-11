import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/repositories/app_release_repository.dart';

/// Lo instalado frente a lo último publicado para esta plataforma.
class AppUpdateStatus {
  final String platform;
  final String installedVersion;
  final String installedBuild;

  /// Null si no hay versiones publicadas para esta plataforma.
  final AppRelease? latest;

  const AppUpdateStatus({
    required this.platform,
    required this.installedVersion,
    required this.installedBuild,
    required this.latest,
  });

  bool get updateAvailable =>
      latest != null &&
      isNewerRelease(
        latest: latest!,
        installedVersion: installedVersion,
        installedBuild: installedBuild,
      );
}

final appReleaseRepositoryProvider = Provider<AppReleaseRepository>(
  (ref) => AppReleaseRepository(Supabase.instance.client),
);

/// Versión instalada (del bundle, no de --dart-define).
final installedAppVersionProvider =
    FutureProvider<({String version, String build})>((ref) async {
      final info = await PackageInfo.fromPlatform();
      return (version: info.version, build: info.buildNumber);
    });

/// Se revisa al arrancar y cada 30 min. Sin red o sin la tabla: error (el
/// aviso queda apagado; el diálogo lo explica).
final appUpdateStatusProvider = FutureProvider<AppUpdateStatus>((ref) async {
  final timer = Timer(const Duration(minutes: 30), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  final installed = await ref.watch(installedAppVersionProvider.future);
  final platform = currentReleasePlatform();
  final latest = await ref.read(appReleaseRepositoryProvider).latest(platform);
  return AppUpdateStatus(
    platform: platform,
    installedVersion: installed.version,
    installedBuild: installed.build,
    latest: latest,
  );
});

/// Atajo para el punto del menú: false mientras carga o si falla.
final appUpdateAvailableProvider = Provider<bool>(
  (ref) => ref
      .watch(appUpdateStatusProvider)
      .maybeWhen(data: (s) => s.updateAvailable, orElse: () => false),
);
