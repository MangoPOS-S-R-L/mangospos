// Clasificar en lote: marcar varios insumos como Gastable, Menaje o insumo
// normal de una vez.
//
// Existe porque un negocio arranca con cientos de insumos «simples» y, uno por
// uno desde la ficha, nadie marca el papel, el cloro, las copas y los platos.
// Devuelve cuántos cambió (o null si se canceló).

import 'package:flutter/material.dart';

import '../../../../core/inventory/item_classification.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_radius.dart';
import '../../../../data/repositories/supplies_repository.dart';

class SuppliesClassifyDialog extends StatefulWidget {
  const SuppliesClassifyDialog({
    super.key,
    required this.initialTarget,
    required this.loadItems,
    required this.onApply,
  });

  /// Clase con la que abre: la de la pestaña donde se tocó el botón.
  final String initialTarget;
  final Future<List<ClassifiableItem>> Function() loadItems;
  final Future<int> Function(List<String> itemIds, String classification)
  onApply;

  @override
  State<SuppliesClassifyDialog> createState() => _SuppliesClassifyDialogState();
}

/// Las tres a las que se puede pasar desde aquí. «Insumo» deshace un error.
const _targets = [
  ItemClassification.supply,
  ItemClassification.smallware,
  ItemClassification.simple,
];

String _targetLabel(String c) => switch (c) {
  ItemClassification.supply => 'Gastable',
  ItemClassification.smallware => 'Menaje',
  _ => 'Insumo',
};

class _SuppliesClassifyDialogState extends State<SuppliesClassifyDialog> {
  final _searchCtrl = TextEditingController();
  late String _target = _targets.contains(widget.initialTarget)
      ? widget.initialTarget
      : ItemClassification.supply;
  List<ClassifiableItem>? _items;
  String? _loadError;
  final Set<String> _selected = {};
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _items = null;
      _loadError = null;
    });
    try {
      final items = await widget.loadItems();
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = 'No se pudieron cargar los insumos: $e');
    }
  }

  /// Los que ya tienen la clase elegida no se pueden marcar: no hay nada que
  /// cambiar. Al volver a «Insumo» solo se ofrecen gastables y menaje, para
  /// no pisar una materia prima o un terminado por error.
  bool _selectable(ClassifiableItem i) {
    if (i.classification == _target) return false;
    if (_target == ItemClassification.simple) {
      return ItemClassification.isNonSale(i.classification);
    }
    return true;
  }

  List<ClassifiableItem> get _visible {
    final items = _items ?? const <ClassifiableItem>[];
    final q = _searchCtrl.text.trim().toLowerCase();
    return items
        .where(
          (i) =>
              q.isEmpty ||
              i.name.toLowerCase().contains(q) ||
              i.sku.toLowerCase().contains(q),
        )
        .where(
          (i) =>
              _target != ItemClassification.simple ||
              ItemClassification.isNonSale(i.classification),
        )
        .toList(growable: false);
  }

  void _setTarget(String target) {
    setState(() {
      _target = target;
      // Lo elegido para otra clase no se arrastra.
      _selected.clear();
      _error = null;
    });
  }

  Future<void> _apply() async {
    if (_saving || _selected.isEmpty) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final changed = await widget.onApply(_selected.toList(), _target);
      if (!mounted) return;
      Navigator.of(context).pop<int>(changed);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = switch (e) {
          SuppliesMigrationMissing() => e.toString(),
          _ when '$e'.contains('permiso') => '$e',
          _ => 'No se pudo clasificar. Revisa la conexión e intenta de nuevo.',
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final selectableVisible = visible.where(_selectable).toList();
    final allVisibleSelected =
        selectableVisible.isNotEmpty &&
        selectableVisible.every((i) => _selected.contains(i.id));
    return AlertDialog(
      title: const Text('Clasificar artículos'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Gastable: se usa y se acaba (papel, cloro, servilletas). '
              'Menaje: se reutiliza y se cuenta por piezas (copas, platos, '
              'ollas). Los equipos como el horno o la nevera van en Activos '
              'fijos.',
              style: TextStyle(
                fontSize: 12.5,
                color: AppColors.mutedForeground,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              key: const Key('classify-target'),
              segments: [
                for (final t in _targets)
                  ButtonSegment(value: t, label: Text(_targetLabel(t))),
              ],
              selected: {_target},
              showSelectedIcon: false,
              onSelectionChanged: _saving ? null : (v) => _setTarget(v.first),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('classify-search'),
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                hintText: 'Buscar insumo (papel, copa, cloro…)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _selected.isEmpty
                        ? 'Toca los que quieres marcar como '
                              '${_targetLabel(_target)}.'
                        : '${_selected.length} seleccionados',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _saving || selectableVisible.isEmpty
                      ? null
                      : () => setState(() {
                          if (allVisibleSelected) {
                            _selected.removeAll(
                              selectableVisible.map((i) => i.id),
                            );
                          } else {
                            _selected.addAll(
                              selectableVisible.map((i) => i.id),
                            );
                          }
                        }),
                  child: Text(
                    allVisibleSelected
                        ? 'Quitar los visibles'
                        : 'Todos los visibles',
                  ),
                ),
              ],
            ),
            Container(
              height: 320,
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: _list(visible),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const Key('classify-error'),
                style: const TextStyle(
                  color: Color(0xFFEF4444),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('classify-apply'),
          onPressed: _saving || _selected.isEmpty ? null : _apply,
          child: Text(
            _saving
                ? 'Guardando...'
                : _selected.isEmpty
                ? 'Marcar como ${_targetLabel(_target)}'
                : 'Marcar ${_selected.length} como ${_targetLabel(_target)}',
          ),
        ),
      ],
    );
  }

  Widget _list(List<ClassifiableItem> visible) {
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _loadError!,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.mutedForeground),
              ),
              TextButton(onPressed: _load, child: const Text('Reintentar')),
            ],
          ),
        ),
      );
    }
    if (_items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (visible.isEmpty) {
      return Center(
        child: Text(
          _target == ItemClassification.simple
              ? 'No hay gastables ni menaje que devolver a insumo.'
              : 'No se encontraron insumos.',
          style: TextStyle(color: AppColors.mutedForeground),
        ),
      );
    }
    return ListView.builder(
      itemCount: visible.length,
      itemBuilder: (context, index) {
        final item = visible[index];
        final selectable = _selectable(item);
        final already = item.classification == _target;
        return CheckboxListTile(
          key: ValueKey('classify-${item.id}'),
          dense: true,
          value: already || _selected.contains(item.id),
          onChanged: !selectable || _saving
              ? null
              : (v) => setState(() {
                  if (v == true) {
                    _selected.add(item.id);
                  } else {
                    _selected.remove(item.id);
                  }
                }),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            [
              if (item.sku.isNotEmpty) item.sku,
              already
                  ? 'Ya es ${_targetLabel(_target)}'
                  : itemClassificationLabel(
                      item.classification,
                      simpleLabel: 'Insumo',
                    ),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}
