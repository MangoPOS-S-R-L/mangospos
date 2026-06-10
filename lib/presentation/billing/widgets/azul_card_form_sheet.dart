// Formulario de tarjeta in-app para tokenizar vía Azul (ProcessDataVault).
//
// Reemplaza el WebView de Payment Page: la app captura número/vencimiento/CVC y
// los manda a la Edge Function `azul-tokenize-card`, que guarda solo el token.
//
// PCI (SAQ D): el PAN/CVV solo viven en los TextEditingController mientras el
// sheet está abierto; se limpian en dispose. No se persisten ni se loguean acá.
// La transmisión es por HTTPS (Supabase functions.invoke).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/repositories/billing_repository.dart';

class AzulCardFormSheet extends ConsumerStatefulWidget {
  final String businessId;
  final bool makeDefault;

  const AzulCardFormSheet({
    super.key,
    required this.businessId,
    this.makeDefault = true,
  });

  /// Abre el sheet y devuelve el método de pago tokenizado, o `null` si se cerró
  /// sin completar.
  static Future<TokenizedCardResult?> show(
    BuildContext context, {
    required String businessId,
    bool makeDefault = true,
  }) {
    return showModalBottomSheet<TokenizedCardResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: AzulCardFormSheet(businessId: businessId, makeDefault: makeDefault),
      ),
    );
  }

  @override
  ConsumerState<AzulCardFormSheet> createState() => _AzulCardFormSheetState();
}

class _AzulCardFormSheetState extends ConsumerState<AzulCardFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _cardCtl = TextEditingController();
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
      Navigator.of(context).pop(result);
    } on BillingRepositoryException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Registrar tarjeta',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Verificaremos tu tarjeta con una autorización temporal de RD\$1 que se libera al instante. Tus datos viajan cifrados a Azul; guardamos solo un token, nunca tu número.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _cardCtl,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.creditCardNumber],
              inputFormatters: [_CardNumberFormatter()],
              decoration: const InputDecoration(
                labelText: 'Número de tarjeta',
                hintText: '0000 0000 0000 0000',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.credit_card),
              ),
              validator: _validateCard,
              enabled: !_submitting,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _expCtl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [_ExpiryFormatter()],
                    decoration: const InputDecoration(
                      labelText: 'Vence (MM/AA)',
                      hintText: '12/34',
                      border: OutlineInputBorder(),
                    ),
                    validator: _validateExp,
                    enabled: !_submitting,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: TextFormField(
                    controller: _cvcCtl,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'CVC',
                      hintText: '123',
                      border: OutlineInputBorder(),
                    ),
                    validator: _validateCvc,
                    enabled: !_submitting,
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        color: theme.colorScheme.onErrorContainer, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                            color: theme.colorScheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              child: _submitting
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Text('Guardar tarjeta'),
            ),
            const SizedBox(height: 8),
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
      ),
    );
  }
}

/// Agrupa el número de tarjeta en bloques de 4 (máx 19 dígitos).
class _CardNumberFormatter extends TextInputFormatter {
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
class _ExpiryFormatter extends TextInputFormatter {
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
