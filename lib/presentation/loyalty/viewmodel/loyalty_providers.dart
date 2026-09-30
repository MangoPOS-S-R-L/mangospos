import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/loyalty_models.dart';
import '../../../data/repositories/loyalty_repository.dart';

final loyaltyRepositoryProvider = Provider<LoyaltyRepository>((ref) {
  return LoyaltyRepository(Supabase.instance.client);
});

/// Tarjetas de sellos de un cliente (programas activos del negocio).
///
/// Sin reintento automático: si falla (sin internet, migración sin aplicar)
/// la pantalla lo dice una vez y ofrece reintentar, en vez de martillar.
/// Tras canjear, quitar un premio o ajustar, invalidar con el mismo id.
final customerLoyaltyCardsProvider = FutureProvider.autoDispose
    .family<List<LoyaltyCard>, String>(
      (ref, customerId) =>
          ref.read(loyaltyRepositoryProvider).getCustomerCards(customerId),
      retry: (retryCount, error) => null,
    );
