import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../data/models/table_deposit_coverage.dart';

List<Map<String, dynamic>> _buildPrecheckItems(
  List<dynamic> rawItems,
  String receiptItemDisplayMode,
) {
  final items = rawItems
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  if (receiptItemDisplayMode != 'separate') {
    return items;
  }

  final expanded = <Map<String, dynamic>>[];
  for (final item in items) {
    final qtyRaw = item['qty'] ?? item['quantity'] ?? 1;
    final qty = qtyRaw is num
        ? qtyRaw.toDouble()
        : double.tryParse('$qtyRaw') ?? 1;
    final roundedQty = qty.roundToDouble();
    final isWholeQuantity = (qty - roundedQty).abs() < 0.001;

    if (!isWholeQuantity || roundedQty <= 1) {
      expanded.add(item);
      continue;
    }

    final parts = roundedQty.toInt();
    final lineTotal =
        (item['lineTotal'] as num?)?.toDouble() ??
        ((item['price'] ?? 0) as num).toDouble() * qty;
    final cents = (lineTotal * 100).round();
    final unitCents = cents ~/ parts;
    final remainder = cents - unitCents * parts;
    for (var idx = 0; idx < parts; idx++) {
      final amount = (unitCents + (idx < remainder ? 1 : 0)) / 100.0;
      expanded.add({
        ...item,
        'qty': 1,
        'quantity': 1,
        'price': amount,
        'lineTotal': amount,
      });
    }
  }

  return expanded;
}

