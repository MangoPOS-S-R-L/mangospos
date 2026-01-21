import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/repositories/customers_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';

final customersRepositoryProvider = Provider<CustomersRepository>((ref) {
  return CustomersRepository(Supabase.instance.client);
});

final customersViewModelProvider = ChangeNotifierProvider<CustomersViewModel>((
  ref,
) {
  return CustomersViewModel(ref.read(customersRepositoryProvider));
});

class CustomersViewModel extends ChangeNotifier {
  final CustomersRepository _repository;

  bool _isLoading = false;
  List<Map<String, dynamic>> _customers = [];
  String? _businessId;

  CustomersViewModel(this._repository);

  bool get isLoading => _isLoading;
  List<Map<String, dynamic>> get customers => _customers;

  Future<void> init() async {
    _isLoading = true;
    notifyListeners();
    try {
      final client = Supabase.instance.client;
      _businessId = await resolveBusinessIdOrNull(client, 'auto');
      if (_businessId != null) {
        await _fetchCustomers();
      }
    } catch (e) {
      debugPrint('Error loading customers: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _fetchCustomers() async {
    if (_businessId == null) return;
    _customers = await _repository.getCustomers(_businessId!);
  }

  Future<void> addCustomer(Map<String, dynamic> data) async {
    if (_businessId == null) return;
    try {
      final payload = {...data, 'business_id': _businessId};
      await _repository.createCustomer(payload);
      await _fetchCustomers();
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> updateCustomer(String id, Map<String, dynamic> data) async {
    try {
      await _repository.updateCustomer(id, data);
      await _fetchCustomers();
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> deleteCustomer(String id) async {
    try {
      await _repository.deleteCustomer(id);
      await _fetchCustomers();
      notifyListeners();
    } catch (e) {
      rethrow;
    }
  }

  Future<void> search(String query) async {
    if (_businessId == null) return;
    _isLoading = true;
    notifyListeners();
    try {
      _customers = await _repository.getCustomers(_businessId!, query: query);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
