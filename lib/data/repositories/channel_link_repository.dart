// Conectar un canal de pedidos (Pincer) desde Ajustes → Integraciones.
//
// El dueño genera un código corto, se lo pasa al canal, y el canal lo canjea
// contra `channel-link` para recibir sus credenciales servidor a servidor. Las
// llaves NUNCA pasan por esta app: acá solo se ve el código y el estado.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Estado del canal para la tarjeta de Ajustes.
class ChannelLinkStatus {
  const ChannelLinkStatus({
    required this.connected,
    this.environment,
    this.keyPrefix,
    this.connectedAt,
    this.lastUsedAt,
    this.ordersToday = 0,
    this.ordersTotal = 0,
    this.lastOrderAt,
    this.pendingCode,
    this.pendingCodeExpiresAt,
  });

  final bool connected;
  final String? environment;
  final String? keyPrefix;
  final DateTime? connectedAt;
  final DateTime? lastUsedAt;
  final int ordersToday;
  final int ordersTotal;
  final DateTime? lastOrderAt;

  /// Código vivo sin canjear, si el dueño acaba de generarlo.
  final String? pendingCode;
  final DateTime? pendingCodeExpiresAt;

  bool get esPrueba => environment == 'sandbox';

  static DateTime? _fecha(dynamic v) =>
      v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

  factory ChannelLinkStatus.fromMap(Map<String, dynamic> m) {
    final pend = m['pending_code'] as Map<String, dynamic>?;
    return ChannelLinkStatus(
      connected: m['connected'] == true,
      environment: m['environment'] as String?,
      keyPrefix: m['key_prefix'] as String?,
      connectedAt: _fecha(m['connected_at']),
      lastUsedAt: _fecha(m['last_used_at']),
      ordersToday: (m['orders_today'] as num?)?.toInt() ?? 0,
      ordersTotal: (m['orders_total'] as num?)?.toInt() ?? 0,
      lastOrderAt: _fecha(m['last_order_at']),
      pendingCode: pend?['code'] as String?,
      pendingCodeExpiresAt: _fecha(pend?['expires_at']),
    );
  }

  static const desconectado = ChannelLinkStatus(connected: false);
}

class ChannelLinkRepository {
  ChannelLinkRepository(this._client);
  final SupabaseClient _client;

  Future<ChannelLinkStatus> status({
    required String businessId,
    String channel = 'pincer',
  }) async {
    final res = await _client.rpc(
      'fn_channel_link_status',
      params: {'p_business_id': businessId, 'p_channel': channel},
    );
    if (res is! Map) return ChannelLinkStatus.desconectado;
    return ChannelLinkStatus.fromMap(Map<String, dynamic>.from(res));
  }

  /// Genera el código de vinculación. Solo dueño o administrador; el RPC lo
  /// valida del lado del servidor, no acá.
  Future<({String code, DateTime expiresAt})> createCode({
    required String businessId,
    String channel = 'pincer',
    String environment = 'production',
  }) async {
    final res = await _client.rpc(
      'fn_create_channel_link_code',
      params: {
        'p_business_id': businessId,
        'p_channel': channel,
        'p_environment': environment,
      },
    );
    final m = Map<String, dynamic>.from(res as Map);
    return (
      code: m['code'] as String,
      expiresAt:
          DateTime.tryParse('${m['expires_at']}')?.toLocal() ??
          DateTime.now().add(const Duration(minutes: 15)),
    );
  }

  /// Revoca la credencial: el canal deja de poder mandar pedidos al instante.
  Future<int> disconnect({
    required String businessId,
    String channel = 'pincer',
  }) async {
    final res = await _client.rpc(
      'fn_disconnect_channel',
      params: {'p_business_id': businessId, 'p_channel': channel},
    );
    if (res is! Map) return 0;
    return (res['revoked'] as num?)?.toInt() ?? 0;
  }
}

final channelLinkRepositoryProvider = Provider<ChannelLinkRepository>(
  (ref) => ChannelLinkRepository(Supabase.instance.client),
);

/// Estado del canal, recargable tras conectar o desconectar.
final channelLinkStatusProvider =
    FutureProvider.family<ChannelLinkStatus, ({String businessId, String channel})>(
      (ref, arg) => ref
          .read(channelLinkRepositoryProvider)
          .status(businessId: arg.businessId, channel: arg.channel),
    );
