import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

/// Construye bytes ESC/POS para cocina y recibos.
class EscposTicketService {
  Future<List<int>> buildKitchenBytes({
    required String orderId,
    required List<Map<String, dynamic>> items,
    String area = 'kitchen',
  }) async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(PaperSize.mm58, profile);
    final bytes = <int>[];
    bytes.addAll(
      gen.text('KITCHEN - $area', styles: const PosStyles(bold: true)),
    );
    bytes.addAll(gen.text('Order #$orderId'));
    bytes.addAll(gen.hr());
    for (final item in items) {
      final name = item['name'] ?? '';
      final qty = item['qty'] ?? 1;
      bytes.addAll(
        gen.row([
          PosColumn(text: '$qty x', width: 2),
          PosColumn(text: name, width: 10),
        ]),
      );
    }
    bytes.addAll(gen.hr());
    bytes.addAll(gen.cut());
    return bytes;
  }

  Future<List<int>> buildReceiptBytes({
    required String orderId,
    required List<Map<String, dynamic>> items,
    double total = 0,
  }) async {
    final profile = await CapabilityProfile.load();
    final gen = Generator(PaperSize.mm80, profile);
    final bytes = <int>[];
    bytes.addAll(
      gen.text(
        'MANGO POS',
        styles: const PosStyles(
          bold: true,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
        ),
      ),
    );
    bytes.addAll(gen.text('Receipt #$orderId'));
    bytes.addAll(gen.hr());
    for (final item in items) {
      final name = item['name'] ?? '';
      final qty = item['qty'] ?? 1;
      final price = (item['price'] ?? 0).toDouble();
      bytes.addAll(
        gen.row([
          PosColumn(text: name, width: 8),
          PosColumn(text: '$qty x', width: 2),
          PosColumn(
            text: price.toStringAsFixed(2),
            width: 2,
            styles: const PosStyles(align: PosAlign.right),
          ),
        ]),
      );
    }
    bytes.addAll(gen.hr());
    bytes.addAll(
      gen.text(
        'TOTAL: ${total.toStringAsFixed(2)}',
        styles: const PosStyles(bold: true, align: PosAlign.right),
      ),
    );
    bytes.addAll(gen.cut());
    return bytes;
  }
}
