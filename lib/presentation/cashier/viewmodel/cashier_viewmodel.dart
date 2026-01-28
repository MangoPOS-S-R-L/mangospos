import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/data/models/sales_models.dart';
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
  String? _businessId;
  Map<String, dynamic> _todaySummary = {};
  List<Map<String, dynamic>> _recentMovements = [];
  List<TableSession> _activeSessions = [];
  List<double> _weeklySales = List.filled(7, 0.0);
  double _totalWeeklySales = 0.0;
  double _weeklyAverage = 0.0;
  double _bestDayAmount = 0.0;
  String _bestDayName = '';

  CashierViewModel(this._repository, this._salesRepository);

  bool get isLoading => _isLoading;
  Map<String, dynamic>? get lastSession => _lastSession;
  int get pendingTables => _pendingTables;
  Map<String, dynamic> get todaySummary => _todaySummary;
  List<Map<String, dynamic>> get recentMovements => _recentMovements;
  List<TableSession> get activeSessions => _activeSessions;
  List<double> get weeklySales => _weeklySales;
  double get totalWeeklySales => _totalWeeklySales;
  double get weeklyAverage => _weeklyAverage;
  double get bestDayAmount => _bestDayAmount;
  String get bestDayName => _bestDayName;

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      _businessId = await resolveBusinessIdOrNull(client, 'auto');

      if (_businessId != null) {
        final registers = await _repository.getCashRegisters(_businessId!);
        if (registers.isNotEmpty) {
          _currentRegisterId = registers.first['id'] as String;
        } else {
          final created = await _repository.createCashRegister(
            businessId: _businessId!,
            name: 'Caja principal',
          );
          _currentRegisterId = created['id'] as String;
        }
        if (_currentRegisterId != null) {
          _lastSession = await _repository.getLastSession(_currentRegisterId!);
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
      final now = DateTime.now();
      final startOfDayDate = DateTime.utc(now.year, now.month, now.day);
      final endOfDayDate = startOfDayDate.add(const Duration(days: 1));
      final startOfDay = startOfDayDate.toIso8601String();
      final endOfDay = endOfDayDate.toIso8601String();

      debugPrint('Loading summary for business: $_businessId');
      debugPrint('Start of day: $startOfDay');

      // Get payments for today
      final paymentsData = await client
          .from('payments')
          .select('amount, created_at')
          .gte('created_at', startOfDay)
          .lt('created_at', endOfDay)
          .eq('status', 'completed')
          .eq('business_id', _businessId!);

      debugPrint('Payments found: ${paymentsData.length}');

      double totalIncome = 0.0;
      int transactionCount = 0;

      transactionCount = paymentsData.length;
      for (var payment in paymentsData) {
        final amount = payment['amount'];
        if (amount != null) {
          // Convert to double safely
          if (amount is num) {
            totalIncome += amount.toDouble();
          } else if (amount is String) {
            totalIncome += double.tryParse(amount) ?? 0.0;
          }
        }
      }

      debugPrint(
        'Total income calculated: $totalIncome from $transactionCount transactions',
      );

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

          debugPrint('Cash movements found: ${movementsData.length}');

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

      debugPrint('Total expenses calculated: $totalExpenses');

      _todaySummary = {
        'total_income': totalIncome,
        'total_expenses': totalExpenses,
        'transaction_count': transactionCount,
      };

      debugPrint('Summary updated: $_todaySummary');
    } catch (e) {
      debugPrint('Error loading today summary: $e');
      debugPrint('Stack trace: ${StackTrace.current}');
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
        debugPrint('Cannot load movements: business_id is null');
        _recentMovements = [];
        return;
      }

      debugPrint('Loading recent movements for business: $_businessId');

      final client = Supabase.instance.client;
      final today = DateTime.now();
      final startOfDayDate = DateTime.utc(today.year, today.month, today.day);
      final endOfDayDate = startOfDayDate.add(const Duration(days: 1));
      final startOfDay = startOfDayDate.toIso8601String();
      final endOfDay = endOfDayDate.toIso8601String();

      // Get recent payments (income) - simplified query
      final paymentsData = await client
          .from('payments')
          .select('id, amount, payment_method_id, created_at, order_id')
          .gte('created_at', startOfDay)
          .lt('created_at', endOfDay)
          .eq('status', 'completed')
          .eq('business_id', _businessId!)
          .order('created_at', ascending: false)
          .limit(15);

      debugPrint('Recent payments found: ${paymentsData.length}');

      List<Map<String, dynamic>> movements = [];

      for (var payment in paymentsData) {
        String description = 'Venta';

        // Try to get a better description from order
        if (payment['order_id'] != null) {
          try {
            final orderData = await client
                .from('orders')
                .select('id, table_id')
                .eq('id', payment['order_id'])
                .maybeSingle();

            if (orderData != null && orderData is Map<String, dynamic>) {
              if (orderData['table_id'] != null) {
                // Try to get table name
                final tableData = await client
                    .from('tables')
                    .select('table_code')
                    .eq('id', orderData['table_id'])
                    .maybeSingle();

                if (tableData != null && tableData is Map<String, dynamic>) {
                  description = 'Venta ${tableData['table_code'] ?? 'Mesa'}';
                }
              } else {
                description =
                    'Venta #${(orderData['id'] ?? payment['id']).toString().substring(0, 8)}';
              }
            }
          } catch (e) {
            debugPrint('Could not get order details: $e');
            // Continue with default description
          }
        }

        // Get amount safely
        double amount = 0.0;
        final paymentAmount = payment['amount'];
        if (paymentAmount != null) {
          if (paymentAmount is num) {
            amount = paymentAmount.toDouble();
          } else if (paymentAmount is String) {
            amount = double.tryParse(paymentAmount) ?? 0.0;
          }
        }

        movements.add({
          'type': 'income',
          'description': description,
          'amount': amount,
          'created_at': payment['created_at'],
        });
      }

      debugPrint('Processed ${movements.length} income movements');

      // Get recent expenses (if any)
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

          debugPrint('Recent expenses found: ${expensesData.length}');

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

      // Sort by created_at descending
      movements.sort((a, b) {
        try {
          final aDate = DateTime.parse(
            a['created_at'] ?? DateTime.now().toIso8601String(),
          );
          final bDate = DateTime.parse(
            b['created_at'] ?? DateTime.now().toIso8601String(),
          );
          return bDate.compareTo(aDate);
        } catch (e) {
          return 0;
        }
      });

      _recentMovements = movements.take(10).toList();
      debugPrint('Recent movements loaded: ${_recentMovements.length}');
    } catch (e) {
      debugPrint('Error loading recent movements: $e');
      debugPrint('Stack trace: ${StackTrace.current}');
      _recentMovements = [];
    }
  }

  Future<void> _loadWeeklySales() async {
    try {
      if (_businessId == null) return;

      final client = Supabase.instance.client;
      final now = DateTime.now();

      // Calculate start of current week (Monday)
      // weekday: 1=Mon, 7=Sun
      final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
      final startOfWeekDate = DateTime(
        startOfWeek.year,
        startOfWeek.month,
        startOfWeek.day,
      ); // 00:00:00

      // Calculate end of current week (Sunday end of day)
      final endOfWeekDate = startOfWeekDate.add(const Duration(days: 7));

      final payments = await client
          .from('payments')
          .select('amount, created_at')
          .gte(
            'created_at',
            startOfDayDate(startOfWeekDate),
          ) // Helper or inline? let's inline iso string
          .lt('created_at', startOfDayDate(endOfWeekDate))
          .eq('status', 'completed')
          .eq('business_id', _businessId!);

      // Reset counters
      _weeklySales = List.filled(7, 0.0);
      _totalWeeklySales = 0.0;
      _weeklyAverage = 0.0;
      _bestDayAmount = 0.0;
      _bestDayName = '-';

      if (payments.isEmpty) {
        notifyListeners();
        return;
      }

      for (var payment in payments) {
        final amount = (payment['amount'] as num?)?.toDouble() ?? 0.0;
        final dateStr = payment['created_at'] as String;
        final date = DateTime.parse(dateStr).toLocal();

        // Map weekday 1..7 to index 0..6
        // 1(Mon)-1 = 0
        final dayIndex = date.weekday - 1;
        if (dayIndex >= 0 && dayIndex < 7) {
          _weeklySales[dayIndex] += amount;
        }
      }

      // Calculate stats
      _totalWeeklySales = _weeklySales.reduce((a, b) => a + b);

      // Average over days that successfully passed (or 7? usually average daily sales considers passed days or full week?)
      // Image shows "Promedio Diario". Let's average over the full 7 days or just passed days?
      // Usually "in this period" implies dividing by 7 for standard comparison, or by passed days for "current pace".
      // Let's divide by 7 to be consistent with "Weekly Average" or maybe passed days?
      // Let's use 7 for simplicity of "Weekly Projected" or (now.weekday) for "Year to date" style.
      // Given it's a dashboard, usually it's "Total / 7" or "Total / Days with sales".
      // Let's use 7.
      _weeklyAverage = _totalWeeklySales / 7; // Simple average

      // Best day
      double maxVal = -1.0;
      int maxIdx = -1;
      for (int i = 0; i < 7; i++) {
        if (_weeklySales[i] > maxVal) {
          maxVal = _weeklySales[i];
          maxIdx = i;
        }
      }

      if (maxIdx != -1) {
        _bestDayAmount = maxVal;
        const days = [
          'Lunes',
          'Martes',
          'Miércoles',
          'Jueves',
          'Viernes',
          'Sábado',
          'Domingo',
        ];
        _bestDayName = days[maxIdx];
      }
    } catch (e) {
      debugPrint('Error loading weekly sales: $e');
    }
  }

  String startOfDayDate(DateTime d) => d
      .toIso8601String(); // Helper if needed, but simple enough to inline if strict

  Future<void> _loadActiveSessions() async {
    try {
      if (_businessId == null) {
        _activeSessions = [];
        return;
      }
      _activeSessions = await _salesRepository.getActiveSessions(_businessId!);
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading active sessions: $e');
      _activeSessions = [];
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

  /// Refresh data without showing loading indicator
  /// Useful for auto-refresh when sales are completed
  Future<void> refreshSilently() async {
    try {
      if (_currentRegisterId != null && _businessId != null) {
        _lastSession = await _repository.getLastSession(_currentRegisterId!);
        _pendingTables = await _salesRepository.getOpenTablesCount(
          _businessId!,
        );
        await _loadTodaySummary();
        await _loadRecentMovements();
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
}
