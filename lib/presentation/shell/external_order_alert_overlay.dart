// Aviso en esquina de los pedidos que entran por un canal externo (Pincer).
//
// Se monta una sola vez, encima del shell, para que se vea sin importar en qué
// pantalla esté el equipo. A diferencia de `AppToast` —que se descarta solo y
// nunca se acumula, porque avisa del resultado de algo que el usuario acaba de
// hacer— esto se QUEDA hasta que alguien lo cierre: un pedido que entró solo no
// lo vio nadie todavía, y tiene que prepararse.
//
// Se apilan hasta 3; de ahí en adelante se cuentan. En una hora pico con ocho
// pedidos seguidos, ocho tarjetas taparían la pantalla de trabajo.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/printing/external_order_alerts.dart';

class ExternalOrderAlertOverlay extends ConsumerWidget {
  const ExternalOrderAlertOverlay({super.key});

  static const _maxVisible = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final alerts = ref.watch(externalOrderAlertsProvider);
    if (alerts.isEmpty) return const SizedBox.shrink();

    final visibles = alerts.take(_maxVisible).toList(growable: false);
    final ocultos = alerts.length - visibles.length;

    return Positioned(
      top: 12,
      right: 12,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final alert in visibles)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _AlertCard(
                  alert: alert,
                  onClose: () => ref
                      .read(externalOrderAlertsProvider.notifier)
                      .dismiss(alert.id),
                ),
              ),
            if (ocultos > 0)
              _MoreChip(
                count: ocultos,
                onClearAll: () =>
                    ref.read(externalOrderAlertsProvider.notifier).dismissAll(),
              ),
          ],
        ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.onClose});

  final ExternalOrderAlert alert;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // El pickup se distingue por color: el personal tiene que saber de un
    // vistazo si el pedido lo viene a buscar alguien o sale en moto.
    final acento = alert.serviceType == 'pickup'
        ? MangoColors.infoBlue
        : MangoColors.primaryOrange;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MangoColors.cardBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Barra de color del canal + cerrar
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              decoration: BoxDecoration(
                color: acento,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(11),
                  topRight: Radius.circular(11),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.receipt_long,
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Pedido nuevo · ${alert.channelLabel}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                    color: Colors.white,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Descartar aviso',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // El número del canal va GRANDE: es como el personal
                  // identifica el pedido cuando el cliente lo viene a buscar.
                  if (alert.number != null && alert.number!.isNotEmpty)
                    Text(
                      '#${alert.number}',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: acento,
                        height: 1.1,
                      ),
                    ),
                  const SizedBox(height: 4),
                  // Wrap y no Row: 'Para llevar' + 'Cobrar al entregar' no
                  // caben juntos en los 320 px de la tarjeta y salía la franja
                  // de overflow. Con Wrap el segundo chip baja de línea.
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _Chip(text: alert.serviceLabel, color: acento),
                      if (alert.paid)
                        const _Chip(
                          text: 'Pagado',
                          color: MangoColors.successGreen,
                        )
                      else
                        const _Chip(
                          text: 'Cobrar al entregar',
                          color: MangoColors.muted,
                        ),
                    ],
                  ),
                  if (alert.customerName != null &&
                      alert.customerName!.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      alert.customerName!,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: MangoColors.darkGray,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (alert.total != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'RD\$ ${alert.total!.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: MangoColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _MoreChip extends StatelessWidget {
  const _MoreChip({required this.count, required this.onClearAll});

  final int count;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onClearAll,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: MangoColors.darkGray,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '+$count más · descartar todos',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
