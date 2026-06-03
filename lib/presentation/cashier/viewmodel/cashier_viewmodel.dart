import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:mangopos/core/offline/offline_pos_service.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/data/utils/payment_amount_utils.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/core/cache/cache_manager.dart';
import 'package:mangopos/core/cache/cache_config.dart';
import 'package:mangopos/core/storage/storage_service.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/core/utils/device_utils.dart';

final cashierRepositoryProvider = Provider<CashierRepository>((ref) {
  return CashierRepository(Supabase.instance.client);
});

final cashierViewModelProvider = ChangeNotifierProvider<CashierViewModel>((
  ref,
) {
  return CashierViewModel(
    ref.read(cashierRepositoryProvider),
    ref.read(salesRepositoryProvider),
  );
});

class CashierViewModel extends ChangeNotifier {
  final CashierRepository _repository;
  final SalesRepository _salesRepository;

  bool _isLoading = false;
  Map<String, dynamic>? _lastSession;
  int _pendingTables = 0;
  String? _currentRegisterId;
  String _currentRegisterName = '';
  String? _businessId;
  String _businessName = '';
  Map<String, dynamic> _todaySummary = {};
  List<Map<String, dynamic>> _recentMovements = [];
  List<TableSession> _activeSessions = [];
  Map<String, double> _sessionTotals = {};
  List<double> _weeklySales = List.filled(7, 0.0);
  double _totalWeeklySales = 0.0;
  double _weeklyAverage = 0.0;
  double _bestDayAmount = 0.0;
  String _bestDayName = '';
  DateTime? _lastCashOpenValidationAt;
  String? _error;

  // PRD 8 Fase 2 fix #1: el polling vive en el VM, no en el widget.
  // Antes: cada CashierView.initState arrancaba un Timer que llamaba
  // notifyListeners cada 30s INCONDICIONALMENTE → rebuild de todo el
  // dashboard aunque nada hubiera cambiado.
  // Ahora: Timer en el VM + hash check antes de notify (`_shouldNotify`).
  // Si nada cambió, no se emite notifyListeners y el subtree queda quieto.
  Timer? _silentRefreshTimer;
  static const Duration _silentRefreshInterval = Duration(seconds: 30);

  CashierViewModel(this._repository, this._salesRepository);

  /// Arranca el polling silencioso. Idempotente: si ya hay timer, no
  /// duplica. Lo llama `init()`; el widget no necesita gestionarlo.
  void startSilentRefresh() {
    _silentRefreshTimer ??= Timer.periodic(
      _silentRefreshInterval,
      (_) => unawaited(refreshSilently()),
    );
  }

  /// Hash del subset de state observable. Usado por `refreshSilently`
  /// para decidir si llamar notifyListeners o no. Si esto NO cambió,
  /// la pantalla se ve idéntica y el rebuild es desperdicio.
  String _observableStateHash() {
    final session = _lastSession;
    return [
      session?['id'],
      session?['status'],
      session?['end_amount'],
      session?['start_amount'],
      _pendingTables,
      _todaySummary['total'],
      _todaySummary['transactions'],
      _recentMovements.length,
      _activeSessions.length,
      _totalWeeklySales,
    ].join('|');
  }

  @override
  void dispose() {
    _silentRefreshTimer?.cancel();
    super.dispose();
  }

  // ───────────────────────────────────────────────────────────────────
  // Persistencia local de la sesión de caja (Fase 1.4a offline)
  // ───────────────────────────────────────────────────────────────────
  // Guardamos un snapshot de `_lastSession` (cuando está open) en
  // SharedPreferences para que un restart de la app sin internet pueda
  // recuperar el estado de caja abierta. Sin esto, después de cerrar y
  // reabrir la app offline el cajero queda bloqueado en `ensureCashOpenFast`.
  String? _cachedSessionKey() {
    if (_businessId == null || _currentRegisterId == null) return null;
    return 'cashier_last_session_${_businessId}_$_currentRegisterId';
  }

  Future<void> _persistLastSession(Map<String, dynamic>? session) async {
    final key = _cachedSessionKey();
    if (key == null) return;
    try {
      final storage = await StorageService.getInstance();
      // Solo cacheamos sesiones abiertas. Sesiones cerradas / null limpian
      // el cache para no reabrir indebidamente al volver offline.
      if (session != null && session['status'] == 'open') {
        await storage.write(key, jsonEncode(session));
      } else {
        await storage.delete(key);
      }
    } catch (e) {
      debugPrint('cashier: error persistiendo lastSession: $e');
    }
  }