class PreCheckDialog extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onPrint;
  final VoidCallback onCancel;
  final String receiptItemDisplayMode;

  const PreCheckDialog({
    super.key,
    required this.data,
    required this.onPrint,
    required this.onCancel,
    this.receiptItemDisplayMode = 'grouped',
  });

  @override
  Widget build(BuildContext context) {
    final amountColumnWidth = (MediaQuery.sizeOf(context).width * 0.25)
        .clamp(88.0, 120.0)
        .toDouble();
    final currencyFormat = NumberFormat.currency(
      symbol: 'RD\$ ',
      decimalDigits: 2,
    );
    final items = _buildPrecheckItems(
      data['items'] as List<dynamic>,
      receiptItemDisplayMode,
    );

    // Calcular totales localmente si no vienen (aunque deberían venir)
    final subtotal = data['subtotal'] ?? 0.0;
    final tax = data['tax'] ?? 0.0;
    final total = data['total'] ?? (subtotal + tax);

    // Abono de la mesa: mismo cálculo que la precuenta impresa. Null = la mesa
    // no tiene saldo (o es sub-cuenta) y el diálogo se ve como siempre.
    final depositCoverage = TableDepositCoverage.of(
      total: (total as num).toDouble(),
      available: (data['tableDepositBalance'] as num?)?.toDouble(),
    );

    // Bloque de totales ya reconciliado por `buildReceiptTotalsRows` (mismo
    // criterio que el ticket impreso): un renglón por impuesto + la línea de
    // descuento, de modo que Subtotal + impuestos − descuento = TOTAL. Si no
    // viene (llamadores viejos), caemos al bloque legacy de dos renglones.
    final totalsRows = (data['totals'] as List<dynamic>? ?? const [])
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
      backgroundColor: Colors.transparent,
      child: Container(
        width: 480,
        constraints: BoxConstraints(
          maxHeight: (MediaQuery.sizeOf(context).height - 48)
              .clamp(0.0, 820.0)
              .toDouble(),
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
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
                      (data['restaurantName']?.toString().trim().isNotEmpty ??
                              false)
                          ? data['restaurantName'].toString().trim()
                          : 'Negocio',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: const Color(0xFF111111),
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (data['rnc']?.toString().trim().isNotEmpty ?? false)
                      Text(
                        'RNC: ${data['rnc'].toString().trim()}',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    if (data['phone']?.toString().trim().isNotEmpty ?? false)
                      Text(
                        'Tel: ${data['phone'].toString().trim()}',
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
                        Expanded(
                          child: Column(
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
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
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
                        ),
                      ],
                    ),

                    // Cliente — solo si está disponible. Ocupa una fila
                    // propia debajo para que respire visualmente.
                    if ((data['customerName'] as String?)?.trim().isNotEmpty ??
                        false) ...[
                      const SizedBox(height: 4),
                      _InfoRow(
                        label: 'Cliente',
                        value: (data['customerName'] as String).trim(),
                      ),
                    ],

                    const SizedBox(height: 16),
                    const Divider(color: Color(0xFFE5E5E5)),
                    const SizedBox(height: 16),

                    // Products Table Headers
                    Row(
                      children: [
                        SizedBox(
                          width: 52,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'CANT.',
                              style: _headerStyle,
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'DESCRIPCIÓN',
                            style: _headerStyle,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: amountColumnWidth,
                          child: Text(
                            'IMPORTE',
                            textAlign: TextAlign.right,
                            style: _headerStyle,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Products List
                    ...items.map((item) {
                      final qty =
                          ((item['qty'] ?? item['quantity'] ?? 1) as num)
                              .toDouble();
                      final amount =
                          (item['lineTotal'] as num?)?.toDouble() ??
                          ((item['price'] ?? 0) as num).toDouble() * qty;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 52,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    NumberFormat('0.###').format(qty),
                                    style: _bodyStyle.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                item['name'] ?? 'Item',
                                style: _bodyStyle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: amountColumnWidth,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    currencyFormat.format(amount),
                                    style: _bodyStyle,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    if (items.isNotEmpty &&
                        items.every(
                          (i) => i['amountIncludesTaxAndDiscount'] == true,
                        ))
                      Text(
                        'Importes con impuestos y descuentos incluidos',
                        style: _bodyStyle.copyWith(
                          fontSize: 11,
                          color: const Color(0xFF777777),
                        ),
                      ),

                    const SizedBox(height: 16),
                    const Divider(color: Color(0xFFE5E5E5)),
                    const SizedBox(height: 16),

                    // Totals
                    if (totalsRows.isNotEmpty)
                      ...totalsRows.map((row) {
                        final amount = (row['amount'] as num?)?.toDouble() ?? 0;
                        final isNegative = row['isNegative'] == true;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _TotalRow(
                            label: row['label'] == 'Descuento' && !isNegative
                                ? 'Descuento incluido'
                                : row['label']?.toString() ?? '',
                            value: isNegative
                                ? '- ${currencyFormat.format(amount)}'
                                : currencyFormat.format(amount),
                            highlight:
                                isNegative || row['label'] == 'Descuento',
                          ),
                        );
                      })
                    else ...[
                      _TotalRow(
                        label: 'Subtotal',
                        value: currencyFormat.format(subtotal),
                      ),
                      const SizedBox(height: 8),
                      _TotalRow(
                        label: 'ITBIS',
                        value: currencyFormat.format(tax),
                      ),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 4),

                    if (depositCoverage != null)
                      _buildGrandTotal(currencyFormat, total),

                    // ABONO DE LA MESA: lo que tiene y la diferencia a pagar.
                    if (depositCoverage != null) ...[
                      const SizedBox(height: 12),
                      _TotalRow(
                        label: 'Abono disponible',
                        value: currencyFormat.format(depositCoverage.available),
                        highlight: true,
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            depositCoverage.coversAll
                                ? 'A PAGAR'
                                : 'DIFERENCIA A PAGAR',
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFF111111),
                            ),
                          ),
                          Text(
                            currencyFormat.format(depositCoverage.toPay),
                            style: GoogleFonts.inter(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                              color: const Color(0xFF111111),
                            ),
                          ),
                        ],
                      ),
                      if (depositCoverage.coversAll) ...[
                        const SizedBox(height: 6),
                        _TotalRow(
                          label: 'Saldo que queda',
                          value: currencyFormat.format(
                            depositCoverage.remaining,
                          ),
                        ),
                      ],
                    ],

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

            // Total fijo: sigue visible aunque la lista de productos se desplace.
            if (depositCoverage == null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
                child: _buildGrandTotal(currencyFormat, total),
              ),

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
                        backgroundColor: const Color(0xFFF97316),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: onPrint,
                      icon: const Icon(Icons.print_rounded, size: 20),
                      label: Text(
                        'Imprimir precuenta',
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

  Widget _buildGrandTotal(NumberFormat currencyFormat, num total) => Row(
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
      const SizedBox(width: 16),
      Expanded(
        child: Align(
          alignment: Alignment.centerRight,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              currencyFormat.format(total),
              style: GoogleFonts.inter(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: const Color(0xFFF97316), // Mango Orange
              ),
            ),
          ),
        ),
      ),
    ],
  );

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

  /// Resalta la fila en verde (se usa para el descuento, igual que el panel
  /// del carrito).
  final bool highlight;

  const _TotalRow({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 14,
              color: const Color(0xFF666666),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: highlight
                ? const Color(0xFF16A34A)
                : const Color(0xFF333333),
          ),
        ),
      ],
    );
  }
}
