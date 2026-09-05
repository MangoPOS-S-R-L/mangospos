// Formulario de tarjeta reutilizable para tokenizar vía Azul (ProcessDataVault).
//
// Renderiza SOLO los campos (número, nombre, vencimiento, CVC) + el botón de
// envío + banner de error. El encabezado/título lo pone el padre, así el mismo
// form sirve tanto en un bottom sheet (`AzulCardFormSheet`) como inline en una
// página completa (Step 4 del registro).
//
// PCI (SAQ D): el PAN/CVV solo viven en los TextEditingController mientras el
// widget está montado; se limpian en dispose. No se persisten ni se loguean
// acá. La transmisión es por HTTPS (Edge Function `azul-tokenize-card`).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/mango_tokens.dart';
import '../../../data/repositories/billing_repository.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

class AzulCardForm extends ConsumerStatefulWidget {
  final String businessId;
  final bool makeDefault;
  final String submitLabel;
  final void Function(TokenizedCardResult result) onSuccess;

  const AzulCardForm({
    super.key,
    required this.businessId,
    required this.submitLabel,
    required this.onSuccess,
    this.makeDefault = true,
  });

  @override
  ConsumerState<AzulCardForm> createState() => _AzulCardFormState();
}

class _AzulCardFormState extends ConsumerState<AzulCardForm> {
  final _formKey = GlobalKey<FormState>();
  final _cardCtl = TextEditingController();
  final _nameCtl = TextEditingController();
  final _expCtl = TextEditingController();
  final _cvcCtl = TextEditingController();

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    // Limpiar los datos de tarjeta de memoria al cerrar (higiene PCI).
    _cardCtl.clear();
    _expCtl.clear();
    _cvcCtl.clear();
    _cardCtl.dispose();
    _nameCtl.dispose();
    _expCtl.dispose();
    _cvcCtl.dispose();
    super.dispose();
  }

  String? _validateCard(String? v) {
    final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 13 || digits.length > 19) {
      return 'Número de tarjeta inválido';
    }
    return null;
  }

  String? _validateExp(String? v) {
    final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length != 4) return 'MM/AA';
    final mm = int.tryParse(digits.substring(0, 2)) ?? 0;
    final yy = int.tryParse(digits.substring(2, 4)) ?? 0;
    if (mm < 1 || mm > 12) return 'Mes inválido';
    final now = DateTime.now();
    final expDate = DateTime(2000 + yy, mm + 1, 0); // último día del mes
    if (expDate.isBefore(DateTime(now.year, now.month, 1))) {
      return 'Tarjeta vencida';
    }
    return null;
  }

  String? _validateCvc(String? v) {
    final digits = (v ?? '').trim();
    if (digits.length < 3 || digits.length > 4) return 'CVC';
    return null;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final cardDigits = _cardCtl.text.replaceAll(RegExp(r'\D'), '');
    final expDigits = _expCtl.text.replaceAll(RegExp(r'\D'), ''); // MMAA
    final yyyymm = '20${expDigits.substring(2, 4)}${expDigits.substring(0, 2)}';

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final repo = ref.read(billingRepositoryProvider);
      final result = await repo.tokenizeCard(
        businessId: widget.businessId,
        cardNumber: cardDigits,
        expiration: yyyymm,
        cvc: _cvcCtl.text.trim(),
        makeDefault: widget.makeDefault,
      );
      if (!mounted) return;
      widget.onSuccess(result);
    } on BillingRepositoryException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = FriendlyError.from(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'No se pudo procesar la tarjeta. Intenta de nuevo.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _label('Número de tarjeta'),
          TextFormField(
            controller: _cardCtl,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.creditCardNumber],
            inputFormatters: [CardNumberInputFormatter()],
            decoration: _decoration(
              hint: '1234 1234 1234 1234',
              suffix: const Icon(Icons.credit_card, size: 20),
            ),
            validator: _validateCard,
            enabled: !_submitting,
          ),
          const SizedBox(height: 16),
          _label('Nombre en la tarjeta'),
          TextFormField(
            controller: _nameCtl,
            keyboardType: TextInputType.name,
            textCapitalization: TextCapitalization.characters,
            autofillHints: const [AutofillHints.creditCardName],
            decoration: _decoration(hint: 'Nombre del titular'),
            enabled: !_submitting,
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('Vence (MM/AA)'),
                    TextFormField(
                      controller: _expCtl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [ExpiryInputFormatter()],
                      decoration: _decoration(hint: '12 / 34'),
                      validator: _validateExp,
                      enabled: !_submitting,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _label('CVC'),
                    TextFormField(
                      controller: _cvcCtl,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                      decoration: _decoration(hint: '123'),
                      validator: _validateCvc,
                      enabled: !_submitting,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFCA5A5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline,
                      color: Color(0xFFB91C1C), size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                          color: Color(0xFFB91C1C), height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: MangoTokens.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _submitting
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: Colors.white),
                    )
                  : Text(
                      widget.submitLabel,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline, size: 14, color: theme.hintColor),
                const SizedBox(width: 6),
                Text('Procesado de forma segura por Azul',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.hintColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: MangoTokens.foreground,
          ),
        ),
      );

  InputDecoration _decoration({required String hint, Widget? suffix}) {
    return InputDecoration(
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      suffixIcon: suffix,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: MangoTokens.border),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: MangoTokens.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: MangoTokens.primary, width: 1.4),
      ),
    );
  }
}

/// Agrupa el número de tarjeta en bloques de 4 (máx 19 dígitos).
class CardNumberInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final trimmed = digits.length > 19 ? digits.substring(0, 19) : digits;
    final buf = StringBuffer();
    for (var i = 0; i < trimmed.length; i++) {
      if (i > 0 && i % 4 == 0) buf.write(' ');
      buf.write(trimmed[i]);
    }
    final text = buf.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// Formatea el vencimiento como MM/AA.
class ExpiryInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final trimmed = digits.length > 4 ? digits.substring(0, 4) : digits;
    final text = trimmed.length >= 3
        ? '${trimmed.substring(0, 2)}/${trimmed.substring(2)}'
        : trimmed;
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}
