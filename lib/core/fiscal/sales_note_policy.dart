import 'ncf_types.dart';

/// The counter belongs to the business and advances only when a document is
/// issued. The server makes the final decision when concurrent tills pay.
class SalesNotePolicy {
  final bool enabled;
  final int notesBeforeInvoice;
  final int currentCount;

  const SalesNotePolicy({
    required this.enabled,
    this.notesBeforeInvoice = 3,
    this.currentCount = 0,
  });

  static bool isConsumerFinal(String? fiscalType) =>
      const {'B02', 'E32'}.contains(fullNcfCode(fiscalType));

  bool allowsNote({
    required String? fiscalType,
    required Iterable<String> paymentMethodCodes,
  }) {
    final methods = paymentMethodCodes.toList();
    return enabled &&
        notesBeforeInvoice > 0 &&
        currentCount < notesBeforeInvoice &&
        isConsumerFinal(fiscalType) &&
        methods.isNotEmpty &&
        methods.every((code) => code.trim().toLowerCase() == 'cash');
  }

  bool shouldSelectNote({
    required String? fiscalType,
    required Iterable<String> paymentMethodCodes,
  }) => allowsNote(
    fiscalType: fiscalType,
    paymentMethodCodes: paymentMethodCodes,
  );
}
