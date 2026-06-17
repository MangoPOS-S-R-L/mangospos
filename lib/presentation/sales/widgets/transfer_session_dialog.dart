// lib/presentation/sales/widgets/transfer_session_dialog.dart
//
// PRD-12 F2: dialog para transferir una cuenta (sesión) abierta a otra
// mesa. Soporta dos modos: TODA la cuenta o ITEMS específicos. El PIN
// supervisor se pide al final, antes de invocar el RPC.
//
// El widget es self-contained: recibe los datos de la cuenta actual
// (sessionId, items, businessId, sourceTableId, sourceTableLabel) y
// devuelve `true` por Navigator.pop si la transferencia fue exitosa.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/utils/sorting_utils.dart';
import '../../../data/models/sales_models.dart';
import '../../../data/repositories/zones_repository.dart';
import '../../../services/session/session_controller.dart';
import 'pin_verification_modal.dart';

/// Punto de entrada. Devuelve `true` si la transferencia se completó.
///
/// `mergeOnly = true` configura el dialog para el caso F3 (Unir mesas
/// desde el grid):
///   - Oculta el toggle "Toda la cuenta / Algunos artículos" — siempre
///     transfiere todo.
///   - Filtra el listado de destinos a solo mesas ocupadas (las únicas
///     con cuenta abierta para combinar).
///   - Cambia el título a "Unir con otra mesa".
Future<bool> showTransferSessionDialog(
  BuildContext context,
  WidgetRef ref, {
  required String businessId,
  required String sourceSessionId,
  required String sourceTableId,
  required String sourceTableLabel,
  required List<OrderItem> items,
  bool mergeOnly = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _TransferSessionDialog(
      businessId: businessId,
      sourceSessionId: sourceSessionId,
      sourceTableId: sourceTableId,
      sourceTableLabel: sourceTableLabel,
      items: items,
      mergeOnly: mergeOnly,
    ),
  );
  return result == true;
}

class _TransferSessionDialog extends ConsumerStatefulWidget {
  const _TransferSessionDialog({
    required this.businessId,
    required this.sourceSessionId,
    required this.sourceTableId,
    required this.sourceTableLabel,
    required this.items,
    this.mergeOnly = false,
  });

  final String businessId;
  final String sourceSessionId;
  final String sourceTableId;
  final String sourceTableLabel;
  final List<OrderItem> items;
  /// PRD-12 F3: cuando `true`, el dialog opera en modo "Unir mesas":
  /// fija el alcance a TODA la cuenta y filtra el listado de destinos
  /// a solo mesas ocupadas.
  final bool mergeOnly;

  @override
  ConsumerState<_TransferSessionDialog> createState() =>
      _TransferSessionDialogState();
}

