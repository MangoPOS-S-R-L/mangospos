import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/core/utils/logger.dart';

// ignore: avoid_web_libraries_in_dot_dart
import 'package:web/web.dart' as web;

class CrossAuthView extends StatefulWidget {
  /// Parámetro propio (`?at=`) o estándar de Supabase (`?access_token=`)
  final String? accessToken;

  /// Parámetro propio (`?rt=`) o estándar de Supabase (`?refresh_token=`)
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
  @override
  void initState() {
    super.initState();
    _handleAuth();
  }

  Future<void> _handleAuth() async {
    // Leer la URL real del browser para capturar también los params estándar
    // que Supabase envía en el callback PKCE/Magic Link
    String? at = widget.accessToken;
    String? rt = widget.refreshToken;

    // Si no vienen por los parámetros del widget, buscarlos en la URL actual
    // Supabase puede enviarlos como ?access_token= o en el fragmento #access_token=
    if ((at == null || at.isEmpty)) {
      try {
        final currentHref = web.window.location.href;
        final currentUri = Uri.parse(currentHref);

        // Buscar en query params directos
        at ??= currentUri.queryParameters['access_token'];
        rt ??= currentUri.queryParameters['refresh_token'];

        // Buscar también en el fragmento (#access_token=...&refresh_token=...)
        if ((at == null || at.isEmpty) && currentUri.fragment.isNotEmpty) {
          final fragmentParams = Uri.splitQueryString(currentUri.fragment);
          at ??= fragmentParams['access_token'];
          rt ??= fragmentParams['refresh_token'];
        }
      } catch (e) {
        AppLogger.w('CrossAuthView: No se pudo leer la URL del browser: $e');
      }
    }

    // Caso 1: el SDK ya restauró la sesión automáticamente (detectSessionInUri)
    final existingSession = Supabase.instance.client.auth.currentSession;
    if (existingSession != null) {
      AppLogger.i('CrossAuthView: Sesión ya activa (detectSessionInUri). Redirigiendo...');
      _clearUrl();
      if (mounted) context.go(AppRoutes.dashboard);
      return;
    }

    // Caso 2: no hay sesión activa y no tenemos tokens → al login
    if (at == null || at.isEmpty) {
      AppLogger.w('CrossAuthView: No se encontró access_token en ningún origen');
      if (mounted) context.go(AppRoutes.login);
      return;
    }

    try {
      AppLogger.i('CrossAuthView: Estableciendo sesión con tokens recibidos...');
      await Supabase.instance.client.auth.setSession(at);
      AppLogger.i('CrossAuthView: Sesión establecida correctamente.');

      _clearUrl();
      if (mounted) context.go(AppRoutes.dashboard);
    } catch (e, st) {
      AppLogger.e('CrossAuthView: Error al establecer sesión cruzada', error: e, stackTrace: st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error de autenticación: $e')),
        );
        context.go(AppRoutes.login);
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
