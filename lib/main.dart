// lib/main.dart
import 'dart:async';
import 'dart:io' show Platform, Process, File, Directory, ProcessStartMode;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // <-- NECESARIO para bloquear orientacion
import 'package:path/path.dart'
    as p; // Necesitas agregar path a pubspec.yaml si no está
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'env/env.dart';
import 'app/router/app_router.dart';
import 'core/network/supabase_config.dart';
import 'core/cache/cache_manager.dart';
import 'core/utils/logger.dart';
import 'core/auth/session_bridge.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_web_plugins/url_strategy.dart';

/// === CONFIG DEL AGENTE ===
const String agentHost = '127.0.0.1';
const int agentPort =
    4000; // El agente local corre en 4000 por defecto en index.js

Future<bool> _pingAgentOnce({
  Duration timeout = const Duration(milliseconds: 1000),
}) async {
  final uri = Uri.parse('http://$agentHost:$agentPort/health');
  try {
    final r = await http.get(uri).timeout(timeout);
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
}

/// Intenta arrancar el agente (solo desktop). En Web no se puede.
Future<void> _ensurePrinterAgentStarted() async {
  // 1) Si ya esta arriba, listo.
  if (await _pingAgentOnce()) {
    debugPrint('[Agent] Ya esta activo en http://$agentHost:$agentPort');
    return;
  }

  if (kIsWeb) {
    debugPrint('[Agent] Web: no se puede iniciar proceso local.');
    return;
  }

  // 2) Desktop: intentar localizar el agente
  String exec;
  List<String> args;
  String workingDir;

  // Ruta base de la aplicación (donde está el .exe de Flutter)
  final String appDir = p.dirname(Platform.resolvedExecutable);

  // Ruta esperada del agente en PRODUCCIÓN: ../Agent/mangopos-agent.exe
  final String prodAgentPath = p.normalize(
    p.join(appDir, '..', 'Agent', 'mangopos-agent.exe'),
  );
  final bool hasProdAgent = File(prodAgentPath).existsSync();

  if (hasProdAgent) {
    // MODO PRODUCCIÓN (Instalador)
    exec = prodAgentPath;
    args = [];
    workingDir = p.dirname(prodAgentPath);
    debugPrint('[Agent] Detectado agente en producción: $exec');
  } else {
    // MODO DESARROLLO (Vscode/Android Studio)
    // Buscamos la carpeta /agent relativa al proyecto
    // Asumimos que estamos corriendo desde el root del proyecto
    workingDir = p.normalize(p.join(Directory.current.path, 'agent'));

    if (Platform.isWindows) {
      exec = 'node';
      args = ['src/index.js'];
    } else {
      exec = 'node';
      args = ['src/index.js'];
    }

    if (!Directory(workingDir).existsSync()) {
      debugPrint(
        '[Agent] Error: No se encontró la carpeta del agente en $workingDir',
      );
      return;
    }
    debugPrint('[Agent] Usando modo desarrollo (node src/index.js)');
  }

  try {
    debugPrint('[Agent] Lanzando: $exec ${args.join(' ')} (wd: $workingDir)');
    await Process.start(
      exec,
      args,
      workingDirectory: workingDir,
      runInShell: true,
      mode: ProcessStartMode
          .detached, // Para que el agente siga vivo si la app se reinicia en hot reload
    );
  } catch (e) {
    debugPrint('[Agent] Error al iniciar el agente: $e');
  }

  // 3) Esperar a que responda /health (retry loop)
  for (int i = 0; i < 10; i++) {
    await Future.delayed(const Duration(milliseconds: 800));
    if (await _pingAgentOnce()) {
      debugPrint('[Agent] Arrancado correctamente.');
      return;
    }
  }
  debugPrint(
    '[Agent] No se pudo confirmar el arranque del agente. Revisa logs o puerto ocupado.',
  );
}

Future<void> _lockLandscapeIfMobile() async {
  // Bloquea SOLO en Android/iOS. No afecta Web ni Desktop.
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
}

void main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    AppLogger.i('Arrancando MangoPOS...');

    // Usar path-based routing en web (sin # en la URL)
    if (kIsWeb) usePathUrlStrategy();

    if (!kIsWeb && Platform.isWindows) {
      await windowManager.ensureInitialized();
    }

    // Inicializar datos de localización para español
    await initializeDateFormatting('es', null);
    AppLogger.d('Localización (es) inicializada');

    // Inicializar Supabase con configuración personalizada
    await SupabaseConfig.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseAnonKey,
    );
    AppLogger.i(
      'Supabase inicializado correctamente conectando a: ${Env.supabaseUrl}',
    );

    // Si estamos en un subdominio tenant (*.mangopos.do) y la URL trae tokens
    // de una redirección desde app.mangopos.do, los consumimos aquí antes de
    // montar la UI para que el router ya vea la sesión activa.
    await SessionBridge.handleIncoming();

    MediaKit.ensureInitialized();
    AppLogger.d('MediaKit inicializado');

    // Bloquear orientacion a horizontal (Android/iOS)
    await _lockLandscapeIfMobile();

    // Arranca o "precalienta" el agente ANTES de montar el arbol de widgets
    await _ensurePrinterAgentStarted();

    // Inicializar CacheManager
    await CacheManager.initialize();
    AppLogger.d('CacheManager inicializado');

    AppLogger.i('MangoPOS inicialización completa. Montando UI.');
    runApp(const ProviderScope(child: MyApp()));
  } catch (e, st) {
    AppLogger.f(
      'Error FATAL durante la inicialización de la app',
      error: e,
      stackTrace: st,
    );
    rethrow;
  }
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'MangoPOS',
      debugShowCheckedModeBanner: false,
      routerConfig: AppRouter.router,
      theme: ThemeData(primaryColor: const Color(0xFFF97316)),
    );
  }
}
