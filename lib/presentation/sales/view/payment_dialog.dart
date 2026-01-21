import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

enum PaymentMethod { cash, card, transfer }

Future<Map<String, dynamic>?> showPaymentDialog(
  BuildContext context, {
  required double total,
}) async {
  final amountCtrl = TextEditingController(text: '0');
  final notesCtrl = TextEditingController();
  PaymentMethod method = PaymentMethod.cash;

  double parseAmount() {
    final v = double.tryParse(amountCtrl.text.replaceAll(',', '.')) ?? 0;
    return v < 0 ? 0 : v;
  }

  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setState) {
          final received = parseAmount();
          final remaining = (total - received);
          final hasEnough = received >= total;

          Widget methodButton(String label, PaymentMethod m, IconData icon) {
            final selected = method == m;
            return Expanded(
              child: OutlinedButton.icon(
                icon: Icon(icon, size: 20),
                label: Text(label),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: selected
                      ? MangoColors.primaryOrange.withOpacity(0.1)
                      : Colors.white,
                  side: BorderSide(
                    color: selected
                        ? MangoColors.primaryOrange
                        : Colors.grey.shade300,
                    width: selected ? 2 : 1,
                  ),
                  foregroundColor: selected
                      ? MangoColors.primaryOrange
                      : MangoColors.darkGray,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => setState(() => method = m),
              ),
            );
          }

          Widget amountButton(String label, double v) => OutlinedButton(
            onPressed: () {
              setState(() => amountCtrl.text = v.toStringAsFixed(2));
            },
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              side: BorderSide(color: Colors.grey.shade300),
              foregroundColor: MangoColors.darkGray,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          );

          return Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 40,
              vertical: 24,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Header con el total
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(20),
                        topRight: Radius.circular(20),
                      ),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Total',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: MangoColors.darkGray,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'RD\$ ${total.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                            color: MangoColors.primaryOrange,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Contenido
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Método de Pago',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: MangoColors.darkGray,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            methodButton(
                              'Efectivo',
                              PaymentMethod.cash,
                              Icons.account_balance_wallet_outlined,
                            ),
                            const SizedBox(width: 8),
                            methodButton(
                              'Tarjeta',
                              PaymentMethod.card,
                              Icons.credit_card,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        methodButton(
                          'Transferencia',
                          PaymentMethod.transfer,
                          Icons.phone_iphone,
                        ),
                        const SizedBox(height: 20),

                        const Text(
                          'Monto Recibido',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: MangoColors.darkGray,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: amountCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          decoration: InputDecoration(
                            prefixText: 'RD\$ ',
                            prefixStyle: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                color: MangoColors.primaryOrange,
                                width: 2,
                              ),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 12),

                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            amountButton('Exacto', total),
                            amountButton('1', 1),
                            amountButton('5', 5),
                            amountButton('10', 10),
                            amountButton('20', 20),
                            amountButton('50', 50),
                            amountButton('100', 100),
                            amountButton('200', 200),
                          ],
                        ),
                        const SizedBox(height: 16),

                        Builder(
                          builder: (_) {
                            if (received <= 0) {
                              return const SizedBox.shrink();
                            }
                            if (!hasEnough) {
                              return Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: Colors.red.shade50,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.red.shade200,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    const Text(
                                      'FALTA PAGAR:',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: MangoColors.muted,
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      'RD\$${remaining.toStringAsFixed(2)}',
                                      style: TextStyle(
                                        color: Colors.red.shade700,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }
                            final change = (received - total);
                            return Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Colors.green.shade50,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.green.shade200,
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Text(
                                    'VUELTO:',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: MangoColors.muted,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    'RD\$${change.toStringAsFixed(2)}',
                                    style: TextStyle(
                                      color: Colors.green.shade700,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 16,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: 20),
                        const Text(
                          'Notas (Opcional)',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                            color: MangoColors.darkGray,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: notesCtrl,
                          maxLines: 2,
                          decoration: InputDecoration(
                            hintText: 'Agregar notas sobre esta venta...',
                            hintStyle: TextStyle(color: Colors.grey.shade400),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: const BorderSide(
                                color: MangoColors.primaryOrange,
                                width: 2,
                              ),
                            ),
                            contentPadding: const EdgeInsets.all(14),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Footer con botones
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: const BorderRadius.only(
                        bottomLeft: Radius.circular(20),
                        bottomRight: Radius.circular(20),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              side: BorderSide(color: Colors.grey.shade300),
                              foregroundColor: MangoColors.darkGray,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text(
                              'Cancelar',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            icon: const Icon(
                              Icons.check_circle_outline,
                              size: 22,
                            ),
                            label: const Text(
                              'COBRAR',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                                letterSpacing: 0.5,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: hasEnough
                                  ? const Color(0xFF4CAF50)
                                  : Colors.grey.shade300,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: hasEnough
                                ? () {
                                    Navigator.pop<Map<String, dynamic>>(
                                      context,
                                      {
                                        'method': method.name,
                                        'received': received,
                                        'notes': notesCtrl.text,
                                      },
                                    );
                                  }
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
