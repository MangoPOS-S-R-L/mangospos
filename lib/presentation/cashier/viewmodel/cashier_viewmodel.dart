import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/data/utils/payment_amount_utils.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/core/cache/cache_manager.dart';
import 'package:mangopos/core/cache/cache_config.dart';
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

  CashierViewModel(this._repository, this._salesRepository);

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
            _lastSession = registerSession.toMap();
          } else {
            // Fallback: última sesión del usuario (cerrada o abierta) para
            // mostrar histórico cuando no hay caja activa.
            _lastSession = await _repository.getLastSession(
              _currentRegisterId!,
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
    } finally {
      _isLoading = false;
      notifyListeners();
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

  Future<void> openBox(double amount) async {
    if (_currentRegisterId == null) {
      final businessId = _businessId;
      if (businessId == null) {
        throw Exception('No se pudo identificar el negocio');
      }
      final created = await _repository.createCashRegister(
        businessId: businessId,
        name: 'Caja principal',
      );
      _currentRegisterId = created['id'] as String;
      _currentRegisterName = created['name']?.toString() ?? 'Caja principal';
    }
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) throw Exception('No user logged in');

    _isLoading = true;
    notifyListeners();
    try {
      final deviceId = await DeviceUtils.getDeviceId();
      final deviceName = DeviceUtils.getDeviceName();

      // Final check before sending to DB to provide better error message
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

      final existingUserSession = await _repository
          .getCurrentUserActiveSession();
      if (existingUserSession != null) {
        throw const CashRegisterException(
          errorCode: 'USER_ALREADY_OPEN',
          message:
              'Ya tienes una sesión de caja abierta en otro dispositivo o caja.',
        );
      }

      await _repository.openSession(
        cashRegisterId: _currentRegisterId!,
        userId: userId,
        startAmount: amount,
        deviceId: deviceId,
        deviceName: deviceName,
      );
      await init(); // Refresh
    } catch (e) {
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
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
    // `processPayment`. Aqui solo hacemos fetch y emitimos un unico
    // `notifyListeners` al final con el estado real.
    try {
      if (_currentRegisterId != null && _businessId != null) {
        // Misma resolucion que init(): caja es per-register (cualquier user
        // del local). Si no hay activa, fallback al historico del usuario
        // para mostrar el ultimo cierre en el panel.
        final registerSession = await _repository.getActiveSessionForRegister(
          _currentRegisterId!,
        );
        if (registerSession != null) {
          _lastSession = registerSession.toMap();
        } else {
          _lastSession = await _repository.getLastSession(_currentRegisterId!);
        }
        _lastCashOpenValidationAt = AppTime.nowAst();
        _pendingTables = await _salesRepository.getOpenTablesCount(
          _businessId!,
        );
        await _loadDashboardData(silent: true);
        notifyListeners();
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
        _lastSession = registerSession.toMap();
      } else {
        _lastSession = await _repository.getLastSession(_currentRegisterId!);
      }
      _lastCashOpenValidationAt = now;
      return _lastSession?['status'] == 'open';
    } catch (e) {
      debugPrint('Error validating cash session quickly: $e');
      return _lastSession?['status'] == 'open';
    }
  }
}
