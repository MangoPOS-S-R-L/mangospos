// Sprint Caja Profesional — Fase D.
// Dashboard "Salud de cajas" para admin/manager.
//
// Consume la vista `v_cash_sessions_health` y muestra:
//   - Resumen: cuántas abiertas, cuántas necesitan atención.
//   - Lista de sesiones abiertas con saldo vivo + edad + bandera roja
//     si lleva >12h sin cerrar.
//   - Acción "Forzar cierre" para sesiones <3d (las >3d ya las auto-cerró
//     la migración 0015 — ya están closed con AUTO_CLOSED_ZOMBIE).
//   - Auto-refresh cada 60s.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/services/session/session_controller.dart';

class CashSessionsHealthView extends ConsumerStatefulWidget {
  const CashSessionsHealthView({super.key});

  @override
  ConsumerState<CashSessionsHealthView> createState() =>
      _CashSessionsHealthViewState();
}

class _CashSessionsHealthViewState
    extends ConsumerState<CashSessionsHealthView> {
  List<Map<String, dynamic>> _sessions = const [];
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;
  bool _openOnly = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final session = ref.read(sessionProvider);
    final businessId = session.activeBusinessId;
    if (businessId == null || businessId.isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Negocio no resuelto.';
        });
      }
      return;
    }
    try {
      final repo = ref.read(cashierRepositoryProvider);
      final rows = await repo.getCashSessionsHealth(
        businessId: businessId,
        openOnly: _openOnly,
      );
      if (!mounted) return;
      setState(() {
        _sessions = rows;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  double _num(Map<String, dynamic> row, String key) {
    final v = row[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  String _fmt(double v) {
    final negative = v < 0;
    final abs = v.abs();
    final whole = abs.truncate();
    final decimals = ((abs - whole) * 100).round().toString().padLeft(2, '0');
    final wholeStr = whole.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
    return '${negative ? '-' : ''}RD\$ $wholeStr.$decimals';
  }

  String _ageLabel(String? iso) {
    if (iso == null) return '—';
    final opened = DateTime.tryParse(iso);
    if (opened == null) return '—';
    final age = DateTime.now().difference(opened);
    if (age.inMinutes < 60) return 'Hace ${age.inMinutes}min';
    if (age.inHours < 24) return 'Hace ${age.inHours}h';
    return 'Hace ${age.inDays}d ${age.inHours % 24}h';
  }

  @override
  Widget build(BuildContext context) {
    final sessionCtrl = ref.read(sessionProvider.notifier);
    final canForceClose = sessionCtrl.hasPermission('caja.cierre');

    final open = _sessions.where((s) => s['status'] == 'open').toList();
    final needsAttention =
        open.where((s) => s['needs_attention'] == true).toList();
    final totalExpected = open.fold<double>(
      0,
      (sum, s) => sum + _num(s, 'saldo_esperado_actual'),
    );

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.4,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.cashier),
        ),
        title: const Text('Salud de cajas'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Recargar',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: MangoColors.primaryOrange,
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (needsAttention.isNotEmpty)
              _AlertBanner(count: needsAttention.length),
            if (needsAttention.isNotEmpty) const SizedBox(height: 16),

            Row(
              children: [
                Expanded(
                  child: _SummaryTile(
                    label: 'Cajas abiertas',
                    value: open.length.toString(),
                    color: MangoColors.primaryOrange,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryTile(
                    label: 'Necesitan atención',
                    value: needsAttention.length.toString(),
                    color: const Color(0xFFEF4444),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SummaryTile(
                    label: 'Efectivo en cajas',
                    value: _fmt(totalExpected),
                    color: MangoColors.successGreen,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            Row(
              children: [
                const Text(
                  'Sesiones',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
                const Spacer(),
                Switch.adaptive(
                  value: _openOnly,
                  activeTrackColor: MangoColors.primaryOrange,
                  onChanged: (v) {
                    setState(() => _openOnly = v);
                    _load();
                  },
                ),
                const SizedBox(width: 6),
                const Text('Solo abiertas', style: TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 10),

            if (_loading && _sessions.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation(
                      MangoColors.primaryOrange,
                    ),
                  ),
                ),
              )
            else if (_sessions.isEmpty)
              const _EmptyState()
            else
              ..._sessions.map(
                (s) => _SessionCard(
                  row: s,
                  ageLabel: _ageLabel(s['opened_at']?.toString()),
                  fmt: _fmt,
                  num_: _num,
                  canForceClose: canForceClose && s['status'] == 'open',
                  onForceClose: () => _showForceCloseDialog(s),
                ),
              ),

            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Aviso: $_error',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFB91C1C),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showForceCloseDialog(Map<String, dynamic> session) async {
    final amountCtrl = TextEditingController();
    final reasonCtrl = TextEditingController();
    final sessionId = session['session_id']?.toString();
    final caja = session['caja_nombre']?.toString() ?? 'Caja';
    final expected = _num(session, 'saldo_esperado_actual');
    if (sessionId == null) return;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forzar cierre de caja'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Vas a cerrar "$caja" sin que el cajero lo haga. Saldo '
              'esperado actual: ${_fmt(expected)}.',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: amountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Monto contado (opcional)',
                hintText: 'Dejar vacío si no se hizo arqueo',
                prefixText: 'RD\$ ',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Razón del cierre forzado *',
                hintText: 'Ej: cajero se fue sin cerrar',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFEF4444),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Forzar cierre'),
          ),
        ],
      ),
    );

    if (result != true || !mounted) return;
    final reason = reasonCtrl.text.trim();
    if (reason.isEmpty) {
      AppToast.info(context, 'La razón es obligatoria.');
      return;
    }
    final amount = double.tryParse(amountCtrl.text.replaceAll(',', '.'));
    try {
      await ref.read(cashierRepositoryProvider).forceCloseSession(
            sessionId: sessionId,
            endAmount: amount,
            reason: reason,
          );
      if (!mounted) return;
      AppToast.success(context, 'Sesión cerrada por fuerza.');
      _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo cerrar: $e');
    }
  }
}

class _AlertBanner extends StatelessWidget {
  final int count;
  const _AlertBanner({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEDD5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFED7AA)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: MangoColors.primaryOrange,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$count caja${count == 1 ? '' : 's'} lleva más de 12h sin '
              'cerrar. Revisa o forza el cierre.',
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF9A3412),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _SummaryTile({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: MangoColors.muted),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final String ageLabel;
  final String Function(double) fmt;
  final double Function(Map<String, dynamic>, String) num_;
  final bool canForceClose;
  final VoidCallback onForceClose;

  const _SessionCard({
    required this.row,
    required this.ageLabel,
    required this.fmt,
    required this.num_,
    required this.canForceClose,
    required this.onForceClose,
  });

  @override
  Widget build(BuildContext context) {
    final status = row['status']?.toString() ?? 'open';
    final isOpen = status == 'open';
    final needsAttention = row['needs_attention'] == true;
    final caja = row['caja_nombre']?.toString() ?? 'Caja';

    Color statusColor;
    String statusLabel;
    if (!isOpen) {
      statusColor = MangoColors.muted;
      statusLabel = 'Cerrada';
    } else if (needsAttention) {
      statusColor = const Color(0xFFEF4444);
      statusLabel = 'Atención';
    } else {
      statusColor = MangoColors.successGreen;
      statusLabel = 'OK';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: needsAttention ? const Color(0xFFFED7AA) : MangoColors.cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  caja,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: statusColor,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  statusLabel,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Abierta: $ageLabel',
            style: const TextStyle(fontSize: 12, color: MangoColors.muted),
          ),
          const SizedBox(height: 12),
          _kv('Apertura',  fmt(num_(row, 'start_amount')),         false),
          _kv('Ventas',    fmt(num_(row, 'ventas_efectivo')),      false),
          _kv('Depósitos', fmt(num_(row, 'depositos')),            false),
          _kv('Retiros',   fmt(num_(row, 'retiros')),              true),
          _kv('Gastos',    fmt(num_(row, 'gastos')),               true),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Divider(height: 1),
          ),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Esperado',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
              ),
              Text(
                fmt(num_(row, 'saldo_esperado_actual')),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: MangoColors.primaryOrange,
                ),
              ),
            ],
          ),
          if (canForceClose) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onForceClose,
                icon: const Icon(Icons.lock_open, size: 14),
                label: const Text('Forzar cierre'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFEF4444),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kv(String label, String amount, bool isOut) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: Text(
              isOut ? '−' : '+',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color:
                    isOut ? const Color(0xFFEF4444) : MangoColors.successGreen,
              ),
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: MangoColors.darkGray),
            ),
          ),
          Text(
            amount,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isOut ? const Color(0xFFEF4444) : MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: const Column(
        children: [
          Icon(Icons.check_circle_outline,
              size: 40, color: MangoColors.successGreen),
          SizedBox(height: 8),
          Text(
            'No hay sesiones que requieran atención.',
            style: TextStyle(fontSize: 13, color: MangoColors.darkGray),
          ),
        ],
      ),
    );
  }
}
