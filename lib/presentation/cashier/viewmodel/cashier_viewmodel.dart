import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/sales_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart'; // Import to access salesRepositoryProvider if defined there, or just define injection here.

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

  CashierViewModel(this._repository, this._salesRepository);

  bool get isLoading => _isLoading;
  Map<String, dynamic>? get lastSession => _lastSession;
  int get pendingTables => _pendingTables;

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
        }
      }
    } catch (e) {
      debugPrint('Error loading cashier data: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
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
}
