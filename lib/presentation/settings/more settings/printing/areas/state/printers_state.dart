import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/models/printing.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/printing/models.dart';
import 'package:mangopos/data/printing/printing_repository.dart';

/// Repo provider (inyecta SupabaseClient)
final printersRepoProvider = Provider<PrintingRepository>((ref) {
  final client = Supabase.instance.client;
  return PrintingRepository(client);
});

/// Lista read-only de impresoras (útil para combos, selects, etc.)
final printersListProvider =
    FutureProvider.family<List<PrinterDevice>, String>((ref, businessIdOrAuto) async {
  final repo = ref.read(printersRepoProvider);
  final bid = await _resolveBusinessId(businessIdOrAuto);
  return repo.getPrinters(bid);
});

/// Helper para resolver el negocio activo si se pasa 'auto' o vacío.
Future<String> _resolveBusinessId(String businessIdOrAuto) async {
  if (businessIdOrAuto.isEmpty || businessIdOrAuto == 'auto') {
    return await BusinessResolver.resolveActiveBusinessId();
  }
  return businessIdOrAuto;
}
