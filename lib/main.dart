// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Directory, File, FileMode, InternetAddressType, NetworkInterface, Platform, Process, ProcessStartMode;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:auto_updater/auto_updater.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'app/router/app_router.dart';
import 'app/router/routes.dart';
import 'core/cache/cache_manager.dart';
import 'core/network/supabase_config.dart';
import 'core/agent/mobile_print_agent.dart';
import 'core/services/local_print_service.dart';
import 'core/utils/logger.dart';
import 'env/env.dart';

/// Global mobile print agent instance (Android/iOS only).
final MobilePrintAgent _mobileAgent = MobilePrintAgent();

const String agentHost = '127.0.0.1';

/// Escribe logs de diagnóstico a archivo junto al ejecutable.
/// Complementa el log nativo C++ (mangopos_startup.log) con info de Dart.
void _logToFile(String message) {
  try {
    if (kIsWeb) return;
    // Platform-aware home directory resolution
    final home = Platform.environment['USERPROFILE'] // Windows
        ?? Platform.environment['HOME']              // macOS / Linux
        ?? '';
    if (home.isEmpty) return;
    final logDir = Platform.isWindows
        ? p.join(home, 'Desktop')
        : home; // macOS/Linux: log in home dir instead of Desktop
    final logFile = File(p.join(logDir, 'mangopos_startup.log'));
    final timestamp = DateTime.now().toIso8601String().substring(0, 19);
    logFile.writeAsStringSync(
      '[$timestamp] [Dart] $message\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // Si no puede escribir el log, no romper la app
  }
}
const int agentPort = 4000;
bool _authRecoveryScheduled = false;
bool _authResetScheduled = false;
int _authRecoveryAttempts = 0;
const int _maxAuthRecoveryAttempts = 3;
DateTime? _lastTransientAuthLogAt;
String? _lastTransientAuthSignature;

/// Returns the first private IPv4 address (192.x / 10.x / 172.x) of this machine.
Future<String?> _getLocalIp() async {
  try {
    final ifaces = await NetworkInterface.list();
    for (final iface in ifaces) {
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (addr.type == InternetAddressType.IPv4 &&
            (ip.startsWith('192.') ||
                ip.startsWith('10.') ||
                ip.startsWith('172.'))) {
          return ip;
        }
      }
    }
  } catch (_) {}
  return null;
}

/// Publishes the agent URL (with LAN IP) to business_settings so tablets can find it.
Future<void> _publishAgentUrlToDb() async {
  try {
    final localIp = await _getLocalIp();
    if (localIp == null) {
      debugPrint('[Agent] Could not determine LAN IP — skipping URL publish.');
      return;
    }
    final agentUrl = 'http://$localIp:$agentPort';

    // Get the active business ID from the current user's membership
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;
    final membership = await Supabase.instance.client
        .from('business_members')
        .select('business_id')
        .eq('user_id', user.id)
        .limit(1)
        .maybeSingle();
    if (membership == null) return;
    final businessId = membership['business_id']?.toString();
    if (businessId == null || businessId.isEmpty) return;

    await LocalPrintService.publishAgentUrl(agentUrl, businessId);
    debugPrint('[Agent] Published agent URL: $agentUrl for business $businessId');
  } catch (e) {
    debugPrint('[Agent] Failed to publish agent URL: $e');
  }
}

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

  final agentBinaryName = Platform.isWindows
      ? 'mangopos-agent.exe'
      : 'mangopos-agent';

  final appDir = p.dirname(Platform.resolvedExecutable);

  // Platform-aware agent directory resolution
  final String agentDir;
  if (Platform.isMacOS) {
    // macOS .app bundle: Contents/MacOS/../Resources/Agent/
    agentDir = p.normalize(p.join(appDir, '..', 'Resources', 'Agent'));
  } else {
    // Windows/Linux: Agent/ folder alongside the executable
    agentDir = p.normalize(p.join(appDir, '..', 'Agent'));
  }

  final prodAgentPath = p.join(agentDir, agentBinaryName);
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
      LocalPrintService.primeBaseUrl('http://$agentHost:$agentPort');
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
      _logToFile('main() - WidgetsBinding initialized');
      _installGlobalErrorHandlers();
      await _bootstrapApp();
    },
    (error, stackTrace) {
      _logToFile('ZONE ERROR: $error\n$stackTrace');
      if (_isSupabaseAuthRefreshSchemaMismatch(error)) {
        _scheduleExpiredAuthReset(error, stackTrace);
        return;
      }

      if (_isTransientSupabaseAuthRefreshError(error)) {
        _scheduleExpiredAuthRecovery(error, stackTrace);
        if (_shouldLogTransientAuthError(error)) {
          AppLogger.w(
            'Supabase Auth devolvio un error transitorio de refresh. La app continuara mientras el backend se recupera.',
            error: error,
            stackTrace: stackTrace,
          );
        }
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
    _logToFile('_bootstrapApp() started');

    if (kIsWeb) usePathUrlStrategy();

    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      _logToFile('windowManager.ensureInitialized()...');
      await windowManager.ensureInitialized();
      await windowManager.setMinimumSize(const Size(800, 600));
      _logToFile('windowManager OK, min size set to 800x600');
    }

    _logToFile('initializeDateFormatting...');
    await initializeDateFormatting('es_DO', null);

    // ── Inicializar Supabase ANTES de montar la UI (requerido por auth/router) ──
    _logToFile('Supabase.initialize() -> ${Env.supabaseUrl}');
    await SupabaseConfig.initialize(
      url: Env.supabaseUrl,
      anonKey: Env.supabaseAnonKey,
    );
    _logToFile('Supabase OK');

    if (!kIsWeb) {
      try {
        _logToFile('MediaKit.ensureInitialized()...');
        MediaKit.ensureInitialized();
        _logToFile('MediaKit OK');
      } catch (e) {
        _logToFile('MediaKit init failed (non-fatal): $e');
      }
    }

    await _lockLandscapeIfMobile();

    // ── Montar la UI de inmediato para que la ventana aparezca ──
    _logToFile('runApp() - mounting UI...');
    runApp(const ProviderScope(child: MyApp()));
    _logToFile('runApp() done - UI mounted, waiting for first frame');

    // ── Inicialización pesada DESPUÉS del primer frame ──
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _logToFile('First frame rendered - starting background services');
      _initializeBackgroundServices();
    });
  } catch (e, st) {
    _logToFile('FATAL ERROR in _bootstrapApp: $e\n$st');
    AppLogger.f(
      'Error FATAL durante la inicializacion de la app',
      error: e,
      stackTrace: st,
    );
    rethrow;
  }
}

