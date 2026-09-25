// Asignarle una mesa abierta a otro mesero.
//
// Caso real: el mesero que abrió la mesa se fue a su casa, entró otro turno,
// o la mesa se abrió a nombre de quien no era. Hasta ahora el dueño de la
// mesa (`table_sessions.opened_by_employee_id`) se escribía al abrirla y no
// cambiaba nunca: la mesa quedaba con el nombre equivocado en el salón, en la
// precuenta, en la factura y en la pantalla de mozos.
//
// La reasignación vale DE AQUÍ EN ADELANTE (decisión del dueño, 2026-09-24):
// lo que ya se consumió sigue acreditado a quien lo digitó. Eso lo garantiza
// el servidor (`fn_reassign_table_waiter`), no esta pantalla.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/utils/app_snackbar.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../data/repositories/employee_repository.dart';
import '../../../data/repositories/zones_repository.dart';

/// Un mesero al que se le puede pasar la mesa.
class ReassignWaiterOption {
  const ReassignWaiterOption({required this.id, required this.name});
  final String id;
  final String name;
}

typedef ReassignWaiterLoader = Future<List<ReassignWaiterOption>> Function(
  String businessId,
);
typedef ReassignWaiterSubmit = Future<Map<String, dynamic>> Function({
  required String sessionId,
  required String employeeId,
  String? reason,
});

/// Meseros ACTIVOS del negocio, ordenados por nombre.
///
/// Es un provider para poder sustituirlo en pruebas: el diálogo no toca
/// Supabase directo. Un mesero inactivo lo rechaza el servidor, así que ni se
/// ofrece — un nombre que al tocarlo da error es peor que no verlo.
final reassignWaiterLoaderProvider = Provider<ReassignWaiterLoader>((ref) {
  return (String businessId) async {
    final employees = await EmployeeRepository(Supabase.instance.client)
        .fetchEmployees(businessId: businessId);
    final waiters = employees
        .where((e) =>
            e.status == 'active' &&
            e.roles.any((r) => r.toLowerCase().trim() == 'waiter'))
        .map((e) => ReassignWaiterOption(
              id: e.id,
              name: '${e.firstName} ${e.lastName}'.trim(),
            ))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return waiters;
  };
});

final reassignWaiterSubmitProvider = Provider<ReassignWaiterSubmit>((ref) {
  return ({
    required String sessionId,
    required String employeeId,
    String? reason,
  }) {
    return ZonesRepository(Supabase.instance.client).reassignTableWaiter(
      sessionId: sessionId,
      employeeId: employeeId,
      reason: reason,
    );
  };
});

/// Abre el diálogo. Devuelve `true` si la mesa quedó asignada a otro mesero.
///
/// [currentWaiterName] es solo para el encabezado ("Ahora es de Claudia"): el
/// dueño real lo resuelve el servidor, que es quien decide.
Future<bool> showReassignWaiterDialog(
  BuildContext context,
  WidgetRef ref, {
  required String businessId,
  required String sessionId,
  required String tableLabel,
  String? currentWaiterName,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ReassignWaiterDialog(
      businessId: businessId,
      sessionId: sessionId,
      tableLabel: tableLabel,
      currentWaiterName: currentWaiterName,
    ),
  );
  return result == true;
}

class _ReassignWaiterDialog extends ConsumerStatefulWidget {
  const _ReassignWaiterDialog({
    required this.businessId,
    required this.sessionId,
    required this.tableLabel,
    this.currentWaiterName,
  });

  final String businessId;
  final String sessionId;
  final String tableLabel;
  final String? currentWaiterName;

  @override
  ConsumerState<_ReassignWaiterDialog> createState() =>
      _ReassignWaiterDialogState();
}

class _ReassignWaiterDialogState extends ConsumerState<_ReassignWaiterDialog> {
  final _reasonCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _error;
  List<ReassignWaiterOption> _waiters = const [];
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final waiters = await ref.read(reassignWaiterLoaderProvider)(
        widget.businessId,
      );
      if (!mounted) return;
      setState(() {
        _waiters = waiters;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = FriendlyError.humanize('No se pudo cargar los meseros: $e');
      });
    }
  }

  List<ReassignWaiterOption> get _filtered {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _waiters;
    return _waiters
        .where((e) => e.name.toLowerCase().contains(q))
        .toList(growable: false);
  }

  Future<void> _submit() async {
    final employeeId = _selectedId;
    if (employeeId == null) return;

    setState(() => _saving = true);
    try {
      final res = await ref.read(reassignWaiterSubmitProvider)(
        sessionId: widget.sessionId,
        employeeId: employeeId,
        reason: _reasonCtrl.text.trim(),
      );
      if (!mounted) return;

      final name = res['to_employee_name']?.toString() ??
          _waiters
              .where((e) => e.id == employeeId)
              .map((e) => e.name)
              .firstOrNull ??
          'el mesero';
      final changed = res['changed'] == true;

      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showAppSnackBar(
        SnackBar(
          content: Text(
            changed
                ? '${widget.tableLabel} ahora es de $name. Lo consumido hasta '
                    'ahora queda con quien lo digitó.'
                : '${widget.tableLabel} ya era de $name.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = FriendlyError.humanize('$e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return AlertDialog(
      title: Text('Asignar ${widget.tableLabel} a otro mesero'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.currentWaiterName != null &&
                widget.currentWaiterName!.trim().isNotEmpty) ...[
              Text(
                'Ahora es de ${widget.currentWaiterName}.',
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0xFF64748B),
                ),
              ),
              const SizedBox(height: 10),
            ],
            // Lo primero que tiene que quedar claro: qué NO se mueve.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(11),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: const Text(
                'Lo que ya se consumió sigue contando para quien lo digitó. '
                'El mesero nuevo se lleva la mesa y lo que agregue desde '
                'ahora.',
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF1E3A8A),
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFECACA)),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF991B1B),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_waiters.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  'Este negocio no tiene meseros activos registrados.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                ),
              )
            else ...[
              // El buscador aparece solo cuando la lista lo amerita: con
              // cuatro meseros estorba más de lo que ayuda.
              if (_waiters.length > 6) ...[
                TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18),
                    hintText: 'Buscar mesero',
                    isDense: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: filtered.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          'Ningún mesero coincide con esa búsqueda.',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final e = filtered[i];
                          return RadioListTile<String>(
                            value: e.id,
                            // ignore: deprecated_member_use
                            groupValue: _selectedId,
                            // ignore: deprecated_member_use
                            onChanged: _saving
                                ? null
                                : (v) => setState(() => _selectedId = v),
                            title: Text(e.name),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          );
                        },
                      ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _reasonCtrl,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: 'Motivo',
                  hintText: 'Ej. cambio de turno',
                  helperText: 'Queda en la bitácora de la mesa',
                  isDense: true,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: (_saving || _selectedId == null) ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Asignar'),
        ),
      ],
    );
  }
}
