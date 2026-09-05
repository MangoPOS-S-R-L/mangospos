// Diálogo compartido de alta rápida de proveedor para el módulo de Compras
// (lista de compras y registro de compra). Cubre los campos del schema
// `suppliers` que faltaban en los quick-create: RNC, dirección, condiciones
// de pago y notas. El CRUD completo (editar/desactivar) sigue viviendo en
// Inventario → Proveedores (`suppliers_view.dart`).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/purchases_state.dart';
import '../viewmodel/purchases_viewmodel.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

/// Muestra el diálogo de alta de proveedor. Devuelve el proveedor creado o
/// `null` si se canceló (o falló; el error queda en el state del viewmodel).
Future<PurchaseSupplier?> showCreateSupplierDialog(
  BuildContext context,
  WidgetRef ref,
) {
  return showDialog<PurchaseSupplier>(
    context: context,
    builder: (_) => _CreateSupplierDialog(ref: ref),
  );
}

class _CreateSupplierDialog extends StatefulWidget {
  final WidgetRef ref;

  const _CreateSupplierDialog({required this.ref});

  @override
  State<_CreateSupplierDialog> createState() => _CreateSupplierDialogState();
}

class _CreateSupplierDialogState extends State<_CreateSupplierDialog> {
  final _nameCtrl = TextEditingController();
  final _rncCtrl = TextEditingController();
  final _contactCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _termsCtrl = TextEditingController();
  // Días de plazo (mig 20260814_0003). Convive con el texto libre: el número
  // alimenta el vencimiento por defecto de la cuenta por pagar y el texto
  // cubre los casos que no son un plazo simple («50% anticipo»).
  final _termsDaysCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _rncCtrl.dispose();
    _contactCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _termsCtrl.dispose();
    _termsDaysCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  String? _orNull(String v) => v.trim().isEmpty ? null : v.trim();

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'El nombre es obligatorio.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created =
          await widget.ref.read(purchasesViewModelProvider).createSupplier(
                name: name,
                rnc: _orNull(_rncCtrl.text),
                contactName: _orNull(_contactCtrl.text),
                phone: _orNull(_phoneCtrl.text),
                email: _orNull(_emailCtrl.text),
                address: _orNull(_addressCtrl.text),
                paymentTerms: _orNull(_termsCtrl.text),
                paymentTermsDays: int.tryParse(_termsDaysCtrl.text.trim()),
                notes: _orNull(_notesCtrl.text),
              );
      if (!mounted) return;
      Navigator.of(context).pop(created);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = FriendlyError.humanize('Error creando proveedor: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nuevo proveedor'),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Nombre *'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _rncCtrl,
                      decoration: const InputDecoration(
                          labelText: 'RNC', hintText: '000-00000-0'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _contactCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Contacto'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _phoneCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Teléfono'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _emailCtrl,
                      decoration: const InputDecoration(labelText: 'Email'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _addressCtrl,
                decoration: const InputDecoration(labelText: 'Dirección'),
                maxLines: 2,
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _termsCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Condiciones de pago',
                        hintText: 'Ej: 30 días, contado, 50% anticipo',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 150,
                    child: TextField(
                      controller: _termsDaysCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(3),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Días de plazo',
                        hintText: '30',
                        helperText: 'Opcional · alimenta el vencimiento',
                        helperMaxLines: 2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesCtrl,
                decoration: const InputDecoration(labelText: 'Notas'),
                maxLines: 2,
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }
}
