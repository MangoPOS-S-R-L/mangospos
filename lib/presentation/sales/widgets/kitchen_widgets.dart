import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';

// === SEND TO KITCHEN BUTTON WITH STATE MACHINE ===

enum KitchenButtonState { idle, validating, sending, success, error }

class _SendToKitchenButton extends ConsumerStatefulWidget {
  final String? orderId;

  const _SendToKitchenButton({this.orderId});

  @override
  ConsumerState<_SendToKitchenButton> createState() =>
      _SendToKitchenButtonState();
}

class _SendToKitchenButtonState extends ConsumerState<_SendToKitchenButton> {
  KitchenButtonState _state = KitchenButtonState.idle;

  Future<void> _handleSendToKitchen() async {
    final orderNotifier = ref.read(currentOrderProvider.notifier);
    final items = ref.read(currentOrderProvider).items;

    // Validation
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Agrega productos antes de enviar'),
          backgroundColor: Color(0xFFEF4444),
        ),
      );
      return;
    }

    try {
      setState(() => _state = KitchenButtonState.validating);
      await Future.delayed(const Duration(milliseconds: 300));

      setState(() => _state = KitchenButtonState.sending);

      // Send order to kitchen (via provider)
      await orderNotifier.confirmOrder();

      setState(() => _state = KitchenButtonState.success);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✓ Orden enviada a cocina'),
            backgroundColor: Color(0xFF22C55E),
          ),
        );
      }

      // Keep success state for 2 seconds
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() => _state = KitchenButtonState.idle);
      }
    } catch (e) {
      setState(() => _state = KitchenButtonState.error);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al enviar orden: ${e.toString()}'),
            backgroundColor: const Color(0xFFEF4444),
            action: SnackBarAction(
              label: 'Reintentar',
              onPressed: _handleSendToKitchen,
              textColor: Colors.white,
            ),
          ),
        );
      }

      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() => _state = KitchenButtonState.idle);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = _getButtonConfig();

    return SizedBox(
      width: double.infinity,
      height: 44,
      child: ElevatedButton.icon(
        onPressed: config['disabled'] ? null : _handleSendToKitchen,
        icon: Icon(config['icon'] as IconData, size: 20),
        label: Text(
          config['text'] as String,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: config['bgColor'] as Color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: (config['bgColor'] as Color).withOpacity(
            0.7,
          ),
          disabledForegroundColor: Colors.white70,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _getButtonConfig() {
    switch (_state) {
      case KitchenButtonState.idle:
        return {
          'text': 'Enviar a Cocina',
          'icon': Icons.restaurant,
          'bgColor': const Color(0xFFFB7116), // kPrimary
          'disabled': false,
        };
      case KitchenButtonState.validating:
        return {
          'text': 'Validando...',
          'icon': Icons.hourglass_empty,
          'bgColor': const Color(0xFFFB7116),
          'disabled': true,
        };
      case KitchenButtonState.sending:
        return {
          'text': 'Enviando...',
          'icon': Icons.cloud_upload,
          'bgColor': const Color(0xFFFB7116),
          'disabled': true,
        };
      case KitchenButtonState.success:
        return {
          'text': '✓ Orden en cocina',
          'icon': Icons.check_circle,
          'bgColor': const Color(0xFF22C55E), // kSuccess
          'disabled': true,
        };
      case KitchenButtonState.error:
        return {
          'text': '⚠ Error al enviar',
          'icon': Icons.error,
          'bgColor': const Color(0xFFEF4444), // kDestructive
          'disabled': false,
        };
    }
  }
}

// === PRE-BILL MODAL FUNCTION ===

void _showPreBillModal(BuildContext context, WidgetRef ref) {
  showDialog(
    context: context,
    builder: (BuildContext context) {
      return const _PreBillModal();
    },
  );
}

class _PreBillModal extends ConsumerWidget {
  const _PreBillModal();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderState = ref.watch(currentOrderProvider);
    final items = orderState.items;
    final total = (orderState.order?.total as num?)?.toDouble() ?? 0.0;
    final subtotal = total / 1.18;
    final tax = total - subtotal;
    final suggestedTip = subtotal * 0.10;

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(24),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFE0DBD9))),
              ),
              child: Column(
                children: [
                  Text(
                    'MANGO POS',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'RNC: 123-45678-9',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      color: const Color(0xFF7D726D),
                    ),
                  ),
                ],
              ),
            ),

            // Order Info
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFFF5F5F4),
                border: Border(
                  bottom: BorderSide(
                    color: Color(0xFFE0DBD9),
                    style: BorderStyle.solid,
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Fecha:',
                        style: GoogleFonts.plusJakartaSans(fontSize: 12),
                      ),
                      Text(
                        DateTime.now().toString().substring(0, 16),
                        style: GoogleFonts.plusJakartaSans(fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Items List
            Container(
              constraints: const BoxConstraints(maxHeight: 300),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ...items.map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${(item.quantity as num).toInt()}x',
                              style: GoogleFonts.plusJakartaSans(fontSize: 14),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                item.productName ?? 'Producto',
                                style: GoogleFonts.plusJakartaSans(
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            Text(
                              'RD\$ ${(item.total as num).toDouble().toStringAsFixed(2)}',
                              style: GoogleFonts.plusJakartaSans(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Totals
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFFE0DBD9))),
              ),
              child: Column(
                children: [
                  _buildTotalRow('Subtotal:', subtotal),
                  const SizedBox(height: 8),
                  _buildTotalRow('ITBIS (18%):', tax),
                  const SizedBox(height: 8),
                  _buildTotalRow(
                    'Propina Sugerida (10%):',
                    suggestedTip,
                    isSuccess: true,
                  ),
                  const Divider(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'TOTAL:',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'RD\$ ${total.toStringAsFixed(2)}',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFFFB7116),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Disclaimer
            Container(
              padding: const EdgeInsets.all(12),
              color: const Color(0xFFFEF3C7),
              child: Text(
                'Esta no es una factura válida\nSolicite su comprobante al pagar',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF92400E),
                ),
              ),
            ),

            // Close Button
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFB7116),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    'Cerrar',
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTotalRow(String label, double amount, {bool isSuccess = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            color: isSuccess
                ? const Color(0xFF22C55E)
                : const Color(0xFF7D726D),
          ),
        ),
        Text(
          'RD\$ ${amount.toStringAsFixed(2)}',
          style: GoogleFonts.plusJakartaSans(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isSuccess
                ? const Color(0xFF22C55E)
                : const Color(0xFF231F1D),
          ),
        ),
      ],
    );
  }
}

// === PUBLIC EXPORTS ===

/// Public wrapper for the SendToKitchen button widget
class SendToKitchenButton extends StatelessWidget {
  final String? orderId;

  const SendToKitchenButton({super.key, this.orderId});

  @override
  Widget build(BuildContext context) {
    return _SendToKitchenButton(orderId: orderId);
  }
}

/// Public function to show the Pre-Bill modal
void showPreBillModal(BuildContext context, WidgetRef ref) {
  _showPreBillModal(context, ref);
}