class _TransferSessionDialogState
    extends ConsumerState<_TransferSessionDialog> {
  /// `true` = transferir todos los items, `false` = elegir cuáles.
  bool _transferAll = true;
  final Set<String> _selectedItemIds = <String>{};

  Map<String, dynamic>? _selectedTable; // map crudo del fetch
  bool _loadingTables = true;
  List<Map<String, dynamic>> _tables = const [];
  String? _loadError;

  /// Buscador de mesa destino: filtra el listado por nombre/código/zona.
  final TextEditingController _searchCtrl = TextEditingController();
  String _tableQuery = '';

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadTables();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTables() async {
    try {
      final repo = ZonesRepository(Supabase.instance.client);
      var list = await repo.fetchTablesForTransfer(
        businessId: widget.businessId,
        excludeTableId: widget.sourceTableId,
      );
      // F3 (Unir mesas): solo destinos ocupados — unir requiere otra
      // cuenta abierta con la cual combinar. Las mesas disponibles
      // serían un transfer normal, no un merge.
      if (widget.mergeOnly) {
        list = list
            .where((t) => (t['state'] as String?) == 'occupied')
            .toList(growable: false);
      }
      if (mounted) {
        setState(() {
          _tables = list;
          _loadingTables = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingTables = false;
          _loadError = e.toString();
        });
      }
    }
  }

  List<OrderItem> get _activeItems => widget.items
      .where((it) => it.status != 'void')
      .toList(growable: false);

  bool get _canSubmit {
    if (_submitting) return false;
    if (_selectedTable == null) return false;
    if (!_transferAll && _selectedItemIds.isEmpty) return false;
    return true;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final messenger = ScaffoldMessenger.of(context);

    // Solo el owner del negocio se salta el PIN. Cualquier otro rol
    // (admin, supervisor, cajero, mesero…) debe escribir PIN de
    // supervisor/admin para transferir o unir cuentas. Este es el punto
    // único de enforcement para ambos flujos de entrada (transferir desde
    // la cuenta y unir mesas desde el grid de zonas).
    final isOwner = ref.read(sessionProvider).isOwner;

    if (!isOwner) {
      final pinOk = await showPinVerificationModal(
        context,
        ref,
        level: PinAccessLevel.supervisor,
        title: 'Autorización de supervisor',
        subtitle:
            'La transferencia entre mesas requiere PIN de supervisor.',
      );
      if (!pinOk) {
        if (!mounted) return;
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Transferencia cancelada: PIN no autorizado.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
    }

    if (!mounted) return;
    setState(() => _submitting = true);

    try {
      final targetTableId = _selectedTable!['id'].toString();
      final itemIds =
          _transferAll ? null : _selectedItemIds.toList(growable: false);
      final repo = ZonesRepository(Supabase.instance.client);
      final res = await repo.transferTableSession(
        sourceSessionId: widget.sourceSessionId,
        targetTableId: targetTableId,
        itemIds: itemIds,
      );
      if (!mounted) return;

      final mode = res['mode']?.toString() ?? 'full';
      final merged = res['merged_with_existing'] == true;
      final movedCount = res['items_moved'] is int
          ? res['items_moved'] as int
          : null;
      final tableLabel =
          (_selectedTable!['label'] as String?)?.trim().isNotEmpty == true
              ? _selectedTable!['label'] as String
              : (_selectedTable!['code'] as String? ?? 'mesa destino');
      String msg;
      if (mode == 'full') {
        msg = merged
            ? 'Cuenta combinada con la mesa $tableLabel.'
            : 'Cuenta movida a la mesa $tableLabel.';
      } else {
        msg = '$movedCount item(s) movidos a la mesa $tableLabel.';
      }

      Navigator.of(context).pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('No se pudo transferir: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
      contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.mergeOnly
                ? 'Unir cuenta de ${widget.sourceTableLabel}'
                : 'Transferir cuenta · ${widget.sourceTableLabel}',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.mergeOnly
                ? 'Selecciona la mesa con la que quieres combinar esta '
                      'cuenta. Solo se muestran mesas ocupadas. Las cuentas '
                      'se fusionan en la mesa destino.'
                : 'Mueve esta cuenta a otra mesa, completa o por items. Si '
                      'la mesa destino ya tiene cuenta abierta, las cuentas '
                      'se combinan automáticamente.',
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF6B7280),
              fontWeight: FontWeight.normal,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!widget.mergeOnly) ...[
                _SectionHeader(label: '1. Qué transferir'),
                const SizedBox(height: 8),
                _ScopeToggle(
                  isAll: _transferAll,
                  onChanged: (val) {
                    setState(() {
                      _transferAll = val;
                      if (val) _selectedItemIds.clear();
                    });
                  },
                ),
                if (!_transferAll) ...[
                  const SizedBox(height: 12),
                  _ItemsPicker(
                    items: _activeItems,
                    selectedIds: _selectedItemIds,
                    onToggle: (id) {
                      setState(() {
                        if (_selectedItemIds.contains(id)) {
                          _selectedItemIds.remove(id);
                        } else {
                          _selectedItemIds.add(id);
                        }
                      });
                    },
                  ),
                ],
                const SizedBox(height: 16),
              ],
              _SectionHeader(
                label: widget.mergeOnly
                    ? 'Mesa destino (cuentas se combinan)'
                    : '2. Mesa destino',
              ),
              const SizedBox(height: 8),
              if (!_loadingTables && _loadError == null && _tables.isNotEmpty)
                _TableSearchField(
                  controller: _searchCtrl,
                  onChanged: (val) => setState(() {
                    _tableQuery = val;
                    // Si el filtro oculta la mesa seleccionada, deselecciónala
                    // para no transferir a una mesa fuera de vista (click
                    // erróneo). El botón "Transferir" se deshabilita hasta que
                    // se elija una mesa visible.
                    if (_selectedTable != null &&
                        !_TablesList.matchesQuery(_selectedTable!, val)) {
                      _selectedTable = null;
                    }
                  }),
                  onClear: () {
                    _searchCtrl.clear();
                    setState(() => _tableQuery = '');
                  },
                ),
              if (!_loadingTables && _loadError == null && _tables.isNotEmpty)
                const SizedBox(height: 8),
              _TablesList(
                loading: _loadingTables,
                error: _loadError,
                tables: _tables,
                query: _tableQuery,
                selectedId: _selectedTable?['id']?.toString(),
                onSelect: (table) {
                  setState(() => _selectedTable = table);
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF97316),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFFFFD2A8),
            disabledForegroundColor: Colors.white,
          ),
          onPressed: _canSubmit ? _submit : null,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(widget.mergeOnly ? 'Unir mesas' : 'Transferir'),
        ),
      ],
    );
  }
}

