import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/app/router/routes.dart';

import 'package:mangopos/core/utils/web_utils/web_utils.dart';

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
  final List<String> _logs = [];

  void _addLog(String msg) {
    print('[MangoPOS:CrossAuth] $msg');
    if (mounted) {
      setState(() {
        _logs.add(msg);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _handleAuth();
  }

  Future<void> _handleAuth() async {
    _addLog('_handleAuth() INICIADO');

    String? at = widget.accessToken;
    String? rt = widget.refreshToken;

    _addLog('PARAMS WIDGET: at=${at != null ? "[recibido: ${at.length} chars]" : "NULL"}, rt=${rt != null ? "[recibido]" : "NULL"}');

    if (at == null || at.isEmpty) {
      try {
        final href = WebUtils.href;
        _addLog('URL BROWSER: $href');
        final uri = Uri.parse(href);

        at ??= uri.queryParameters['at'];
        rt ??= uri.queryParameters['rt'];
        _addLog('Búsqueda QueryParams (antes de #): at=${at != null ? "ENCONTRADO" : "NO"}, rt=${rt != null ? "ENCONTRADO" : "NO"}');

        if ((at == null || at.isEmpty) && uri.fragment.contains('?')) {
          final fragParams = Uri.splitQueryString(uri.fragment.split('?').last);
          at ??= fragParams['at'] ?? fragParams['access_token'];
          rt ??= fragParams['rt'] ?? fragParams['refresh_token'];
          _addLog('Búsqueda Hash Fragment (después de #): at=${at != null ? "ENCONTRADO" : "NO"}');
        }
      } catch (e) {
        _addLog('ERROR LEYENDO URL: $e');
      }
    }

    final existingSession = Supabase.instance.client.auth.currentSession;
    _addLog('SESIÓN EXISTENTE: ${existingSession != null ? "ACTIVA (uid=${existingSession.user.id})" : "Nula"}');

    if (existingSession != null) {
      _addLog('OK -> SESIÓN ACTIVA CONFIRMADA. Vamos a dashboard en 2 seg...');
      await Future.delayed(const Duration(seconds: 2));
      _clearUrl();
      if (mounted) context.go(AppRoutes.dashboard);
      return;
    }

    if (rt == null || rt.isEmpty) {
      _addLog('CRÍTICO -> NO HAY REFRESH TOKEN (rt) EN NINGÚN LADO.');
      _addLog('Mandando a LOGIN en 3 seg...');
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) context.go(AppRoutes.login);
      return;
    }

    try {
      _addLog('CONSTRUYENDO SESIÓN VIA GET-USER (... ESPERANDO SUPABASE...)');
      // La API REST rejecta el refresh_token si ya fue "consumido" o es de otro subdominio rápido.
      // Usaremos getSessionFromUrl que reconstruye la sesión validando el access_token 
      // contra /auth/v1/user directamente y guarda la sesión localmente sin gastar el refresh loop inicial.
      
      final authUri = Uri.parse(
        'http://localhost/#access_token=$at&refresh_token=$rt&expires_in=3600&token_type=bearer&type=magiclink'
      );
      
      await Supabase.instance.client.auth.getSessionFromUrl(authUri);
      _addLog('SETSESSION EXITOSO! Redirigiendo a dashboard en 2 seg...');
      
      await Future.delayed(const Duration(seconds: 2));
      _clearUrl();
      if (mounted) context.go(AppRoutes.dashboard);
    } catch (e) {
      _addLog('ERROR EN SETSESSION: $e');
      _addLog('Probablemente el access_token expiró o es inválido.');
    }
  }

  void _clearUrl() {
    try {
      final currentUri = Uri.parse(WebUtils.href);
      final newUrl =
          '${currentUri.scheme}://${currentUri.host}'
          '${currentUri.port != 80 && currentUri.port != 443 ? ":${currentUri.port}" : ""}/#/';
      WebUtils.replaceState(null, '', newUrl);
    } catch (e) {
      _addLog('Error ocultando URL: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text('DEBUG CROSS-AUTH'), backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Logs del flujo de Autenticación:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Divider(),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                color: Colors.black87,
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (c, i) => Text(
                    '> ${_logs[i]}',
                    style: const TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => context.go(AppRoutes.login),
              child: const Text('FORZAR IR AL LOGIN'),
            ),
          ],
        ),
      ),
    );
  }
}

