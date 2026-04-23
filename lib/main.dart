// lib/main.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        Directory,
        File,
        FileMode,
        InternetAddressType,
        NetworkInterface,
        Platform,
        Process,
        ProcessStartMode,
        stderr;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:auto_updater/auto_updater.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

/// Escribe logs de diagnóstico a archivo.
///
/// Nota: el runner nativo (C++) escribe `mangopos_startup.log` y mantiene el
/// archivo abierto, lo que en Windows puede bloquear escrituras simultáneas.
/// Por eso el log de Dart usa un archivo separado: `mangopos_dart.log`.
void _logToFile(String message) {
  try {
    if (kIsWeb) return;

    String? pickExistingDir(List<String?> candidates) {
      for (final dir in candidates) {
        if (dir == null || dir.trim().isEmpty) continue;
        try {
          if (Directory(dir).existsSync()) return dir;
        } catch (_) {}
      }
      return null;
    }

    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    final oneDrive = Platform.environment['OneDrive'];
    final temp = Platform.environment['TEMP'] ?? Platform.environment['TMP'];

    final logDir = Platform.isWindows
        ? pickExistingDir([
            if (home != null) p.join(home, 'Desktop'),
            if (oneDrive != null) p.join(oneDrive, 'Desktop'),
            temp,
            home,
          ])
        : pickExistingDir([home, temp]);

    if (logDir == null) return;
    final logFile = File(p.join(logDir, 'mangopos_dart.log'));
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

/// Log a mensaje a la consola (cuando exista), para que `flutter run` muestre
/// la causa del cierre/crash durante debug.
void _logToConsole(String message) {
  try {
    if (kIsWeb) return;
    if (!kDebugMode) return;
    final timestamp = DateTime.now().toIso8601String().substring(0, 19);
    // Usar stderr para que aparezca incluso si stdout es filtrado.
    stderr.writeln('[$timestamp] [MangoPOS] $message');
  } catch (_) {
    // No romper por logging
  }
}

void _logCritical(String message, {Object? error, StackTrace? stackTrace}) {
  final details = <String>[message];
  if (error != null) details.add('error=$error');
  if (stackTrace != null) details.add('stack=$stackTrace');
  final line = details.join(' | ');
  _logToFile(line);
  _logToConsole(line);
}

void _logStep(String message) {
  // Step-level logs: útiles para saber el último punto antes de un crash nativo.
  _logToFile(message);
  _logToConsole(message);
}

const int agentPort = 4000;
bool _authRecoveryScheduled = false;
bool _authResetScheduled = false;
bool _startupUiMounted = false;
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
    debugPrint(
      '[Agent] Published agent URL: $agentUrl for business $businessId',
    );
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

/// Detecta si `shared_preferences.json` está corrupto y lo elimina para que el
/// siguiente `SharedPreferences.getInstance()` lo regenere vacío.
///
/// `shared_preferences_windows` hace `json.decode(readAsStringSync())` sin
/// try/catch, así que si el archivo tiene bytes no-JSON (corrupción de disco,
/// antivirus, interrupción de escritura) tira un `FormatException` que sube
/// hasta `Supabase.initialize` y tumba el arranque de la app.
Future<void> _purgeCorruptSharedPreferencesIfNeeded() async {
  if (kIsWeb) return;

  try {
    await SharedPreferences.getInstance();
    return;
  } on FormatException catch (e) {
    _logStep('shared_preferences corrupto detectado (FormatException): $e');
  } catch (e) {
    _logStep('SharedPreferences.getInstance error no-Format: $e');
    return;
  }

  String? deletedPath;
  try {
    final supportDir = await getApplicationSupportDirectory();
    final file = File(p.join(supportDir.path, 'shared_preferences.json'));
    if (file.existsSync()) {
      file.deleteSync();
      deletedPath = file.path;
    }
  } catch (e) {
    _logStep('No se pudo borrar shared_preferences.json via path_provider: $e');
  }

  if (deletedPath == null && Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null) {
      try {
        final fallback = File(
          p.join(appData, 'com.example', 'mangopos', 'shared_preferences.json'),
        );
        if (fallback.existsSync()) {
          fallback.deleteSync();
          deletedPath = fallback.path;
        }
      } catch (e) {
        _logStep('Fallback delete de shared_preferences.json fallo: $e');
      }
    }
  }

  if (deletedPath != null) {
    _logStep('shared_preferences.json corrupto eliminado: $deletedPath');
  }

  try {
    await SharedPreferences.getInstance();
    _logStep('SharedPreferences reinicializado tras purga');
  } catch (e) {
    _logStep('SharedPreferences sigue fallando tras purga (se continuara): $e');
  }
}

Future<void> _forceShowStartupWindow() async {
  // En Windows hacemos esto en el runner nativo (Win32Window::Show) para evitar
  // crashes intermitentes del plugin `window_manager` en algunos entornos.
  if (kIsWeb || Platform.isWindows || !(Platform.isMacOS || Platform.isLinux)) {
    return;
  }

  try {
    await windowManager.setSkipTaskbar(false);
    await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
    _logStep('Native window restored/shown/focused');
  } catch (e) {
    _logStep('Native window show/focus failed (non-fatal): $e');
  }
}

void main() {
  print('>>> [MangoPOS] main() entry point');
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      print('>>> [MangoPOS] WidgetsBinding OK');
      _logToFile('main() - WidgetsBinding initialized');
      _installGlobalErrorHandlers();
      print('>>> [MangoPOS] Calling _bootstrapApp()...');
      await _bootstrapApp();
    },
    (error, stackTrace) {
      _logCritical('ZONE ERROR', error: error, stackTrace: stackTrace);
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
    print('>>> [MangoPOS] _bootstrapApp() started');
    _logStep('_bootstrapApp() started');

    const bool skipWindowManager = bool.fromEnvironment(
      'SKIP_WINDOW_MANAGER',
      defaultValue: false,
    );
    const bool skipSupabase = bool.fromEnvironment(
      'SKIP_SUPABASE',
      defaultValue: false,
    );
    const bool skipMediaKit = bool.fromEnvironment(
      'SKIP_MEDIA_KIT',
      defaultValue: false,
    );

    if (kIsWeb) usePathUrlStrategy();

    if (!kIsWeb &&
        (Platform.isMacOS || Platform.isLinux) &&
        !skipWindowManager) {
      _logStep('windowManager.ensureInitialized()...');
      print('>>> [MangoPOS] windowManager.ensureInitialized()...');
      await windowManager.ensureInitialized();

      _logStep('windowManager.setMinimumSize(800x600)...');
      print('>>> [MangoPOS] windowManager.setMinimumSize(800x600)...');
      await windowManager.setMinimumSize(const Size(800, 600));

      _logStep('_forceShowStartupWindow()...');
      print('>>> [MangoPOS] _forceShowStartupWindow()...');
      await _forceShowStartupWindow();

      _logStep('windowManager OK');
      print('>>> [MangoPOS] windowManager OK');
    }

    _logStep('initializeDateFormatting(es_DO)...');
    print('>>> [MangoPOS] initializeDateFormatting(es_DO)...');
    await initializeDateFormatting('es_DO', null);
    _logStep('initializeDateFormatting OK');

    _logStep('Verificando integridad de shared_preferences...');
    await _purgeCorruptSharedPreferencesIfNeeded();
    _logStep('shared_preferences OK');

    // ── Inicializar Supabase ANTES de montar la UI (requerido por auth/router) ──
    if (!skipSupabase) {
      _logStep('Supabase.initialize() -> ${Env.supabaseUrl}');
      print('>>> [MangoPOS] Supabase.initialize()...');
      await SupabaseConfig.initialize(
        url: Env.supabaseUrl,
        anonKey: Env.supabaseAnonKey,
      ).timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException(
          'Supabase.initialize excedio 20s durante el arranque',
        ),
      );
      _logStep('Supabase OK');
      print('>>> [MangoPOS] Supabase OK');
    } else {
      _logStep('Supabase SKIPPED via SKIP_SUPABASE');
      print('>>> [MangoPOS] Supabase SKIPPED');
    }

    if (!kIsWeb) {
      try {
        if (!skipMediaKit) {
          _logStep('MediaKit.ensureInitialized()...');
          print('>>> [MangoPOS] MediaKit.ensureInitialized()...');
          MediaKit.ensureInitialized();
          _logStep('MediaKit OK');
          print('>>> [MangoPOS] MediaKit OK');
        } else {
          _logStep('MediaKit SKIPPED via SKIP_MEDIA_KIT');
          print('>>> [MangoPOS] MediaKit SKIPPED');
        }
      } catch (e) {
        _logStep('MediaKit init failed (non-fatal): $e');
      }
    }

    await _lockLandscapeIfMobile();

    // ── Montar la UI de inmediato para que la ventana aparezca ──
    _logStep('runApp() - mounting UI...');
    print('>>> [MangoPOS] runApp()...');
    runApp(const ProviderScope(child: MyApp()));
    _startupUiMounted = true;
    await _forceShowStartupWindow();
    _logStep('runApp() done - UI mounted, waiting for first frame');
    print('>>> [MangoPOS] runApp() done');

    // ── Inicialización pesada DESPUÉS del primer frame ──
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _logStep('First frame rendered - starting background services');
      _initializeBackgroundServices();
    });
  } catch (e, st) {
    _logCritical('FATAL ERROR in _bootstrapApp', error: e, stackTrace: st);
    if (!_startupUiMounted) {
      runApp(StartupFailureApp(error: e, stackTrace: st));
      _startupUiMounted = true;
      await _forceShowStartupWindow();
    }
    AppLogger.f(
      'Error FATAL durante la inicializacion de la app',
      error: e,
      stackTrace: st,
    );
    // No re-lanzar: si fallamos antes de montar la UI, queremos mantener la
    // app viva mostrando la pantalla de error para poder diagnosticar (log en
    // mangopos_startup.log). En POS es preferible a cerrar silenciosamente.
    return;
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
    _logCritical(
      'FlutterError no controlado',
      error: details.exception,
      stackTrace: details.stack,
    );
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

    _logCritical(
      'Error asincrono no controlado',
      error: error,
      stackTrace: stackTrace,
    );
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

class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({
    super.key,
    required this.error,
    required this.stackTrace,
  });

  final Object error;
  final StackTrace stackTrace;

  @override
  Widget build(BuildContext context) {
    final friendlyMessage = SupabaseConfig.getFriendlyErrorMessage(error);

    return MaterialApp(
      title: 'MangoPOS',
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF8F5F1),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                elevation: 3,
                margin: const EdgeInsets.all(24),
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFFF97316),
                        size: 44,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'MangoPOS abrió, pero no pudo completar el arranque',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1C1917),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        friendlyMessage,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.4,
                          color: Color(0xFF57534E),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Revisa el log mangopos_startup.log (Escritorio o carpeta TEMP) para soporte técnico.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF78716C),
                        ),
                      ),
                      const SizedBox(height: 22),
                      FilledButton.icon(
                        onPressed: () => SystemNavigator.pop(),
                        icon: const Icon(Icons.close_rounded),
                        label: const Text('Cerrar'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