// ─── Sub-widgets ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: Color(0xFF374151),
        letterSpacing: 0.3,
      ),
    );
  }
}

/// Campo de búsqueda de la mesa destino. Filtra por título de mesa, código
/// o zona. Muestra una "X" para limpiar cuando hay texto.
class _TableSearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  const _TableSearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFF97316);
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Buscar mesa o zona…',
        hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
        prefixIcon: const Icon(Icons.search, size: 20, color: Color(0xFF6B7280)),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                splashRadius: 18,
                tooltip: 'Limpiar',
                onPressed: onClear,
              ),
        contentPadding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        filled: true,
        fillColor: const Color(0xFFFAFAFA),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: orange, width: 1.5),
        ),
      ),
    );
  }
}

class _ScopeToggle extends StatelessWidget {
  final bool isAll;
  final ValueChanged<bool> onChanged;
  const _ScopeToggle({required this.isAll, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ScopeButton(
            label: 'Toda la cuenta',
            icon: Icons.swap_horiz_rounded,
            isSelected: isAll,
            onTap: () => onChanged(true),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _ScopeButton(
            label: 'Algunos artículos',
            icon: Icons.checklist_rounded,
            isSelected: !isAll,
            onTap: () => onChanged(false),
          ),
        ),
      ],
    );
  }
}

