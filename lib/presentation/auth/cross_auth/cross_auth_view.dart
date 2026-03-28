import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/core/auth/session_bridge.dart';
import 'package:mangopos/core/utils/web_utils/web_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CrossAuthView extends StatefulWidget {
  final String? accessToken;
  final String? refreshToken;

  const CrossAuthView({super.key, this.accessToken, this.refreshToken});

  @override
  State<CrossAuthView> createState() => _CrossAuthViewState();
}

class _CrossAuthViewState extends State<CrossAuthView> {
  final List<String> _logs = [];

  void _addLog(String msg) {
    debugPrint('[MangoPOS:CrossAuth] $msg');
    if (!mounted) return;
    setState(() => _logs.add(msg));
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

    _addLog(
      'PARAMS WIDGET: at=${at != null ? "[recibido: ${at.length} chars]" : "NULL"}, rt=${rt != null ? "[recibido]" : "NULL"}',
    );

    if (at == null || at.isEmpty) {
      try {
        final href = WebUtils.href;
        _addLog('URL BROWSER: $href');
        final uri = Uri.parse(href);

        at ??= uri.queryParameters['at'];
        rt ??= uri.queryParameters['rt'];
        _addLog(
          'Busqueda QueryParams (antes de #): at=${at != null ? "ENCONTRADO" : "NO"}, rt=${rt != null ? "ENCONTRADO" : "NO"}',
        );

        if ((at == null || at.isEmpty) && uri.fragment.contains('?')) {
          final fragParams = Uri.splitQueryString(uri.fragment.split('?').last);
          at ??= fragParams['at'] ?? fragParams['access_token'];
          rt ??= fragParams['rt'] ?? fragParams['refresh_token'];
          _addLog(
            'Busqueda Hash Fragment (despues de #): at=${at != null ? "ENCONTRADO" : "NO"}',
          );
        }
      } catch (e) {
        _addLog('ERROR LEYENDO URL: $e');
      }
    }

    final existingSession = Supabase.instance.client.auth.currentSession;
    _addLog(
      'SESION EXISTENTE: ${existingSession != null ? "ACTIVA (uid=${existingSession.user.id})" : "Nula"}',
    );

    if (existingSession != null) {
      _addLog('OK -> SESION ACTIVA CONFIRMADA. Vamos a dashboard en 2 seg...');
      await Future.delayed(const Duration(seconds: 2));
      _clearUrl();
      if (mounted) context.go(AppRoutes.dashboard);
      return;
    }

    if (at == null || at.isEmpty || rt == null || rt.isEmpty) {
      _addLog('CRITICO -> NO HAY TOKENS SUFICIENTES EN LA URL.');
      _addLog('Mandando a LOGIN en 3 seg...');
      await Future.delayed(const Duration(seconds: 3));
      if (mounted) context.go(AppRoutes.login);
      return;
    }

    try {
      _addLog(
        'RESTAURANDO SESION DESDE ACCESS TOKEN (... ESPERANDO SUPABASE...)',
      );
      final restored = await SessionBridge.restoreFromTokens(
        accessToken: at,
        refreshToken: rt,
      );
      if (!restored) {
        throw Exception(
          'No se pudo reconstruir la sesion desde los tokens recibidos.',
        );
      }

      _addLog('SESION RESTAURADA! Redirigiendo a dashboard en 2 seg...');
      await Future.delayed(const Duration(seconds: 2));
      _clearUrl();
      if (mounted) context.go(AppRoutes.dashboard);
    } catch (e) {
      _addLog('ERROR RESTAURANDO SESION: $e');
      _addLog('Probablemente el access_token expiro o es invalido.');
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
      appBar: AppBar(
        title: const Text('DEBUG CROSS-AUTH'),
        backgroundColor: Colors.redAccent,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Logs del flujo de Autenticacion:',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const Divider(),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                color: Colors.black87,
                child: ListView.builder(
                  itemCount: _logs.length,
                  itemBuilder: (c, i) => Text(
                    '> ${_logs[i]}',
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
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
