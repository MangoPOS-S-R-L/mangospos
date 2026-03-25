import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/core/utils/logger.dart';

// ignore: avoid_web_libraries_in_dot_dart
import 'package:web/web.dart' as web;

class CrossAuthView extends StatefulWidget {
  final String? accessToken;
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
    final at = widget.accessToken;
    final rt = widget.refreshToken;

    if (at == null || at.isEmpty) {
      AppLogger.w('CrossAuthView: No se encontró access_token');
      if (mounted) context.go(AppRoutes.login);
      return;
    }

    try {
      AppLogger.i('CrossAuthView: Iniciando sesión con tokens externos...');
      
      if (rt != null) {
        // En versiones modernas de Supabase, recoverSession es ideal si hay refresh_token.
        // Pero para ser paritarios con la lógica del usuario, intentaremos setSession.
        await Supabase.instance.client.auth.setSession(at);
      } else {
        await Supabase.instance.client.auth.setSession(at);
      }
      
      AppLogger.i('CrossAuthView: Sesión establecida correctamente.');

      // Limpiar URL (solo en Web)
      _clearUrl();

      if (mounted) {
        context.go(AppRoutes.dashboard);
      }
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
      // Usando package:web para manipular el historial del browser
      final currentUri = Uri.parse(web.window.location.href);
      // Extraer solo la parte base antes del fragmento o simplemente limpiar parametros
      final newUrl = '${currentUri.scheme}://${currentUri.host}${currentUri.port != 80 && currentUri.port != 443 ? ":${currentUri.port}" : ""}/#/';
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
