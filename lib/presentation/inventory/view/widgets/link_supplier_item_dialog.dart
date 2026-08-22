// Declarar que un proveedor provee un insumo.
//
// Es el vínculo que hoy no existe y por el que «Sugerencias de reorden» puede
// decir «faltan 3 botellas de ron» pero no a quién comprarlas. Tres datos lo
// hacen útil:
//
//   - **El insumo.** Obligatorio, es el vínculo.
//   - **El código del proveedor.** Cómo llama ÉL a ese insumo en su catálogo.
//     Va en la orden de compra: sin eso, la OC sale con el nombre interno del
//     negocio y del otro lado no saben qué se está pidiendo.
//   - **El precio de lista.** Referencia para armar la orden. NO es el costo
//     del insumo ni lo pisa: el costo lo sigue calculando la recepción.
//
// Además ofrece marcarlo como suplidor PREFERIDO del insumo. Es una decisión
// distinta —«se lo compro a él» vs «se lo puedo comprar a él»— y por eso es
// una casilla aparte y no un efecto secundario de vincular.

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../data/repositories/suppliers_repository.dart';
import '../../state/inventory_state.dart';

/// Abre el diálogo. Devuelve `true` si algo cambió.
Future<bool> showLinkSupplierItemDialog(
  BuildContext context, {
  required String businessId,
  required String supplierId,
  required String supplierName,
  required SuppliersRepository repo,
  Set<String> alreadyLinked = const {},
}) async {
  final saved = await showDialog<bool>(
    context: context,
    builder: (_) => LinkSupplierItemDialog(
      businessId: businessId,
      supplierId: supplierId,
      supplierName: supplierName,
      repo: repo,
      alreadyLinked: alreadyLinked,
    ),
  );
  return saved == true;
}

class LinkSupplierItemDialog extends StatefulWidget {
  final String businessId;
  final String supplierId;
  final String supplierName;
  final SuppliersRepository repo;

  /// Ids ya declarados. Se muestran igual pero deshabilitados: esconderlos
  /// haría parecer que el insumo no existe.
  final Set<String> alreadyLinked;

  const LinkSupplierItemDialog({
    super.key,
    required this.businessId,
    required this.supplierId,
    required this.supplierName,
    required this.repo,
    this.alreadyLinked = const {},
  });

  @override
  State<LinkSupplierItemDialog> createState() => _LinkSupplierItemDialogState();
}

class _LinkSupplierItemDialogState extends State<LinkSupplierItemDialog> {
  final _searchCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _unitCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();

  List<InventoryItemSummary> _catalog = const [];
  InventoryItemSummary? _selected;
  bool _preferred = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCatalog());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _codeCtrl.dispose();
    _unitCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    try {
      final items = await widget.repo.getItemCatalog(widget.businessId);
      if (!mounted) return;
      setState(() {
        _catalog = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'No se pudo leer el catálogo de insumos: $e';
      });
    }
  }

  List<InventoryItemSummary> get _results {
    final q = _searchCtrl.text.trim().toLowerCase();
    final list = q.isEmpty
        ? _catalog
        : _catalog
              .where(
                (i) =>
                    i.name.toLowerCase().contains(q) ||
                    i.sku.toLowerCase().contains(q),
              )
              .toList(growable: false);
    return list.take(60).toList(growable: false);
  }

  Future<void> _save() async {
    final item = _selected;
    if (item == null) {
      setState(() => _error = 'Elegí el insumo que provee.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final linked = await widget.repo.linkItem(
        businessId: widget.businessId,
        supplierId: widget.supplierId,
        itemId: item.id,
        supplierCode: _codeCtrl.text.trim().isEmpty
            ? null
            : _codeCtrl.text.trim(),
        purchaseUnit: _unitCtrl.text.trim().isEmpty
            ? null
            : _unitCtrl.text.trim(),
        listPrice: double.tryParse(_priceCtrl.text.trim().replaceAll(',', '')),
      );

      var changed = linked;
      if (_preferred) {
        final ok = await widget.repo.setPreferredSupplier(
          itemId: item.id,
          supplierId: widget.supplierId,
        );
        changed = changed || ok;
      }

      if (!mounted) return;
      if (!changed) {
        setState(() {
          _saving = false;
          _error =
              'Este negocio todavía no tiene la tabla de vínculos '
              '(migración 20260819_0003) ni el suplidor preferido '
              '(20260813_0001). No hay dónde guardarlo.';
        });
        return;
      }
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Vincular insumo a ${widget.supplierName}'),
      content: SizedBox(
        width: 560,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _searchCtrl,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar insumo por nombre o SKU',
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _results.isEmpty
                  ? Center(
                      child: Text(
                        'Ningún insumo coincide.',
                        style: TextStyle(color: AppColors.mutedForeground),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, i) {
                        final item = _results[i];
                        final linked = widget.alreadyLinked.contains(item.id);
                        final selected = _selected?.id == item.id;
                        return ListTile(
                          enabled: !linked,
                          selected: selected,
                          onTap: linked
                              ? null
                              : () => setState(() {
                                  _selected = item;
                                  if (_unitCtrl.text.trim().isEmpty) {
                                    _unitCtrl.text = item.purchaseUnit.isEmpty
                                        ? item.unit
                                        : item.purchaseUnit;
                                  }
                                }),
                          leading: Icon(
                            selected
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 20,
                            color: selected
                                ? AppColors.primary
                                : AppColors.mutedForeground,
                          ),
                          dense: true,
                          title: Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            linked
                                ? 'Ya vinculado a este proveedor'
                                : [
                                    if (item.sku.isNotEmpty) item.sku,
                                    if (item.unit.isNotEmpty) item.unit,
                                  ].join(' · '),
                            style: TextStyle(
                              fontSize: 11.5,
                              color: linked
                                  ? AppColors.success
                                  : AppColors.mutedForeground,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Código del proveedor',
                      hintText: 'Ej: FER-HAR-50',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _unitCtrl,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Unidad',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 130,
                  child: TextField(
                    controller: _priceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Precio lista',
                    ),
                  ),
                ),
              ],
            ),
            CheckboxListTile(
              value: _preferred,
              onChanged: (v) => setState(() => _preferred = v ?? false),
              title: const Text('Marcarlo como suplidor preferido del insumo'),
              subtitle: Text(
                'Con esto, «Qué comprar hoy» va a proponer este proveedor '
                'cuando el insumo baje del mínimo.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: AppColors.mutedForeground,
                ),
              ),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
            if (_error != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: AppColors.destructive.withValues(alpha: 0.08),
                  border: Border.all(
                    color: AppColors.destructive.withValues(alpha: 0.35),
                  ),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: AppColors.foreground,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Vincular'),
        ),
      ],
    );
  }
}