/// Servicios que no necesitan bloquear el arranque de la UI.
Future<void> _initializeBackgroundServices() async {
  try {
    // Auto-updater
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows)) {
      try {
        const feedURL = 'https://mangopos.com/appcast.xml';
        await autoUpdater.setFeedURL(feedURL);
        await autoUpdater.setScheduledCheckInterval(3600);
        unawaited(
          autoUpdater.checkForUpdates(inBackground: true).catchError((e) {
            AppLogger.w('Auto-update check falló', error: e);
          }),
        );
        AppLogger.d('AutoUpdater inicializado con feed: $feedURL');
      } catch (e) {
        AppLogger.w('AutoUpdater no soportado en esta compilación', error: e);
      }
    }

    // Printer agent
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      // Mobile: start the built-in Dart agent
      final agentUrl = await _mobileAgent.start(port: agentPort);
      if (agentUrl != null) {
        LocalPrintService.primeBaseUrl(agentUrl);
        debugPrint('[Agent] Mobile agent running at $agentUrl');
        unawaited(_publishAgentUrlToDb());
      }
    } else if (!kIsWeb) {
      // Desktop: launch the Node.js agent (puede tardar hasta 8s con los pings)
      await _ensurePrinterAgentStarted();
      LocalPrintService.primeBaseUrl('http://$agentHost:$agentPort');
      unawaited(_publishAgentUrlToDb());
    }
    unawaited(LocalPrintService().warmup());

    // Cache
    await CacheManager.initialize();
    AppLogger.d('CacheManager inicializado');

    AppLogger.i('Servicios en background inicializados correctamente.');
  } catch (e, st) {
    AppLogger.e(
      'Error inicializando servicios en background',
      error: e,
      stackTrace: st,
    );
  }
}