class _ScopeButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;
  const _ScopeButton({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const orange = Color(0xFFF97316);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFF7ED) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? orange : const Color(0xFFE5E7EB),
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? orange : Colors.black54, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  color: isSelected ? const Color(0xFF7C2D12) : Colors.black87,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemsPicker extends StatelessWidget {
  final List<OrderItem> items;
  final Set<String> selectedIds;
  final ValueChanged<String> onToggle;
  const _ItemsPicker({
    required this.items,
    required this.selectedIds,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: const Text(
          'No hay items en esta cuenta para transferir.',
          style: TextStyle(color: Color(0xFF6B7280)),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (ctx, i) {
          final it = items[i];
          final selected = selectedIds.contains(it.id);
          return InkWell(
            onTap: () => onToggle(it.id),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected ? const Color(0xFFFFF7ED) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: selected
                      ? const Color(0xFFF97316)
                      : const Color(0xFFE5E7EB),
                  width: selected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded,
                    color: selected
                        ? const Color(0xFFF97316)
                        : Colors.black38,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${it.quantity.toStringAsFixed(0)}× ${it.productName}',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    'RD\$ ${it.subtotal.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _TablesList extends StatelessWidget {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> tables;
  final String query;
  final String? selectedId;
  final ValueChanged<Map<String, dynamic>> onSelect;
  const _TablesList({
    required this.loading,
    required this.error,
    required this.tables,
    required this.query,
    required this.selectedId,
    required this.onSelect,
  });

  /// Título visible de una mesa (label si existe, si no su código).
  static String _titleOf(Map<String, dynamic> t) {
    final label = (t['label'] as String?)?.trim();
    final code = (t['code'] as String?)?.trim() ?? '';
    return label != null && label.isNotEmpty ? label : code;
  }

  static String _zoneOf(Map<String, dynamic> t) {
    final zone = t['zones'] is Map ? t['zones'] as Map : const {};
    final name = (zone['name'] as String?)?.trim();
    return name != null && name.isNotEmpty ? name : 'Sin zona';
  }

  /// Predicado del buscador: una mesa coincide si el query aparece en su
  /// título, su código o su zona. Query vacío ⇒ coincide siempre. Único
  /// punto de verdad para el filtro de la lista y la limpieza de selección.
  static bool matchesQuery(Map<String, dynamic> t, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final code = (t['code'] as String?)?.toLowerCase() ?? '';
    return _titleOf(t).toLowerCase().contains(q) ||
        code.contains(q) ||
        _zoneOf(t).toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (error != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF2F2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFFECACA)),
        ),
        child: Text(
          'No se pudieron cargar las mesas: $error',
          style: const TextStyle(color: Color(0xFF991B1B)),
        ),
      );
    }
    if (tables.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: const Text(
          'No hay otras mesas activas para transferir.',
          style: TextStyle(color: Color(0xFF6B7280)),
        ),
      );
    }

    // Buscador: filtra por título de mesa, código o nombre de zona.
    final filtered = query.trim().isEmpty
        ? tables
        : tables.where((t) => matchesQuery(t, query)).toList(growable: false);

    if (filtered.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Text(
          'Sin resultados para «${query.trim()}».',
          style: const TextStyle(color: Color(0xFF6B7280)),
        ),
      );
    }

    // Agrupar por zona para que el picker tenga contexto.
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in filtered) {
      grouped.putIfAbsent(_zoneOf(t), () => []).add(t);
    }
    // Orden natural: zonas por nombre y, dentro de cada zona, las mesas por
    // su título ("Mesa 2" antes que "Mesa 10").
    final zoneNames = grouped.keys.toList(growable: false)
      ..sort(SortingUtils.naturalCompare);
    for (final list in grouped.values) {
      list.sort((a, b) => SortingUtils.naturalCompare(_titleOf(a), _titleOf(b)));
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final zoneName in zoneNames) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 6),
              child: Text(
                zoneName,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF6B7280),
                  letterSpacing: 0.5,
                ),
              ),
            ),
            ...grouped[zoneName]!.map((t) {
              final id = t['id']?.toString() ?? '';
              final selected = selectedId == id;
              final code = (t['code'] as String?) ?? '';
              final label = (t['label'] as String?)?.trim();
              final state = (t['state'] as String?) ?? 'available';
              final isOccupied = state == 'occupied';
              final displayLabel =
                  label != null && label.isNotEmpty ? label : code;
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  onTap: () => onSelect(t),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color:
                          selected ? const Color(0xFFFFF7ED) : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFFF97316)
                            : const Color(0xFFE5E7EB),
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: isOccupied
                                ? const Color(0xFFF59E0B)
                                : const Color(0xFF22C55E),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            displayLabel.isEmpty ? code : displayLabel,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          isOccupied ? 'Ocupada · combinará' : 'Disponible',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isOccupied
                                ? const Color(0xFFB45309)
                                : const Color(0xFF15803D),
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.check_circle,
                            color: Color(0xFFF97316),
                            size: 18,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}