  Future<Map<String, dynamic>?> _readCachedLastSession() async {
    final key = _cachedSessionKey();
    if (key == null) return null;
    try {
      final storage = await StorageService.getInstance();
      final raw = await storage.read(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (e) {
      debugPrint('cashier: error leyendo lastSession cacheada: $e');
    }
    return null;
  }

  /// Setter helper que mantiene el cache local sincronizado con `_lastSession`.
  /// Reemplaza asignaciones directas para que toda actualización pase por aquí.
  void _setLastSession(Map<String, dynamic>? session) {
    _lastSession = session;
    // Persistir en background (fire-and-forget). Los lectores ven el cambio
    // sincrónico en memoria; el disco es eventual.
    unawaited(_persistLastSession(session));
  }

  bool get isLoading => _isLoading;
  String? get error => _error;
  String get businessName => _businessName;
  Map<String, dynamic>? get lastSession => _lastSession;
  int get pendingTables => _pendingTables;
  Map<String, dynamic> get todaySummary => _todaySummary;
  List<Map<String, dynamic>> get recentMovements => _recentMovements;
  List<TableSession> get activeSessions => _activeSessions;
  Map<String, double> get sessionTotals => _sessionTotals;
  List<double> get weeklySales => _weeklySales;
  double get totalWeeklySales => _totalWeeklySales;
  double get weeklyAverage => _weeklyAverage;
  double get bestDayAmount => _bestDayAmount;
  String get bestDayName => _bestDayName;
  String? get currentRegisterId => _currentRegisterId;
  String get currentRegisterName => _currentRegisterName;
  bool get isCashOpen => _lastSession?['status'] == 'open';
  String? get businessId => _businessId;

  Future<void> init() async {
    _isLoading = true;
    _error = null;
    // NO limpiamos `_lastSession` aqui aposta. Antes lo nulleabamos para
    // evitar mostrar "abierta" stale durante el fetch (~5s), pero eso
    // hacia que en cada navegacion la UI parpadeara "Caja cerrada"
    // durante 2-5s aun cuando la caja estaba realmente abierta. El
    // riesgo de cross-device close (cache "abierta" + realidad
    // "cerrada") esta cubierto por:
    //   1) `ensureCashOpenFast` (TTL 12s) que se llama al entrar a las
    //      pantallas de venta — revalida si la ultima validacion es
    //      vieja.
    //   2) `processPayment` RPC server-side, que retorna
    //      `CASH_SESSION_REQUIRED` si la caja no esta abierta.
    // Resultado: la UI muestra el ultimo estado conocido mientras
    // refresca en background; si cambia, el `notifyListeners()` final
    // actualiza sin flash.
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      _businessId = await resolveBusinessIdOrNull(client, 'auto');

      if (_businessId != null) {
        // Fetch Business Name
        try {
          final businessData = await client
              .from('businesses')
              .select() // Select all to avoid column errors
              .eq('id', _businessId!)
              .maybeSingle();

          if (businessData != null) {
            _businessName =
                businessData['name'] as String? ??
                businessData['business_name'] as String? ??
                '';
          }
        } catch (e) {
          debugPrint('Error fetching business name: $e');
        }

        final registers = await _repository.getCashRegisters(_businessId!);
        if (registers.isNotEmpty) {
          _currentRegisterId = registers.first['id'] as String;
          _currentRegisterName = registers.first['name']?.toString() ?? '';
        } else {
          final created = await _repository.createCashRegister(
            businessId: _businessId!,
            name: 'Caja principal',
          );
          _currentRegisterId = created['id'] as String;
          _currentRegisterName =
              created['name']?.toString() ?? 'Caja principal';
        }
        if (_currentRegisterId != null) {
          // Modelo: una caja por cash_register, visible para todos los empleados
          // del local (mesero/cajero/admin pueden vender si hay caja abierta).
          // El cierre sigue restringido al dueño (validado en cashier_view +
          // RPC fn_close_cash_session).
          final registerSession = await _repository.getActiveSessionForRegister(
            _currentRegisterId!,
          );
          if (registerSession != null) {
            _setLastSession(registerSession.toMap());
          } else {
            // Fallback: última sesión del usuario (cerrada o abierta) para
            // mostrar histórico cuando no hay caja activa.
            _setLastSession(
              await _repository.getLastSession(_currentRegisterId!),
            );
          }

          _lastCashOpenValidationAt = AppTime.nowAst();
          _pendingTables = await _salesRepository.getOpenTablesCount(
            _businessId!,
          );

          // Load all dashboard data in parallel to reduce wait time
          await _loadDashboardData();
        }
      }
    } catch (e) {
      debugPrint('Error loading cashier data: $e');
      _error = 'Error al cargar datos de caja.';

      // Fase 1.4a — fallback offline: si la consulta al server falló y NO
      // tenemos sesión en memoria, intentar restaurar de SharedPreferences.
      // Esto permite que un restart de la app sin internet no bloquee al
      // cajero cuando ya había caja abierta antes de perder la conexión.
      if (_lastSession == null) {
        final cached = await _readCachedLastSession();
        if (cached != null && cached['status'] == 'open') {
          _lastSession = cached;
          _lastCashOpenValidationAt = AppTime.nowAst();
          debugPrint('cashier: restaurada caja abierta desde cache offline');
        }
      }
    } finally {
      _isLoading = false;
      notifyListeners();
      // PRD 8 Fase 2 fix #1: arrancar polling silencioso. Idempotente:
      // si ya hay timer corriendo, no duplica. Se cancela en dispose().
      startSilentRefresh();
    }
  }

  /// Loads summary, movements, sessions and weekly sales in parallel.
  /// Emits a single notifyListeners at the end to avoid multiple rebuilds.
  Future<void> _loadDashboardData({bool silent = false}) async {
    final results = await Future.wait([
      _fetchTodaySummary(),
      _fetchRecentMovements(),
      _fetchActiveSessions(),
      _fetchWeeklySales(),
    ], eagerError: false);

    final summary = results[0] as Map<String, dynamic>?;
    final movements = results[1] as List<Map<String, dynamic>>?;
    final sessionsData = results[2] as Map<String, dynamic>?;
    final weeklyData = results[3] as Map<String, dynamic>?;

    if (summary != null) _todaySummary = summary;
    if (movements != null) _recentMovements = movements;
    if (sessionsData != null) {
      final sessionsList = sessionsData['sessions'] as List;
      _activeSessions = sessionsList
          .map((s) => TableSession.fromMap(s as Map<String, dynamic>))
          .toList();
      _sessionTotals = Map<String, double>.from(sessionsData['totals'] ?? {});
    }
    if (weeklyData != null) _applyWeeklyData(weeklyData);

    if (!silent) notifyListeners();
  }

  /// Pure data fetcher — returns summary map without mutating state.
  Future<Map<String, dynamic>?> _fetchTodaySummary() async {
    try {
      if (_businessId == null) {
        return {
          'total_income': 0.0,
          'total_expenses': 0.0,
          'transaction_count': 0,
        };
      }

      final client = Supabase.instance.client;
      final dayRange = AppTime.todayRangeUtc();
      final startOfDay = dayRange.fromUtc.toIso8601String();
      final endOfDay = dayRange.toUtc.toIso8601String();

      final paymentsData = await client
          .from('payments')
          .select('amount, change_amount, created_at')
          .gte('created_at', startOfDay)
          .lt('created_at', endOfDay)
          .eq('status', 'completed')
          .eq('business_id', _businessId!);

      double totalIncome = 0.0;
      int transactionCount = paymentsData.length;
      for (var payment in paymentsData) {
        totalIncome += netPaymentAmount(
          payment['amount'],
          payment['change_amount'],
        );
      }

      double totalExpenses = 0.0;
      if (_lastSession != null && _lastSession!['id'] != null) {
        try {
          final movementsData = await client
              .from('cash_transactions')
              .select('amount, type, created_at')
              .gte('created_at', startOfDay)
              .lt('created_at', endOfDay)
              .eq('session_id', _lastSession!['id']);

          for (var movement in movementsData) {
            if (movement['type'] == 'expense') {
              final amount = movement['amount'];
              if (amount != null) {
                if (amount is num) {
                  totalExpenses += amount.toDouble();
                } else if (amount is String) {
                  totalExpenses += double.tryParse(amount) ?? 0.0;
                }
              }
            }
          }
        } catch (e) {
          debugPrint('Error loading expenses: $e');
        }
      }

      return {
        'total_income': totalIncome,
        'total_expenses': totalExpenses,
        'transaction_count': transactionCount,
      };
    } catch (e) {
      debugPrint('Error loading today summary: $e');
      return {
        'total_income': 0.0,
        'total_expenses': 0.0,
        'transaction_count': 0,
      };
    }
  }

  /// Pure data fetcher — returns movements list without mutating state.
  Future<List<Map<String, dynamic>>?> _fetchRecentMovements() async {
    try {
      if (_businessId == null) return [];

      final client = Supabase.instance.client;
      final dayRange = AppTime.todayRangeUtc();
      final startOfDay = dayRange.fromUtc.toIso8601String();
      final endOfDay = dayRange.toUtc.toIso8601String();

      final paymentsData = await client
          .from('payments')
          .select(
            'id, amount, change_amount, payment_method_id, created_at, order_id',
          )
          .gte('created_at', startOfDay)
          .lt('created_at', endOfDay)
          .eq('status', 'completed')
          .eq('business_id', _businessId!)
          .order('created_at', ascending: false)
          .limit(15);

      List<Map<String, dynamic>> movements = [];

      for (var payment in paymentsData) {
        String description = 'Venta';
        if (payment['order_id'] != null) {
          try {
            final orderData = await client
                .from('orders')
                .select('id, session_id')
                .eq('id', payment['order_id'])
                .maybeSingle();

            if (orderData != null) {
              final orderIdShort = (orderData['id'] ?? payment['id'])
                  .toString()
                  .substring(0, 8);
              description = 'Venta #$orderIdShort';

              if (orderData['session_id'] != null) {
                final sessionData = await client
                    .from('table_sessions')
                    .select('table_id')
                    .eq('id', orderData['session_id'])
                    .maybeSingle();

                if (sessionData != null && sessionData['table_id'] != null) {
                  final tableData = await client
                      .from('dining_tables')
                      .select('code, label')
                      .eq('id', sessionData['table_id'])
                      .maybeSingle();

                  if (tableData != null) {
                    final code =
                        tableData['code'] ?? tableData['label'] ?? '??';
                    description = 'Venta Mesa $code';
                  }
                }
              }
            }
          } catch (e) {
            debugPrint('Could not get order details: $e');
          }
        }

        final amount = netPaymentAmount(
          payment['amount'],
          payment['change_amount'],
        );
        movements.add({
          'type': 'income',
          'description': description,
          'amount': amount,
          'created_at': payment['created_at'],
        });
      }

      if (_lastSession != null && _lastSession!['id'] != null) {
        try {
          final expensesData = await client
              .from('cash_transactions')
              .select('id, amount, description, type, created_at')
              .eq('session_id', _lastSession!['id'])
              .eq('type', 'expense')
              .gte('created_at', startOfDay)
              .lt('created_at', endOfDay)
              .order('created_at', ascending: false)
              .limit(5);

          for (var expense in expensesData) {
            double amount = 0.0;
            final expenseAmount = expense['amount'];
            if (expenseAmount != null) {
              if (expenseAmount is num) {
                amount = expenseAmount.toDouble();
              } else if (expenseAmount is String) {
                amount = double.tryParse(expenseAmount) ?? 0.0;
              }
            }

            movements.add({
              'type': 'expense',
              'description': expense['description'] ?? 'Compra suministros',
              'amount': amount,
              'created_at': expense['created_at'],
            });
          }
        } catch (e) {
          debugPrint('Error loading expenses: $e');
        }
      }

      movements.sort((a, b) {
        try {
          final aDate = DateTime.parse(
            a['created_at'] ?? AppTime.astToUtcIso(AppTime.nowAst()),
          );
          final bDate = DateTime.parse(
            b['created_at'] ?? AppTime.astToUtcIso(AppTime.nowAst()),
          );
          return bDate.compareTo(aDate);
        } catch (e) {
          return 0;
        }
      });

      return movements.take(10).toList();
    } catch (e) {
      debugPrint('Error loading recent movements: $e');
      return [];
    }
  }

  /// Pure data fetcher for weekly sales — returns data map without mutating state.
  Future<Map<String, dynamic>?> _fetchWeeklySales() async {
    try {
      if (_businessId == null) return null;

      final cacheKey = 'weekly_sales_v1_$_businessId';

      Future<Map<String, dynamic>> fetchFromApi() async {
        final client = Supabase.instance.client;
        final now = AppTime.nowAst();
        final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
        final startOfWeekDate = DateTime(
          startOfWeek.year,
          startOfWeek.month,
          startOfWeek.day,
        );
        final endOfWeekDate = startOfWeekDate.add(const Duration(days: 7));

        final payments = await client
            .from('payments')
            .select('amount, change_amount, created_at')
            .gte('created_at', AppTime.astToUtcIso(startOfWeekDate))
            .lt('created_at', AppTime.astToUtcIso(endOfWeekDate))
            .eq('status', 'completed')
            .eq('business_id', _businessId!);

        List<double> weeklySales = List.filled(7, 0.0);
        for (var payment in payments) {
          final amount = netPaymentAmount(
            payment['amount'],
            payment['change_amount'],
          );
          final dateStr = payment['created_at'] as String;
          final date = AppTime.tryParseServerToAst(dateStr);
          if (date == null) continue;
          final dayIndex = date.weekday - 1;
          if (dayIndex >= 0 && dayIndex < 7) {
            weeklySales[dayIndex] += amount;
          }
        }

        final totalWeeklySales = weeklySales.reduce((a, b) => a + b);
        final weeklyAverage = totalWeeklySales / 7;

        double maxVal = -1.0;
        int maxIdx = -1;
        for (int i = 0; i < 7; i++) {
          if (weeklySales[i] > maxVal) {
            maxVal = weeklySales[i];
            maxIdx = i;
          }
        }

        String bestDayName = '-';
        double bestDayAmount = 0.0;
        if (maxIdx != -1) {
          bestDayAmount = maxVal;
          const days = [
            'Lunes',
            'Martes',
            'Miércoles',
            'Jueves',
            'Viernes',
            'Sábado',
            'Domingo',
          ];
          bestDayName = days[maxIdx];
        }

        return {
          'weekly_sales': weeklySales,
          'total_weekly_sales': totalWeeklySales,
          'weekly_average': weeklyAverage,
          'best_day_amount': bestDayAmount,
          'best_day_name': bestDayName,
        };
      }

      // Try cache first for fast initial display
      final cached = await CacheManager().get<Map<String, dynamic>>(
        key: cacheKey,
        strategy: CacheStrategy.cacheOnly,
        fromJson: (json) => Map<String, dynamic>.from(json),
        fetchFromApi: fetchFromApi,
      );

      // Then always fetch fresh from network
      final fresh = await CacheManager().get<Map<String, dynamic>>(
        key: cacheKey,
        strategy: CacheStrategy.networkOnly,
        ttl: const Duration(minutes: 30),
        fromJson: (json) => Map<String, dynamic>.from(json),
        fetchFromApi: fetchFromApi,
      );

      return fresh ?? cached;
    } catch (e) {
      debugPrint('Error loading weekly sales: $e');
      return null;
    }
  }

  /// Pure data fetcher for active sessions — returns data map without mutating state.
  Future<Map<String, dynamic>?> _fetchActiveSessions() async {
    try {
      if (_businessId == null)
        return {'sessions': [], 'totals': <String, double>{}};

      final cacheKey = 'active_sessions_v1_$_businessId';

      Future<Map<String, dynamic>> fetchFromApi() async {
        final sessions = await _salesRepository.getActiveSessions(_businessId!);

        Map<String, double> sessionTotals = {};
        if (sessions.isNotEmpty) {
          final sessionIds = sessions.map((s) => s.id).toList(growable: false);
          final client = Supabase.instance.client;

          final orderRows = List<Map<String, dynamic>>.from(
            await client
                .from('orders')
                .select(
                  'id,session_id,status_ext,subtotal,tax,service_fee,discounts,total,created_at,closed_at',
                )
                .inFilter('session_id', sessionIds)
                .isFilter('closed_at', null)
                .not('status_ext', 'in', '(paid,void)'),
          );

          final orderIds = orderRows
              .map((order) => order['id']?.toString().trim())
              .whereType<String>()
              .where((orderId) => orderId.isNotEmpty)
              .toList(growable: false);

          final sessionIdByOrderId = <String, String>{};
          final ordersById = <String, Order>{};
          for (final order in orderRows) {
            final orderId = order['id']?.toString().trim();
            final sessionId = order['session_id']?.toString().trim();
            if (orderId == null || orderId.isEmpty) continue;
            if (sessionId == null || sessionId.isEmpty) continue;
            sessionIdByOrderId[orderId] = sessionId;
            ordersById[orderId] = Order.fromMap(order);
          }

          final itemsByOrderId = <String, List<OrderItem>>{};
          final closedCheckIdsByOrderId = <String, Set<String>>{};

          if (orderIds.isNotEmpty) {
            final itemRows = List<Map<String, dynamic>>.from(
              await client
                  .from('order_items')
                  .select(
                    'id,order_id,product_id,product_name,sku,qty,quantity,unit_price,subtotal,discounts,tax,total,check_id,is_takeout,status,notes,tax_mode,tax_rate,created_at',
                  )
                  .inFilter('order_id', orderIds)
                  .not('status', 'in', '(paid,void)'),
            );

            final checkRows = List<Map<String, dynamic>>.from(
              await client
                  .from('order_checks')
                  .select('id,order_id,is_closed')
                  .inFilter('order_id', orderIds),
            );

            for (final itemRow in itemRows) {
              final item = OrderItem.fromMap(itemRow);
              final orderId = item.orderId.trim();
              if (orderId.isEmpty) continue;
              itemsByOrderId
                  .putIfAbsent(orderId, () => <OrderItem>[])
                  .add(item);
            }

            for (final checkRow in checkRows) {
              final checkId = checkRow['id']?.toString().trim();
              final orderId = checkRow['order_id']?.toString().trim();
              if (orderId == null || orderId.isEmpty) continue;
              if (checkRow['is_closed'] != true) continue;
              if (checkId == null || checkId.isEmpty) continue;
              closedCheckIdsByOrderId
                  .putIfAbsent(orderId, () => <String>{})
                  .add(checkId);
            }
          }

          for (final orderId in orderIds) {
            final sessionId = sessionIdByOrderId[orderId];
            if (sessionId == null || sessionId.isEmpty) continue;
            final order = ordersById[orderId];
            if (order == null) continue;
            final closedCheckIds =
                closedCheckIdsByOrderId[orderId] ?? const <String>{};
            final pendingItems =
                (itemsByOrderId[orderId] ?? const <OrderItem>[])
                    .where((item) => !closedCheckIds.contains(item.checkId))
                    .toList(growable: false);
            final pendingTotal = summarizeOrderPricing(
              order,
              pendingItems,
            ).total;
            sessionTotals[sessionId] =
                (sessionTotals[sessionId] ?? 0) + pendingTotal;
          }
        }

        final serializedSessions = sessions
            .map(
              (s) => {
                'id': s.id,
                'business_id': s.businessId,
                'opened_by': s.openedBy,
                'opened_at': s.openedAt.toIso8601String(),
                'people_count': s.peopleCount,
                'origin': s.origin,
                'table_name': s.tableName,
                'zone_name': s.zoneName,
              },
            )
            .toList();

        return {'sessions': serializedSessions, 'totals': sessionTotals};
      }

      // Try cache first for fast display
      final cached = await CacheManager().get<Map<String, dynamic>>(
        key: cacheKey,
        strategy: CacheStrategy.cacheOnly,
        fromJson: (json) => Map<String, dynamic>.from(json),
        fetchFromApi: fetchFromApi,
      );

      // Then always fetch fresh from network
      final fresh = await CacheManager().get<Map<String, dynamic>>(
        key: cacheKey,
        strategy: CacheStrategy.networkOnly,
        ttl: const Duration(minutes: 5),
        fromJson: (json) => Map<String, dynamic>.from(json),
        fetchFromApi: fetchFromApi,
      );

      return fresh ?? cached;
    } catch (e) {
      debugPrint('Error loading active sessions: $e');
      return null;
    }
  }

  void _applyWeeklyData(Map<String, dynamic> data) {
    _weeklySales = List<double>.from(
      data['weekly_sales'] ?? List.filled(7, 0.0),
    );
    _totalWeeklySales = (data['total_weekly_sales'] as num?)?.toDouble() ?? 0.0;
    _weeklyAverage = (data['weekly_average'] as num?)?.toDouble() ?? 0.0;
    _bestDayAmount = (data['best_day_amount'] as num?)?.toDouble() ?? 0.0;
    _bestDayName = data['best_day_name'] ?? '-';
  }

  /// Abre la caja. Devuelve `true` si la apertura se resolvió por la rama
  /// OFFLINE (sesión local encolada para sync) y `false` si se confirmó
  /// online contra el server. El caller usa esto para no mostrar "Caja
  /// abierta exitosamente" cuando en realidad quedó pendiente de sync.
  Future<bool> openBox(double amount) async {
    if (_currentRegisterId == null) {
      final businessId = _businessId;
      if (businessId == null) {
        throw Exception('No se pudo identificar el negocio');
      }
      try {
        final created = await _repository.createCashRegister(
          businessId: businessId,
          name: 'Caja principal',
        );
        _currentRegisterId = created['id'] as String;
        _currentRegisterName = created['name']?.toString() ?? 'Caja principal';
      } catch (e) {
        // Sin red Y sin register_id local: único caso donde abrir caja
        // offline es imposible. Device totalmente nuevo en esta sucursal
        // que nunca operó antes.
        if (_isConnectivityError(e)) {
          throw const CashRegisterException(
            errorCode: 'NO_REGISTER_OFFLINE',
            message:
                'No hay una caja configurada en este dispositivo. '
                'Conéctate a internet al menos una vez para crearla.',
          );
        }
        rethrow;
      }
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) throw Exception('No user logged in');

    _isLoading = true;
    notifyListeners();
    try {
      final deviceId = await DeviceUtils.getDeviceId();
      final deviceName = DeviceUtils.getDeviceName();

      // Guards previos: si fallan POR RED NO bloqueamos — el RPC server-
      // side los re-valida al sync. Si fallan por estado real (sesión ya
      // abierta) sí propagamos el error.
      try {
        final existingDeviceSession = await _repository.getDeviceActiveSession(
          deviceId,
        );
        if (existingDeviceSession != null) {
          throw const CashRegisterException(
            errorCode: 'DEVICE_ALREADY_OPEN',
            message:
                'No se puede abrir otra caja ya que hay una caja abierta actualmente en este dispositivo.',
          );
        }

        // Escopear el chequeo al business actual: si el usuario es owner
        // de varias sucursales, la migración 20260509_0002 le permite
        // abrir caja simultánea en cada una. Filtrar sin business_id
        // bloquearía aunque el backend lo permita. El RPC sigue siendo
        // la autoridad final y rechaza si Rule B aplica para no-owners.
        final businessIdScope = _businessId;
        final existingUserSession = businessIdScope != null
            ? await _repository.getCurrentUserActiveSessionForBusiness(
                businessId: businessIdScope,
              )
            : await _repository.getCurrentUserActiveSession();
        if (existingUserSession != null) {
          throw const CashRegisterException(
            errorCode: 'USER_ALREADY_OPEN',
            message:
                'Ya tienes una sesión de caja abierta en esta sucursal.',
          );
        }
      } on CashRegisterException {
        rethrow;
      } catch (e) {
        if (!_isConnectivityError(e)) rethrow;
        debugPrint('[openBox] guards skipped por falta de red: $e');
      }

      try {
        await _repository.openSession(
          cashRegisterId: _currentRegisterId!,
          userId: userId,
          startAmount: amount,
          deviceId: deviceId,
          deviceName: deviceName,
        );
        await init(); // Refresh — solo en path online (lee server state).
        return false; // Confirmado online.
      } catch (e) {
        if (!_isConnectivityError(e)) rethrow;
        // Diagnóstico: dejamos rastro del error real que clasificamos como
        // "sin red". Si esto aparece estando online, el clasificador
        // (_isConnectivityError) está tragando un error que NO es de red y
        // bajamos a offline indebidamente (banner falso "caja abierta").
        debugPrint(
          '[openBox] openSession cayó a fallback offline. Error real: $e',
        );
        // Fallback offline: sesión local + encolar para replay al sync.
        await _openBoxOfflineFallback(
          amount: amount,
          userId: userId,
          deviceId: deviceId,
          deviceName: deviceName,
        );
        return true; // Quedó pendiente de sincronizar.
      }
    } catch (e) {
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Rama offline de [openBox]: crea una sesión con id temporal
  /// `local-cash-session-<ts>`, la persiste vía `_setLastSession` (que
  /// ya hace cache en SharedPreferences) y encola `open_cash_session`.
  /// Al sync, el replay llamará al RPC real y guardará el mapping
  /// `local-id → remote-uuid` en OfflinePosService — los payments
  /// encolados con `cashier_session_id` local se traducen al replay.
  Future<void> _openBoxOfflineFallback({
    required double amount,
    required String userId,
    required String deviceId,
    required String deviceName,
  }) async {
    final businessId = _businessId;
    if (businessId == null) {
      throw Exception('No se pudo identificar el negocio offline');
    }
    final openedAt = DateTime.now().toUtc();
    // UUID v4 garantiza unicidad incluso con dos aperturas en la misma
    // milésima (improbable en producción, posible en emuladores lentos
    // o tests). El prefijo `local-cash-session-` se mantiene como
    // marker para que OfflinePosService.replay detecte el id local y
    // lo traduzca al remoto vía el mapping.
    final localId = 'local-cash-session-${const Uuid().v4()}';

    await OfflinePosService().enqueueAction(
      businessId: businessId,
      action: {
        'type': 'open_cash_session',
        'local_session_id': localId,
        'cash_register_id': _currentRegisterId,
        'user_id': userId,
        'start_amount': amount,
        'device_id': deviceId,
        'device_name': deviceName,
        'opened_at': openedAt.toIso8601String(),
      },
    );

    _setLastSession({
      'id': localId,
      'cash_register_id': _currentRegisterId,
      'user_id': userId,
      'start_amount': amount,
      'status': 'open',
      'opened_at': openedAt.toIso8601String(),
      'closed_at': null,
      'device_id': deviceId,
      'device_name': deviceName,
      'business_id': businessId,
    });
    _lastCashOpenValidationAt = AppTime.nowAst();
  }

  /// Registra un movimiento manual de caja (depósito/retiro/gasto). Si la
  /// red se cae, lo encola como `cash_transaction` para replay al
  /// reconectar — antes esto se perdía sin conexión (gap F2). Devuelve
  /// `true` si se aplicó online, `false` si quedó encolado offline.
  Future<bool> createManualTransaction({
    required String sessionId,
    required double amount,
    required String type,
    required String reasonCode,
    String? description,
    String? approvedBy,
  }) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    try {
      await _repository.createManualTransaction(
        sessionId: sessionId,
        amount: amount,
        type: type,
        reasonCode: reasonCode,
        description: description,
        createdBy: userId,
        approvedBy: approvedBy,
      );
      return true;
    } catch (e) {
      // Solo caemos a offline ante error de conectividad. Errores de
      // negocio (razón inválida, aprobación requerida, sesión cerrada) se
      // propagan para que el cajero los corrija en el momento.
      if (!_isConnectivityError(e)) rethrow;
      final businessId = _businessId;
      if (businessId == null) rethrow;
      await OfflinePosService().enqueueAction(
        businessId: businessId,
        action: {
          'type': 'cash_transaction',
          'session_id': sessionId,
          'amount': amount,
          'cash_type': type,
          'reason_code': reasonCode,
          'description': description,
          'created_by': userId,
          'approved_by': approvedBy,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      );
      return false;
    }
  }

  bool _isConnectivityError(Object e) {
    if (e is SocketException) return true;
    if (e is TimeoutException) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('socket') ||
        msg.contains('failed host lookup') ||
        msg.contains('clientexception') ||
        (msg.contains('connection') && msg.contains('refused'));
  }

  /// Silent background refresh — loads all data in parallel without showing
  /// a loading spinner. Emits a single notifyListeners al final.
  ///
  /// NO invalidamos `_lastSession` antes del fetch para evitar el flicker
  /// "abierta → cerrada → abierta" cada 30 s.
  ///
  /// Tradeoff: si la caja fue cerrada en otro dispositivo desde el último
  /// refresh, la UI seguirá mostrando "abierta" hasta que termine este fetch
  /// (~varios segundos). Caso raro; `init()` (que sí invalida) se llama en
  /// cambios de business y aperturas explícitas, donde el loading es OK.
  Future<void> refreshSilently() async {
    // NO nulleamos `_lastSession` aqui aposta. Ver comentario largo en
    // `init()`: nullear causaba el flash "Caja cerrada" en cada
    // navegacion. La proteccion contra stale "open" esta en
    // `ensureCashOpenFast` (TTL 12s) y la validacion server-side de
    // `processPayment`. Aqui solo hacemos fetch y emitimos
    // notifyListeners SOLO si el state observable cambio.
    //
    // PRD 8 Fase 2 fix #1: snapshot del hash ANTES del fetch, comparar
    // DESPUES. Si nada cambio, skip notify y el widget no rebuild. En
    // negocios con poca actividad (la mayoria del tiempo), eso evita
    // ~120 rebuilds/hora del dashboard de caja completo.
    try {
      if (_currentRegisterId != null && _businessId != null) {
        final prevHash = _observableStateHash();

        // Misma resolucion que init(): caja es per-register (cualquier user
        // del local). Si no hay activa, fallback al historico del usuario
        // para mostrar el ultimo cierre en el panel.
        final registerSession = await _repository.getActiveSessionForRegister(
          _currentRegisterId!,
        );
        if (registerSession != null) {
          _setLastSession(registerSession.toMap());
        } else {
          _setLastSession(
            await _repository.getLastSession(_currentRegisterId!),
          );
        }
        _lastCashOpenValidationAt = AppTime.nowAst();
        _pendingTables = await _salesRepository.getOpenTablesCount(
          _businessId!,
        );
        await _loadDashboardData(silent: true);

        if (_observableStateHash() != prevHash) {
          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('Error refreshing cashier data: $e');
    }
  }

  Future<int> refreshPendingTablesCount() async {
    if (_businessId == null) return _pendingTables;
    try {
      _pendingTables = await _salesRepository.getOpenTablesCount(_businessId!);
      notifyListeners();
      return _pendingTables;
    } catch (e) {
      debugPrint('Error refreshing pending tables: $e');
      return _pendingTables;
    }
  }

  /// Verificación ligera para flujo de ventas:
  /// evita cargar resúmenes/movimientos en cada click de mesa.
  Future<bool> ensureCashOpenFast({
    Duration ttl = const Duration(seconds: 12),
    bool force = false,
  }) async {
    final now = AppTime.nowAst();
    final hasRecentValidation =
        _lastCashOpenValidationAt != null &&
        now.difference(_lastCashOpenValidationAt!) < ttl;

    if (!force && hasRecentValidation) {
      return _lastSession?['status'] == 'open';
    }

    try {
      if (_currentRegisterId == null || _businessId == null) {
        await init();
        return _lastSession?['status'] == 'open';
      }

      // Buscar caja activa por register (compartida entre empleados del local).
      // Si no hay activa, caer a última sesión del usuario para mostrar histórico.
      final registerSession = await _repository.getActiveSessionForRegister(
        _currentRegisterId!,
      );
      if (registerSession != null) {
        _setLastSession(registerSession.toMap());
      } else {
        _setLastSession(
          await _repository.getLastSession(_currentRegisterId!),
        );
      }
      _lastCashOpenValidationAt = now;
      return _lastSession?['status'] == 'open';
    } catch (e) {
      debugPrint('Error validating cash session quickly: $e');
      // Fase 1.4a — offline: si no hay sesión en memoria pero hay una
      // cacheada del último login online, restaurarla para no bloquear al
      // cajero. El TTL del cache es implícito: si el cajero cierra caja en
      // otro dispositivo, este queda con stale "open" hasta volver online
      // — mismo tradeoff que ya documenta `refreshSilently`.
      if (_lastSession == null) {
        final cached = await _readCachedLastSession();
        if (cached != null && cached['status'] == 'open') {
          _lastSession = cached;
        }
      }
      return _lastSession?['status'] == 'open';
    }
  }
}
