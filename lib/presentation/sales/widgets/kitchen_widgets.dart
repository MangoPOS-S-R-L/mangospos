import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/data/repositories/printing_service.dart';
import 'package:mangopos/presentation/sales/viewmodel/menu_browser_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';

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

  Future<void> _showMissingPrinterDialog(
    NoAssignedKitchenPrinterException error,
  ) {
    final areas = error.areaCodes.isEmpty
        ? 'cocina'
        : error.areaCodes.join(', ').replaceAll('_', ' ').toUpperCase();

    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.print_disabled_outlined, color: Color(0xFFF97316)),
            SizedBox(width: 10),
            Expanded(child: Text('Impresora no configurada')),
          ],
        ),
        content: Text(
          'No hay una impresora asignada para $areas.\n\nConfigura la impresion de comandas antes de enviar esta orden a cocina.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cerrar'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              context.go(AppRoutes.printingOrders);
            },
            icon: const Icon(Icons.settings_outlined, size: 18),
            label: const Text('Configurar ahora'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSendToKitchen() async {
    final orderNotifier = ref.read(currentOrderProvider.notifier);
    final items = ref.read(currentOrderProvider).items;

    // Validation
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showAppSnackBar(
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

      // Refrescar stock — el trigger auto-86 ya corrió en backend, queremos
      // que el badge del catálogo refleje las nuevas cantidades sin esperar
      // al próximo loadAll.
      unawaited(
        ref.read(menuBrowserVmProvider.notifier).refreshStock(),
      );

      setState(() => _state = KitchenButtonState.success);

      if (mounted) {
        ScaffoldMessenger.of(context).showAppSnackBar(
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
    } on NoAssignedKitchenPrinterException catch (e) {
      setState(() => _state = KitchenButtonState.error);

      if (mounted) {
        await _showMissingPrinterDialog(e);
      }

      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        setState(() => _state = KitchenButtonState.idle);
      }
    } catch (e) {
      setState(() => _state = KitchenButtonState.error);

      if (mounted) {
        ScaffoldMessenger.of(context).showAppSnackBar(
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
          disabledBackgroundColor: (config['bgColor'] as Color).withValues(
            alpha: 0.7,
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
          'text': 'Enviar Pedido',
          'icon': Icons.restaurant,
          'bgColor': const Color(0xFFF97316), // kPrimary
          'disabled': false,
        };
      case KitchenButtonState.validating:
        return {
          'text': 'Validando...',
          'icon': Icons.hourglass_empty,
          'bgColor': const Color(0xFFF97316),
          'disabled': true,
        };
      case KitchenButtonState.sending:
        return {
          'text': 'Enviando...',
          'icon': Icons.cloud_upload,
          'bgColor': const Color(0xFFF97316),
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

  Future<Map<String, String?>> _loadBusinessInfo(WidgetRef ref) async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    final fallbackName =
        (session.activeBusinessName?.trim().isNotEmpty ?? false)
        ? session.activeBusinessName!.trim()
        : 'Negocio';

    if (businessId == null || businessId.isEmpty) {
      return {'name': fallbackName, 'rnc': null};
    }

    final client = Supabase.instance.client;
    String? name = fallbackName;
    String? rnc;

    try {
      final business = await client
          .from('businesses')
          .select('business_name, branch_name')
          .eq('id', businessId)
          .maybeSingle();
      final branchName = business?['branch_name']?.toString().trim();
      final businessName = business?['business_name']?.toString().trim();
      if (branchName != null && branchName.isNotEmpty) {
        name = branchName;
      } else if (businessName != null && businessName.isNotEmpty) {
        name = businessName;
      }
    } catch (_) {}

    try {
      final fiscal = await client
          .from('fiscal_settings')
          .select('rnc')
          .eq('business_id', businessId)
          .maybeSingle();
      rnc = fiscal?['rnc']?.toString().trim();
    } catch (_) {}

    return {'name': name, 'rnc': rnc};
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orderState = ref.watch(currentOrderProvider);
    final items = orderState.items;
    final total = (orderState.order?.total as num?)?.toDouble() ?? 0.0;
    final subtotal = total / 1.18;
    final tax = total - subtotal;
    final suggestedTip = subtotal * 0.10;

    return FutureBuilder<Map<String, String?>>(
      future: _loadBusinessInfo(ref),
      builder: (context, snapshot) {
        final businessName = snapshot.data?['name'] ?? 'Negocio';
        final businessRnc = snapshot.data?['rnc'];

        return Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFE0DBD9)),
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        businessName,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (businessRnc != null && businessRnc.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'RNC: $businessRnc',
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 12,
                            color: const Color(0xFF7D726D),
                          ),
                        ),
                      ],
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
                                  style: GoogleFonts.plusJakartaSans(
                                    fontSize: 14,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    item.productName,
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
                              color: const Color(0xFFF97316),
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
                        backgroundColor: const Color(0xFFF97316),
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
      },
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
