import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../../../services/fiscal/fiscal_service.dart';
import '../../../../../../data/models/fiscal_models.dart';
import '../../../../../../services/session/session_controller.dart';

final fiscalVmProvider = NotifierProvider<FiscalViewModel, FiscalState>(
  () => FiscalViewModel(),
);

class FiscalState {
  final List<FiscalNcfSequence> sequences;
  final bool isLoading;
  final String? error;
  final bool preferElectronicBilling;
  final String fiscalRnc;
  final String fiscalName;

  FiscalState({
    this.sequences = const [],
    this.isLoading = false,
    this.error,
    this.preferElectronicBilling = false,
    this.fiscalRnc = '',
    this.fiscalName = '',
  });

  FiscalState copyWith({
    List<FiscalNcfSequence>? sequences,
    bool? isLoading,
    String? error,
    bool? preferElectronicBilling,
    String? fiscalRnc,
    String? fiscalName,
  }) {
    return FiscalState(
      sequences: sequences ?? this.sequences,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      preferElectronicBilling:
          preferElectronicBilling ?? this.preferElectronicBilling,
      fiscalRnc: fiscalRnc ?? this.fiscalRnc,
      fiscalName: fiscalName ?? this.fiscalName,
    );
  }
}

class FiscalViewModel extends Notifier<FiscalState> {
  @override
  FiscalState build() => FiscalState();

  Future<void> load(String businessId) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final bizId = businessId == 'auto'
          ? ref.read(sessionProvider).activeBusinessId ?? ''
          : businessId;

      if (bizId.isEmpty) {
        state = state.copyWith(
          isLoading: false,
          error: 'No se encontró un ID de negocio válido.',
        );
        return;
      }

      final seqs = await ref.read(fiscalServiceProvider).getSequences(bizId);
      final settings = await ref
          .read(fiscalServiceProvider)
          .getBusinessFiscalSettings(bizId);

      state = state.copyWith(
        sequences: seqs,
        isLoading: false,
        preferElectronicBilling: settings['ecf_enabled'] ?? false,
        fiscalRnc: settings['rnc'] ?? '',
        fiscalName: settings['business_legal_name'] ?? '',
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> toggleElectronicBilling(String businessId, bool value) async {
    try {
      final bizId = businessId == 'auto'
          ? ref.read(sessionProvider).activeBusinessId ?? ''
          : businessId;
      await ref
          .read(fiscalServiceProvider)
          .updateBusinessFiscalSettings(bizId, {
            'rnc': state.fiscalRnc,
            'business_legal_name': state.fiscalName,
            'ecf_enabled': value,
            'default_ncf_type': value ? 'E32' : 'B02',
          });
      state = state.copyWith(preferElectronicBilling: value);
    } catch (e) {
      state = state.copyWith(error: 'Error al cambiar modalidad: $e');
    }
  }

  Future<void> updateFiscalInfo(
    String businessId, {
    required String rnc,
    required String name,
  }) async {
    try {
      final bizId = businessId == 'auto'
          ? ref.read(sessionProvider).activeBusinessId ?? ''
          : businessId;
      await ref
          .read(fiscalServiceProvider)
          .updateBusinessFiscalSettings(bizId, {
            'rnc': rnc,
            'business_legal_name': name,
            'ecf_enabled': state.preferElectronicBilling,
            'default_ncf_type': state.preferElectronicBilling ? 'E32' : 'B02',
          });
      state = state.copyWith(fiscalRnc: rnc, fiscalName: name);
    } catch (e) {
      state = state.copyWith(error: 'Error al guardar datos fiscales: $e');
    }
  }

  Future<void> addSequence(
    String businessId, {
    required String tipo,
    required String serie,
    required int ultimoSeq,
    required int maximoSeq,
  }) async {
    try {
      final bizId = businessId == 'auto'
          ? ref.read(sessionProvider).activeBusinessId ?? ''
          : businessId;
      await ref
          .read(fiscalServiceProvider)
          .initializeSequence(
            businessId: bizId,
            tipo: tipo,
            serie: serie,
            ultimoSeq: ultimoSeq,
            maximoSeq: maximoSeq,
          );
      await load(businessId); // Recargar
    } catch (e) {
      state = state.copyWith(error: 'Error al agregar secuencia: $e');
    }
  }

  Future<void> saveSequence(String id, Map<String, dynamic> data) async {
    try {
      await ref.read(fiscalServiceProvider).updateSequence(id, data);
      // Actualización rápida local
      final newSeqs = state.sequences.map((s) {
        if (s.id == id) {
          return s.copyWith(
            ultimoSeq: data['current_number'] ?? s.ultimoSeq,
            maximoSeq: data['range_end'] ?? s.maximoSeq,
            activo: data['is_active'] ?? s.activo,
          );
        }
        return s;
      }).toList();
      state = state.copyWith(sequences: newSeqs);
    } catch (e) {
      state = state.copyWith(error: 'Error al actualizar secuencia: $e');
    }
  }
}
