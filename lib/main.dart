// lib/main.dart
import 'dart:async';
import 'dart:io' show Platform, Process;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // <-- NECESARIO para bloquear orientacion
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:media_kit/media_kit.dart';

import 'env/env.dart';
import 'app/router/app_router.dart';
import 'core/network/supabase_config.dart';
import 'core/cache/cache_manager.dart';
import 'core/utils/logger.dart';

/// === CONFIG DEL AGENTE ===
/// Cambia estas rutas/puerto segun tu instalacion.
const String agentHost = '127.0.0.1';
const int agentPort = 3000;

/// Si usas Node:
///   - executable: 'node'
///   - args: ['agent.js']
const String agentExecutableWindows = 'node'; // o 'printer-service.exe'
// Usa el agente local de MangoPOS (puerto 4000) ubicado en /agent/src/index.js
const List<String> agentArgsWindows = ['src/index.js']; // [] si usas .exe
const String agentWorkingDirWindows = r'D:\MangoPos\Dev\mangopos\agent';

const String agentExecutableMac = 'node'; // o './printer-service'
const List<String> agentArgsMac = ['agent.js']; // [] si usas binario
const String agentWorkingDirMac = '/Users/tu-usuario/MangoPos/printer-service';

const String agentExecutableLinux = 'node'; // o './printer-service'
const List<String> agentArgsLinux = ['agent.js']; // [] si usas binario
const String agentWorkingDirLinux = '/home/tu-usuario/MangoPos/printer-service';

Future<bool> _pingAgentOnce({
  Duration timeout = const Duration(milliseconds: 800),
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
    // ignore: avoid_print
    print('[Agent] Ya esta activo en http://$agentHost:$agentPort');
    return;
  }

  if (kIsWeb) {
    // En Web no podemos lanzar procesos. Solo "precalienta" con varios /health.
    // ignore: avoid_print
    print(
      '[Agent] Web: no se puede iniciar proceso; intentando precalentar /health...',
    );
    for (int i = 0; i < 4; i++) {
      await Future.delayed(const Duration(milliseconds: 350));
      if (await _pingAgentOnce(timeout: const Duration(milliseconds: 900))) {
        // ignore: avoid_print
        print('[Agent] Web: /health OK');
        return;
      }
    }
    // ignore: avoid_print
    print(
      '[Agent] Web: no respondio /health; asegurate de correr el agente como servicio.',
    );
    return;
  }

  // 2) Desktop: intenta iniciar el agente localmente.
  String exec;
  List<String> args;
  String workingDir;

  if (Platform.isWindows) {
    exec = agentExecutableWindows;
    args = List<String>.from(agentArgsWindows);
    workingDir = agentWorkingDirWindows;
  } else if (Platform.isMacOS) {
    exec = agentExecutableMac;
    args = List<String>.from(agentArgsMac);
    workingDir = agentWorkingDirMac;
  } else if (Platform.isLinux) {
    exec = agentExecutableLinux;
    args = List<String>.from(agentArgsLinux);
    workingDir = agentWorkingDirLinux;
  } else {
    // Otras plataformas: no hacer nada
    return;
  }

  try {
    // ignore: avoid_print
    print(
      '[Agent] Iniciando agente: $exec ${args.join(' ')}  (wd: $workingDir)',
    );
    // runInShell:true permite resolver 'node' desde PATH en Windows.
    await Process.start(
      exec,
      args,
      workingDirectory: workingDir,
      runInShell: true,
    );
  } catch (e) {
    // ignore: avoid_print
    print('[Agent] Error al iniciar el agente: $e');
    // No devuelvas error para no bloquear la app; seguiremos intentando health abajo.
  }

  // 3) Esperar a que responda /health (retry loop corto).
  for (int i = 0; i < 12; i++) {
    await Future.delayed(const Duration(milliseconds: 700));
    if (await _pingAgentOnce(timeout: const Duration(milliseconds: 1000))) {
      // ignore: avoid_print
      print('[Agent] Arrancado correctamente. http://$agentHost:$agentPort');
      return;
    }
  }
  // ignore: avoid_print
  print(
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
