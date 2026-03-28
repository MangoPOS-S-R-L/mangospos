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

  CashierViewModel(this._repository, this._salesRepository);

  bool get isLoading => _isLoading;
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
          _lastSession = await _repository.getLastSession(_currentRegisterId!);
          _lastCashOpenValidationAt = AppTime.nowAst();
          _pendingTables = await _salesRepository.getOpenTablesCount(
            _businessId!,
          );

          // Load today's summary
          await _loadTodaySummary();

          // Load recent movements
          await _loadRecentMovements();

          // Load active sessions
          await _loadActiveSessions();

          // Load weekly sales
          await _loadWeeklySales();
        }
      }
    } catch (e) {
      debugPrint('Error loading cashier data: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadTodaySummary() async {
    try {
      if (_businessId == null) {
        debugPrint('Cannot load summary: business_id is null');
        _todaySummary = {
          'total_income': 0.0,
          'total_expenses': 0.0,
          'transaction_count': 0,
        };
        return;
      }

      final client = Supabase.instance.client;
      final dayRange = AppTime.todayRangeUtc();
      final startOfDay = dayRange.fromUtc.toIso8601String();
      final endOfDay = dayRange.toUtc.toIso8601String();

      debugPrint('Loading summary for business: $_businessId');

      // Get payments for today
      final paymentsData = await client
          .from('payments')
          .select('amount, change_amount, created_at')
          .gte('created_at', startOfDay)
          .lt('created_at', endOfDay)
          .eq('status', 'completed')
          .eq('business_id', _businessId!);

      double totalIncome = 0.0;
      int transactionCount = 0;

      transactionCount = paymentsData.length;
      for (var payment in paymentsData) {
        totalIncome += netPaymentAmount(
          payment['amount'],
          payment['change_amount'],
        );
      }

      // Get expenses for today (cash movements)
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

      _todaySummary = {
        'total_income': totalIncome,
        'total_expenses': totalExpenses,
        'transaction_count': transactionCount,
      };
    } catch (e) {
      debugPrint('Error loading today summary: $e');
      _todaySummary = {
        'total_income': 0.0,
        'total_expenses': 0.0,
        'transaction_count': 0,
      };
    }
  }

  Future<void> _loadRecentMovements() async {
    try {
      if (_businessId == null) {
        _recentMovements = [];
        return;
      }

      final client = Supabase.instance.client;
      final dayRange = AppTime.todayRangeUtc();
      final startOfDay = dayRange.fromUtc.toIso8601String();
      final endOfDay = dayRange.toUtc.toIso8601String();

      // Get recent payments (income) - simplified query
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

      _recentMovements = movements.take(10).toList();
    } catch (e) {
      debugPrint('Error loading recent movements: $e');
      _recentMovements = [];
    }
  }

  Future<void> _loadWeeklySales() async {
    try {
      if (_businessId == null) return;

      final cacheKey = 'weekly_sales_v1_$_businessId';

      // Función auxiliar para parsear y actualizar el estado
      void updateStateFromData(Map<String, dynamic> data) {
        _weeklySales = List<double>.from(
          data['weekly_sales'] ?? List.filled(7, 0.0),
        );
        _totalWeeklySales =
            (data['total_weekly_sales'] as num?)?.toDouble() ?? 0.0;
        _weeklyAverage = (data['weekly_average'] as num?)?.toDouble() ?? 0.0;
        _bestDayAmount = (data['best_day_amount'] as num?)?.toDouble() ?? 0.0;
        _bestDayName = data['best_day_name'] ?? '-';
        notifyListeners();
      }

      // Función para obtener desde API
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

      // 1. Carga RÁPIDA desde caché local
      final cached = await CacheManager().get<Map<String, dynamic>>(
        key: cacheKey,
        strategy: CacheStrategy.cacheOnly,
        fromJson: (json) => Map<String, dynamic>.from(json),
        fetchFromApi: fetchFromApi,
      );

      if (cached != null) {
        updateStateFromData(cached);
      }

      // 2. Carga FRESCA desde red (siempre actualiza)
      final fresh = await CacheManager().get<Map<String, dynamic>>(
        key: cacheKey,
        strategy: CacheStrategy.networkOnly,
        ttl: const Duration(minutes: 30),
        fromJson: (json) => Map<String, dynamic>.from(json),
        fetchFromApi: fetchFromApi,
      );

      if (fresh != null) {
        updateStateFromData(fresh);
      }
    } catch (e) {
      debugPrint('Error loading weekly sales: $e');
    }
  }

  Future<void> _loadActiveSessions() async {
    try {
      if (_businessId == null) {
        _activeSessions = [];
        return;
      }

      final cacheKey = 'active_sessions_v1_$_businessId';

      // Función auxiliar para parsear y actualizar el estado
      void updateStateFromData(Map<String, dynamic> data) {
        final sessionsList = data['sessions'] as List;
        _activeSessions = sessionsList
            .map((s) => TableSession.fromMap(s as Map<String, dynamic>))
            .toList();

        _sessionTotals = Map<String, double>.from(data['totals'] ?? {});
        notifyListeners();
      }

      // Función para obtener desde API
      Future<Map<String, dynamic>> fetchFromApi() async {
        final sessions = await _salesRepository.getActiveSessions(_businessId!);

        Map<String, double> sessionTotals = {};
        if (sessions.isNotEmpty) {
          final sessionIds = sessions.map((s) => s.id).toList();
          final client = Supabase.instance.client;

          final ordersData = await client
              .from('orders')
              .select('session_id, total')
              .inFilter('session_id', sessionIds)
              .neq('status', 'paid')
              .neq('status', 'cancelled');

          for (final order in ordersData) {
            final sessionId = order['session_id'] as String;
            final total = (order['total'] as num).toDouble();
            sessionTotals[sessionId] = (sessionTotals[sessionId] ?? 0) + total;
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

      // 1. Carga RÁPIDA desde caché local
      final cached = await CacheManager().get<Map<String, dynamic>>(
        key: cacheKey,
        strategy: CacheStrategy.cacheOnly,
        fromJson: (json) => Map<String, dynamic>.from(json),
        fetchFromApi: fetchFromApi,
      );

      if (cached != null) {
        updateStateFromData(cached);
      }

      // 2. Carga FRESCA desde red (siempre)
      final fresh = await CacheManager().get<Map<String, dynamic>>(
        key: cacheKey,
        strategy: CacheStrategy.networkOnly,
        ttl: const Duration(minutes: 5),
        fromJson: (json) => Map<String, dynamic>.from(json),
        fetchFromApi: fetchFromApi,
      );

      if (fresh != null) {
        updateStateFromData(fresh);
      }
    } catch (e) {
      debugPrint('Error loading active sessions: $e');
      if (_activeSessions.isEmpty) {
        _activeSessions = [];
        notifyListeners();
      }
    }
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
      await _repository.openSession(
        cashRegisterId: _currentRegisterId!,
        userId: userId,
        startAmount: amount,
      );
      await init(); // Refresh
    } catch (e) {
      rethrow;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> refreshSilently() async {
    try {
      if (_currentRegisterId != null && _businessId != null) {
        _lastSession = await _repository.getLastSession(_currentRegisterId!);
        _lastCashOpenValidationAt = AppTime.nowAst();
        _pendingTables = await _salesRepository.getOpenTablesCount(
          _businessId!,
        );
        await _loadTodaySummary();
        await _loadRecentMovements();
        await _loadActiveSessions();
        await _loadWeeklySales();
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

      _lastSession = await _repository.getLastSession(_currentRegisterId!);
      _lastCashOpenValidationAt = now;
      return _lastSession?['status'] == 'open';
    } catch (e) {
      debugPrint('Error validating cash session quickly: $e');
      return _lastSession?['status'] == 'open';
    }
  }
}
