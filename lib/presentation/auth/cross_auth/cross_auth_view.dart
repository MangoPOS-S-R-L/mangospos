import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/core/utils/logger.dart';

// ignore: avoid_web_libraries_in_dot_dart
import 'package:web/web.dart' as web;

class CrossAuthView extends StatefulWidget {
  /// Token de acceso recibido como query param real (?at=) ANTES del fragmento #
  final String? accessToken;

  /// Refresh token recibido como query param real (?rt=) ANTES del fragmento #
  final String? refreshToken;

  const CrossAuthView({
    super.key,
    this.accessToken,
    this.refreshToken,
  });

  @override
  State<CrossAuthView> createState() => _CrossAuthViewState();
}

class _CrossAuthViewState extends State<CrossAuthView> {
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _handleAuth();
  }

  Future<void> _handleAuth() async {
    // Prioridad 1: tokens de GoRouter state (query params antes del '#')
    String? at = widget.accessToken;
    String? rt = widget.refreshToken;

    AppLogger.i('CrossAuthView init: at=${at != null ? "[presente, len=${at.length}]" : "null"}, rt=${rt != null ? "[presente]" : "null"}');

    // Prioridad 2: leer directamente de window.location si el widget no los tiene
    if (at == null || at.isEmpty) {
      try {
        final href = web.window.location.href;
        AppLogger.d('CrossAuthView: URL completa = $href');
        final uri = Uri.parse(href);

        // Query params de la URL real (antes del #)
        at ??= uri.queryParameters['at'];
        rt ??= uri.queryParameters['rt'];

        // También intentar desde el fragmento (formato antiguo /#/auth?at=...)
        if ((at == null || at.isEmpty) && uri.fragment.contains('?')) {
          final fragParams = Uri.splitQueryString(uri.fragment.split('?').last);
          at ??= fragParams['at'] ?? fragParams['access_token'];
          rt ??= fragParams['rt'] ?? fragParams['refresh_token'];
        }

        AppLogger.d('CrossAuthView: after URL scan: at=${at != null ? "[presente]" : "null"}');
      } catch (e) {
        AppLogger.w('CrossAuthView: Error leyendo URL: $e');
      }
    }

    // Prioridad 3: Supabase ya restauró la sesión automáticamente (detectSessionInUri)
    final existingSession = Supabase.instance.client.auth.currentSession;
    if (existingSession != null) {
      AppLogger.i('CrossAuthView: Sesión ya activa. Redirigiendo al dashboard...');
      _clearUrl();
      if (mounted) context.go(AppRoutes.dashboard);
      return;
    }

    // Sin tokens y sin sesión activa → ir al login
    if (at == null || at.isEmpty) {
      AppLogger.w('CrossAuthView: No hay tokens ni sesión activa. Redirigiendo al login.');
      if (mounted) context.go(AppRoutes.login);
      return;
    }

    try {
      AppLogger.i('CrossAuthView: Llamando setSession...');
      await Supabase.instance.client.auth.setSession(at);
      AppLogger.i('CrossAuthView: setSession exitoso.');

      _clearUrl();
      if (mounted) context.go(AppRoutes.dashboard);
    } catch (e, st) {
      AppLogger.e('CrossAuthView: setSession falló', error: e, stackTrace: st);
      // Mostrar el error en pantalla en vez de redirigir silenciosamente
      if (mounted) {
        setState(() {
          _errorMessage = 'Error validando sesión: $e';
        });
      }
    }
  }

  void _clearUrl() {
    try {
      final currentUri = Uri.parse(web.window.location.href);
      final newUrl =
          '${currentUri.scheme}://${currentUri.host}'
          '${currentUri.port != 80 && currentUri.port != 443 ? ":${currentUri.port}" : ""}/#/';
      web.window.history.replaceState(null, '', newUrl);
    } catch (e) {
      AppLogger.w('CrossAuthView: No se pudo limpiar la URL: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'No se pudo iniciar sesión',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => context.go(AppRoutes.login),
                  child: const Text('Ir al inicio de sesión'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 20),
            Text('Validando sesión...', style: TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