void _installGlobalErrorHandlers() {
  FlutterError.onError = (details) {
    if (_isSupabaseAuthRefreshSchemaMismatch(details.exception)) {
      _scheduleExpiredAuthReset(details.exception, details.stack);
      return;
    }

    if (_isTransientSupabaseAuthRefreshError(details.exception)) {
      _scheduleExpiredAuthRecovery(details.exception, details.stack);
      if (_shouldLogTransientAuthError(details.exception)) {
        AppLogger.w(
          'FlutterError recuperable de Supabase Auth refresh.',
          error: details.exception,
          stackTrace: details.stack,
        );
      }
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
    if (_isSupabaseAuthRefreshSchemaMismatch(error)) {
      _scheduleExpiredAuthReset(error, stackTrace);
      return true;
    }

    if (_isTransientSupabaseAuthRefreshError(error)) {
      _scheduleExpiredAuthRecovery(error, stackTrace);
      if (_shouldLogTransientAuthError(error)) {
        AppLogger.w(
          'PlatformDispatcher capturo un error transitorio de Supabase Auth refresh.',
          error: error,
          stackTrace: stackTrace,
        );
      }
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

bool _isSupabaseAuthRefreshSchemaMismatch(Object error) {
  return SupabaseConfig.isAuthRefreshSchemaMismatchError(error);
}

bool _isTransientSupabaseAuthRefreshError(Object error) {
  return SupabaseConfig.isTransientAuthRefreshError(error);
}

bool _shouldLogTransientAuthError(Object error) {
  final now = DateTime.now();
  final signature = error.toString();
  final shouldLog =
      _lastTransientAuthSignature != signature ||
      _lastTransientAuthLogAt == null ||
      now.difference(_lastTransientAuthLogAt!) > const Duration(seconds: 45);

  if (shouldLog) {
    _lastTransientAuthSignature = signature;
    _lastTransientAuthLogAt = now;
  }

  return shouldLog;
}

void _scheduleExpiredAuthReset(Object error, StackTrace? stackTrace) {
  if (_authResetScheduled) return;

  final auth = Supabase.instance.client.auth;
  if (auth.currentSession == null) {
    return;
  }

  _authResetScheduled = true;
  Future<void>.microtask(() async {
    try {
      if (_shouldLogTransientAuthError(error)) {
        AppLogger.e(
          'Supabase Auth no pudo refrescar la sesion por una incompatibilidad del backend. Se limpiara la sesion local y se enviara al usuario al login.',
          error: error,
          stackTrace: stackTrace,
        );
      }

      await auth.signOut(scope: SignOutScope.local);
    } catch (resetError, resetStack) {
      AppLogger.e(
        'No se pudo limpiar la sesion local tras un fallo de refresh incompatible.',
        error: resetError,
        stackTrace: resetStack,
      );
    } finally {
      _authRecoveryAttempts = 0;
      _authRecoveryScheduled = false;
      _authResetScheduled = false;
      AppRouter.router.go(AppRoutes.login);
    }
  });
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
      _authRecoveryAttempts += 1;
      final retryDelay = Duration(
        seconds: _authRecoveryAttempts <= 1 ? 2 : (_authRecoveryAttempts * 4),
      );

      if (_shouldLogTransientAuthError(error)) {
        AppLogger.w(
          'La sesion expiro y el refresh fallo. Intentando recuperar la sesion sin cerrar al usuario. Intento $_authRecoveryAttempts/$_maxAuthRecoveryAttempts en ${retryDelay.inSeconds}s.',
          error: error,
          stackTrace: stackTrace,
        );
      }

      await Future.delayed(retryDelay);

      final latestSession = auth.currentSession;
      final latestAccessToken = latestSession?.accessToken;
      if (latestAccessToken != null && !_isJwtExpired(latestAccessToken)) {
        _authRecoveryAttempts = 0;
        return;
      }

      final refreshToken = latestSession?.refreshToken;
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await auth.refreshSession(refreshToken);
      }

      final recoveredSession = auth.currentSession;
      final recoveredAccessToken = recoveredSession?.accessToken;
      final recovered =
          recoveredAccessToken != null && !_isJwtExpired(recoveredAccessToken);

      if (recovered) {
        _authRecoveryAttempts = 0;
        AppLogger.i(
          'Sesion recuperada correctamente tras refresh fallido transitorio.',
        );
        return;
      }

      if (_authRecoveryAttempts < _maxAuthRecoveryAttempts) {
        if (_shouldLogTransientAuthError(error)) {
          AppLogger.w(
            'No se pudo recuperar la sesion en este intento. Se mantendra la app activa y se reintentara con backoff.',
          );
        }
        return;
      }

      final latestRefreshToken = auth.currentSession?.refreshToken;
      if (latestRefreshToken != null && latestRefreshToken.isNotEmpty) {
        AppLogger.e(
          'No se pudo recuperar la sesion tras $_authRecoveryAttempts intentos, pero el refresh token sigue presente. Se conservara la sesion local y se volvera a intentar cuando Supabase responda.',
          error: error,
          stackTrace: stackTrace,
        );
        _authRecoveryAttempts = 0;
        return;
      }

      AppLogger.e(
        'No se pudo recuperar la sesion tras $_authRecoveryAttempts intentos y ya no hay refresh token usable. Cerrando sesion local como ultimo recurso.',
        error: error,
        stackTrace: stackTrace,
      );
      await auth.signOut(scope: SignOutScope.local);
      AppRouter.router.go(AppRoutes.login);
      _authRecoveryAttempts = 0;
    } catch (recoveryError, recoveryStack) {
      if (_shouldLogTransientAuthError(recoveryError)) {
        AppLogger.e(
          'Fallo el intento de recuperar la sesion expirada.',
          error: recoveryError,
          stackTrace: recoveryStack,
        );
      }

      if (_authRecoveryAttempts >= _maxAuthRecoveryAttempts) {
        final latestRefreshToken = auth.currentSession?.refreshToken;
        if (latestRefreshToken != null && latestRefreshToken.isNotEmpty) {
          _authRecoveryAttempts = 0;
          return;
        }

        try {
          await auth.signOut(scope: SignOutScope.local);
        } catch (signOutError, signOutStack) {
          AppLogger.e(
            'No se pudo completar el logout local tras fallo repetido de recovery.',
            error: signOutError,
            stackTrace: signOutStack,
          );
        }
        AppRouter.router.go(AppRoutes.login);
        _authRecoveryAttempts = 0;
      }
    } finally {
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
