import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// 🎬 Botones de acción del carrito.
///
/// Renderiza (en orden visual):
///   1. **Enviar a Cocina** (sólo si hay items draft).
///   2. **Pagar** (siempre que haya items y `payTotal > 0`).
///   3. **Dividir cuenta** (secundario, sólo si hay items y >= 2 productos).
///   4. **Descuento** (secundario, sólo si hay items).
///
/// Diseño puro: el widget NO ejecuta lógica de negocio. Sólo emite callbacks.
/// La vista que lo embebe se encarga de coordinar con `sales_viewmodel`.
///
/// Diferencias entre modos (Quick/Manual/Zone):
/// - Quick y Manual: pueden no tener "dividir cuenta" inicialmente (config OQ4-3 = sí en PRD 4).
/// - Manual: el callback `onSendToKitchen` y `onPay` típicamente abren un
///   `TableSelectorModal` antes de continuar el flujo.
class OrderActionButtons extends StatelessWidget {
  /// Total a pagar (lo que se muestra en el botón "Pagar RD\$ X").
  final double payTotal;

  /// Cantidad de items con `status == 'draft'`. Si es 0, "Enviar a Cocina"
  /// no aparece.
  final int draftItemsCount;

  /// Cantidad total de items (todos los status no-void). Define si los
  /// botones secundarios aparecen.
  final int totalItemsCount;

  /// Callback al tocar "Enviar a Cocina". Si es null, el botón se renderiza
  /// pero deshabilitado.
  final VoidCallback? onSendToKitchen;

  /// Callback al tocar "Pagar". Si es null, el botón aparece deshabilitado.
  final VoidCallback? onPay;

  /// Callback al tocar "Dividir cuenta". Si es null, el botón no aparece.
  final VoidCallback? onSplitBill;

  /// Callback al tocar "Descuento". Si es null, el botón no aparece.
  final VoidCallback? onApplyDiscount;

  /// Si está bloqueado (ej. caja cerrada), todos los botones quedan
  /// deshabilitados con un tooltip.
  final String? lockedReason;

  const OrderActionButtons({
    super.key,
    required this.payTotal,
    required this.draftItemsCount,
    required this.totalItemsCount,
    this.onSendToKitchen,
    this.onPay,
    this.onSplitBill,
    this.onApplyDiscount,
    this.lockedReason,
  });

  @override
  Widget build(BuildContext context) {
    if (totalItemsCount == 0) {
      return const SizedBox.shrink();
    }

    final currency = NumberFormat('#,##0.00', 'en_US');
    final isLocked = lockedReason != null;
    final hasDrafts = draftItemsCount > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        children: [
          if (isLocked) ...[
            _LockedBanner(reason: lockedReason!),
            const SizedBox(height: 12),
          ],

          // 1. Enviar Pedido (si hay drafts).
          //
          // Renombrado 2026-05-27: antes "Enviar a Cocina". El label nuevo
          // funciona también para negocios sin cocina (kioskos/minimarkets)
          // que igualmente quieran usar el flujo de "confirmar pedido".
          if (hasDrafts) ...[
            _PrimaryButton(
              label: 'Enviar Pedido',
              icon: Icons.soup_kitchen_outlined,
              background: const Color(0xFFF97316),
              onPressed: isLocked ? null : onSendToKitchen,
            ),
            const SizedBox(height: 10),
          ],

          // 2. Pagar
          _PrimaryButton(
            label: 'Pagar RD\$ ${currency.format(payTotal)}',
            icon: Icons.payment_outlined,
            background: const Color(0xFF22C55E),
            onPressed: (isLocked || payTotal <= 0) ? null : onPay,
          ),

          // 3 + 4. Acciones secundarias (split + descuento)
          if (onSplitBill != null || onApplyDiscount != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (onSplitBill != null && totalItemsCount >= 2)
                  Expanded(
                    child: _SecondaryButton(
                      label: 'Dividir',
                      icon: Icons.call_split,
                      onPressed: isLocked ? null : onSplitBill,
                    ),
                  ),
                if (onSplitBill != null &&
                    totalItemsCount >= 2 &&
                    onApplyDiscount != null)
                  const SizedBox(width: 8),
                if (onApplyDiscount != null)
                  Expanded(
                    child: _SecondaryButton(
                      label: 'Descuento',
                      icon: Icons.percent,
                      onPressed: isLocked ? null : onApplyDiscount,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color background;
  final VoidCallback? onPressed;

  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.background,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white, size: 20),
        label: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          disabledBackgroundColor: const Color(0xFFE5E7EB),
          disabledForegroundColor: const Color(0xFF9CA3AF),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          elevation: 0,
        ),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const _SecondaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18, color: const Color(0xFFF97316)),
      label: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF2C2C2C),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFFE5E7EB), width: 1),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}

class _LockedBanner extends StatelessWidget {
  final String reason;
  const _LockedBanner({required this.reason});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 16, color: Color(0xFFDC2626)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              reason,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF991B1B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
