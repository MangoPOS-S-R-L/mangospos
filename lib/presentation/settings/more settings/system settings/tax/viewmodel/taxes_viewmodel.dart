import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/repositories/tax_repository.dart';
import '../state/taxes_state.dart';

final taxesVmProvider =
    NotifierProvider<TaxesVm, TaxesState>(TaxesVm.new);

class TaxesVm extends Notifier<TaxesState> {
  final _repo = TaxRepository();
  late String _businessId;

  String get businessId => _businessId;

  @override
  TaxesState build() => const TaxesState();

  Future<void> load({required String businessId}) async {
    _businessId = businessId;
    state = state.copyWith(data: const AsyncLoading());

    try {
      final list = await _repo.list(_businessId);
      state = state.copyWith(data: AsyncData(list));
    } catch (e, st) {
      state = state.copyWith(data: AsyncError(e, st));
    }
  }

  Future<void> refresh() => load(businessId: _businessId);

  void setSearch(String q) => state = state.copyWith(search: q);

  void select(String? id) => state = state.copyWith(selectedId: id);

  Future<void> create({
    required String name,
    required double rate,
    bool isActive = true,
    bool applyOnZone = true,
    bool applyOnManual = true,
    bool applyOnQuick = true,
    bool applyOnDelivery = true,
    bool applyOnTakeout = true,
    bool isServiceFee = false,
  }) async {
    await _repo.create(
      businessId: _businessId,
      name: name,
      rate: rate,
      isActive: isActive,
      applyOnZone: applyOnZone,
      applyOnManual: applyOnManual,
      applyOnQuick: applyOnQuick,
      applyOnDelivery: applyOnDelivery,
      applyOnTakeout: applyOnTakeout,
      isServiceFee: isServiceFee,
    );
    await refresh();
  }


  Future<void> update(
    String id, {
    String? name,
    double? rate,
    bool? isActive,
    bool? applyOnZone,
    bool? applyOnManual,
    bool? applyOnQuick,
    bool? applyOnDelivery,
    bool? applyOnTakeout,
    bool? isServiceFee,
  }) async {
    final patch = <String, dynamic>{
      if (name != null) 'name': name,
      if (rate != null) 'rate': rate,
      if (isActive != null) 'is_active': isActive,
      if (applyOnZone != null) 'apply_on_zone': applyOnZone,
      if (applyOnManual != null) 'apply_on_manual': applyOnManual,
      if (applyOnQuick != null) 'apply_on_quick': applyOnQuick,
      if (applyOnDelivery != null) 'apply_on_delivery': applyOnDelivery,
      if (applyOnTakeout != null) 'apply_on_takeout': applyOnTakeout,
      if (isServiceFee != null) 'is_service_fee': isServiceFee,
    };
    await _repo.update(id, patch);
    await refresh();
  }


  Future<void> toggleActive(String id, bool v) async {
    await _repo.update(id, {'is_active': v});
    await refresh();
  }

  Future<void> remove(String id) async {
    await _repo.remove(id);
    if (state.selectedId == id) {
      state = state.copyWith(clearSelected: true);
    }
    await refresh();
  }
}
