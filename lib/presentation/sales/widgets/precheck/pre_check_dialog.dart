import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';

class PreCheckDialog extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onPrint;
  final VoidCallback onCancel;

  const PreCheckDialog({
    super.key,
    required this.data,
    required this.onPrint,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final currencyFormat = NumberFormat.currency(
      symbol: 'RD\$ ',
      decimalDigits: 2,
    );
    final items = data['items'] as List<dynamic>;

    // Calcular totales localmente si no vienen (aunque deberían venir)
    final subtotal = data['subtotal'] ?? 0.0;
    final tax = data['tax'] ?? 0.0;
    final total = data['total'] ?? (subtotal + tax);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
      backgroundColor: Colors.transparent,
      child: Container(
        width: 400,
        constraints: const BoxConstraints(maxHeight: 700),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          children: [
            // --- HEADER ---
            _buildHeader(context),
            const Divider(height: 1, color: Color(0xFFE5E5E5)),

            // --- CONTENT (Scrollable) ---
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 20,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Restaurant Info
                    Text(
                      data['restaurantName'] ?? 'REST. MANGO POS',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: const Color(0xFF111111),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'RNC: ${data['rnc'] ?? '000-00000-0'}',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                    Text(
                      'Tel: ${data['phone'] ?? '809-555-0000'}',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),

                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Divider(color: Color(0xFFE5E5E5)),
                    ),

                    // Table Info
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _InfoRow(
                              label: 'Mesa',
                              value: data['tableName'] ?? 'N/A',
                            ),
                            _InfoRow(
                              label: 'Fecha',
                              value: DateFormat(
                                'dd/MM/yyyy',
                              ).format(DateTime.now()),
                            ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _InfoRow(
                              label: 'Hora',
                              value: DateFormat(
                                'hh:mm a',
                              ).format(DateTime.now()),
                            ),
                            _InfoRow(
                              label: 'Mesero',
                              value: data['waiterName'] ?? 'N/A',
                            ),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),
                    const Divider(color: Color(0xFFE5E5E5)),
                    const SizedBox(height: 16),

                    // Products Table Headers
                    Row(
                      children: [
                        SizedBox(
                          width: 30,
                          child: Text('CANT', style: _headerStyle),
                        ),
                        Expanded(
                          child: Text('DESCRIPCIÓN', style: _headerStyle),
                        ),
                        Text('PRECIO', style: _headerStyle),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Products List
                    ...items.map((item) {
                      final price = item['price'] ?? 0.0;
                      final qty = item['quantity'] ?? 1;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 30,
                              child: Text(
                                '$qty',
                                style: _bodyStyle.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                item['name'] ?? 'Item',
                                style: _bodyStyle,
                              ),
                            ),
                            Text(
                              currencyFormat.format(price * qty),
                              style: _bodyStyle,
                            ),
                          ],
                        ),
                      );
                    }).toList(),

                    const SizedBox(height: 16),
                    const Divider(color: Color(0xFFE5E5E5)),
                    const SizedBox(height: 16),

                    // Totals
                    _TotalRow(
                      label: 'Subtotal',
                      value: currencyFormat.format(subtotal),
                    ),
                    const SizedBox(height: 8),
                    _TotalRow(
                      label: 'ITBIS (18%)',
                      value: currencyFormat.format(tax),
                    ),
                    const SizedBox(height: 12),

                    // GRAND TOTAL
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'TOTAL',
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: const Color(0xFF111111),
                          ),
                        ),
                        Text(
                          currencyFormat.format(total),
                          style: GoogleFonts.inter(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            color: const Color(0xFFFB7116), // Mango Orange
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 24),
                    const Divider(color: Color(0xFFE5E5E5)),

                    // Disclaimer
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '* Este documento no tiene validez fiscal *\nGracias por su preferencia',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: Colors.grey[500],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const Divider(height: 1, color: Color(0xFFE5E5E5)),

            // --- FOOTER ---
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  // Cancel Button
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: const BorderSide(color: Color(0xFFE5E5E5)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: onCancel,
                      child: Text(
                        'Cerrar',
                        style: GoogleFonts.inter(
                          color: const Color(0xFF666666),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  // Print Button
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: const Color(0xFFFB7116),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: onPrint,
                      icon: const Icon(Icons.print_rounded, size: 20),
                      label: Text(
                        'Imprimir Pre-Cuenta',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Pre-Cuenta',
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF111111),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Color(0xFF666666)),
            onPressed: onCancel,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            splashRadius: 20,
          ),
        ],
      ),
    );
  }

  static final TextStyle _headerStyle = GoogleFonts.inter(
    fontSize: 11,
    fontWeight: FontWeight.bold,
    color: const Color(0xFF999999),
    letterSpacing: 0.5,
  );

  static final TextStyle _bodyStyle = GoogleFonts.inter(
    fontSize: 13,
    color: const Color(0xFF333333),
    height: 1.4,
  );
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: GoogleFonts.inter(
            fontSize: 13,
            color: const Color(0xFF333333),
          ), // Base style
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(color: Color(0xFF888888)),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  final String label;
  final String value;

  const _TotalRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            color: const Color(0xFF666666),
          ),
        ),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF333333),
          ),
        ),
      ],
    );
  }
}
