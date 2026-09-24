// Ajustes → Integraciones.
//
// Por ahora un solo canal (Pincer), pero la pantalla ya está armada como lista:
// Uber Eats y PedidosYa entran agregando una tarjeta, porque el motor de abajo
// es el mismo (`external_*`, un `channel` distinto).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'channel_link_card.dart';

class IntegrationsView extends ConsumerWidget {
  const IntegrationsView({required this.businessId, super.key});

  /// 'auto' resuelve el negocio activo, igual que el resto de Ajustes.
  final String businessId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: MangoColors.appBackground,
      appBar: AppBar(
        title: const Text('Integraciones'),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: FutureBuilder<String>(
        future: BusinessResolver.ensure(businessId),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final id = snap.data;
          if (id == null || id.isEmpty) {
            return const Center(
              child: Text('No se pudo determinar el negocio activo'),
            );
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Pedidos en línea',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Conecta la plataforma donde tus clientes ordenan y los '
                      'pedidos entran solos al POS: van a cocina, imprimen '
                      'comanda y cuadran en la caja como cualquier venta.',
                      style: TextStyle(fontSize: 13, color: MangoColors.muted),
                    ),
                    const SizedBox(height: 16),
                    ChannelLinkCard(businessId: id),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: MangoColors.bgLight,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '¿Cómo funciona?',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: MangoColors.darkGray,
                            ),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Al tocar Conectar sale un código de 8 caracteres. '
                            'Se lo das a la plataforma —puedes dictarlo por '
                            'teléfono— y ellos lo canjean para quedar '
                            'conectados. El código vence en 15 minutos y sirve '
                            'una sola vez.\n\n'
                            'Tus claves de acceso nunca se muestran ni se '
                            'envían por mensaje: viajan directo entre los dos '
                            'sistemas. Si algún día quieres cortar el acceso, '
                            'Desconectar lo corta al instante.',
                            style: TextStyle(
                              fontSize: 12,
                              color: MangoColors.muted,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
