// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform, Process, ProcessStartMode;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'app/router/app_router.dart';
import 'app/router/routes.dart';
import 'core/cache/cache_manager.dart';
import 'core/network/supabase_config.dart';
import 'core/utils/logger.dart';
import 'env/env.dart';

const String agentHost = '127.0.0.1';
const int agentPort = 4000;
bool _authRecoveryScheduled = false;

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

Future<void> _ensurePrinterAgentStarted() async {
  if (await _pingAgentOnce()) {
    debugPrint('[Agent] Ya esta activo en http://$agentHost:$agentPort');
    return;
  }

  if (kIsWeb) {
    debugPrint('[Agent] Web: no se puede iniciar proceso local.');
    return;
  }

  String exec;
  List<String> args;
  String workingDir;

  final appDir = p.dirname(Platform.resolvedExecutable);
  final prodAgentPath = p.normalize(
    p.join(appDir, '..', 'Agent', 'mangopos-agent.exe'),
  );
  final hasProdAgent = File(prodAgentPath).existsSync();

  if (hasProdAgent) {
    exec = prodAgentPath;
    args = [];
    workingDir = p.dirname(prodAgentPath);
    debugPrint('[Agent] Detectado agente en produccion: $exec');
  } else {
    workingDir = p.normalize(p.join(Directory.current.path, 'agent'));
    exec = 'node';
    args = ['src/index.js'];

    if (!Directory(workingDir).existsSync()) {
      debugPrint(
        '[Agent] Error: No se encontro la carpeta del agente en $workingDir',
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
      mode: ProcessStartMode.detached,
    );
  } catch (e) {
    debugPrint('[Agent] Error al iniciar el agente: $e');
  }

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
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
}

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      _installGlobalErrorHandlers();
      await _bootstrapApp();
    },
    (error, stackTrace) {
      if (_isTransientSupabaseAuthRefreshError(error)) {
        _scheduleExpiredAuthRecovery(error, stackTrace);
        AppLogger.w(
          'Supabase Auth devolvio un error transitorio de refresh. La app continuara mientras el backend se recupera.',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }

      AppLogger.f(
        'Error FATAL no controlado',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}

Future<void> _bootstrapApp() async {
  try {
    AppLogger.i('Arrancando MangoPOS...');

    if (kIsWeb) usePathUrlStrategy();

    if (!kIsWeb && Platform.isWindows) {
      await windowManager.ensureInitialized();
    }

    await initializeDateFormatting('es_DO', null);
    AppLogger.d('Localizacion (es_DO) inicializada');

    await SupabaseConfig.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseAnonKey,
    );
    AppLogger.i(
      'Supabase inicializado correctamente conectando a: ${Env.supabaseUrl}',
    );

    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.windows) {
      MediaKit.ensureInitialized();
      AppLogger.d('MediaKit inicializado');
    } else {
      AppLogger.d('MediaKit omitido en esta plataforma');
    }

    await _lockLandscapeIfMobile();
    await _ensurePrinterAgentStarted();
    await CacheManager.initialize();
    AppLogger.d('CacheManager inicializado');

    AppLogger.i('MangoPOS inicializacion completa. Montando UI.');
    runApp(const ProviderScope(child: MyApp()));
  } catch (e, st) {
    AppLogger.f(
      'Error FATAL durante la inicializacion de la app',
      error: e,
      stackTrace: st,
    );
    rethrow;
  }
}

void _installGlobalErrorHandlers() {
  FlutterError.onError = (details) {
    if (_isTransientSupabaseAuthRefreshError(details.exception)) {
      _scheduleExpiredAuthRecovery(details.exception, details.stack);
      AppLogger.w(
        'FlutterError recuperable de Supabase Auth refresh.',
        error: details.exception,
        stackTrace: details.stack,
      );
      return;
    }

    FlutterError.presentError(details);
    AppLogger.e(
      'FlutterError no controlado',
      error: details.exception,
      stackTrace: details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    if (_isTransientSupabaseAuthRefreshError(error)) {
      _scheduleExpiredAuthRecovery(error, stackTrace);
      AppLogger.w(
        'PlatformDispatcher capturo un error transitorio de Supabase Auth refresh.',
        error: error,
        stackTrace: stackTrace,
      );
      return true;
    }

    AppLogger.e(
      'Error asincrono no controlado',
      error: error,
      stackTrace: stackTrace,
    );
    return false;
  };
}

bool _isTransientSupabaseAuthRefreshError(Object error) {
  final message = error.toString();
  if (!message.contains('AuthRetryableFetchException')) {
    return false;
  }

  return message.contains('missing destination name oauth_client_id') ||
      message.contains('Bad Gateway') ||
      message.contains('statusCode: 500') ||
      message.contains('statusCode: 502');
}

void _scheduleExpiredAuthRecovery(Object error, StackTrace? stackTrace) {
  if (_authRecoveryScheduled) return;

  final auth = Supabase.instance.client.auth;
  final session = auth.currentSession;
  final accessToken = session?.accessToken;
  if (accessToken == null || !_isJwtExpired(accessToken)) {
    return;
  }

  _authRecoveryScheduled = true;
  Future<void>.microtask(() async {
    try {
      AppLogger.w(
        'La sesion expiro y el refresh fallo. Cerrando sesion local para evitar requests abortados en cascada.',
        error: error,
        stackTrace: stackTrace,
      );
      await auth.signOut(scope: SignOutScope.local);
    } catch (signOutError, signOutStack) {
      AppLogger.e(
        'No se pudo completar el logout local tras fallo de refresh.',
        error: signOutError,
        stackTrace: signOutStack,
      );
    } finally {
      AppRouter.router.go(AppRoutes.login);
      _authRecoveryScheduled = false;
    }
  });
}

bool _isJwtExpired(String accessToken) {
  try {
    final parts = accessToken.split('.');
    if (parts.length < 2) return false;

    final payload =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
            as Map<String, dynamic>;
    final exp = payload['exp'];
    if (exp is! num) return false;

    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return exp.toInt() <= nowSeconds;
  } catch (_) {
    return false;
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
