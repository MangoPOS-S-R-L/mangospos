import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/currency/business_currency_provider.dart';
import '../../../core/multimesero/operator_permissions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/app_snackbar.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../data/models/table_status.dart';
import '../../../data/models/zone.dart';
import '../../../data/repositories/order_review_repository.dart';
import '../../../services/session/session_controller.dart';
import '../view/theme/table_status_style.dart';
import '../viewmodel/sales_by_zone_viewmodel.dart';
import 'pin_verification_modal.dart';

final orderReviewRepositoryProvider = Provider<OrderReviewRepository>(
  (ref) => OrderReviewRepository(Supabase.instance.client),
);

/// Mesa con cuentas en revisión (20261010_0020): antes de abrirla se muestran
/// para unirlas a la cuenta actual o anularlas como duplicado. Devuelve true
/// si hay que seguir abriendo la mesa (eligió «Abrir la cuenta de la mesa» o
/// acaba de unir productos para revisarlos), false si se cerró la hoja.
Future<bool> showReviewAccountsSheet(
  BuildContext context,
  WidgetRef ref,
  TableStatus table,
) async {
  final sessionId = table.sessionId;
  if (sessionId == null || sessionId == 'local-draft' || sessionId == 'hub') {
    return true;
  }
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => ReviewAccountsSheet(table: table, sessionId: sessionId),
  );
  return result ?? false;
}

class ReviewAccountsSheet extends ConsumerStatefulWidget {
  final TableStatus table;
  final String sessionId;

  const ReviewAccountsSheet({
    super.key,
    required this.table,
    required this.sessionId,
  });

  @override
  ConsumerState<ReviewAccountsSheet> createState() =>
      _ReviewAccountsSheetState();
}

class _ReviewAccountsSheetState extends ConsumerState<ReviewAccountsSheet> {
  late Future<List<ReviewAccount>> _accounts;
  String? _busyOrderId;

  @override
  void initState() {
    super.initState();
    _accounts = _load();
  }

  Future<List<ReviewAccount>> _load() => ref
      .read(orderReviewRepositoryProvider)
      .openReviewAccounts(widget.sessionId);

  // Cuerpo con llaves: una flecha devolvería el Future de la asignación y
  // setState lo rechaza («callback argument returned a Future»).
  void _reload() {
    setState(() {
      _accounts = _load();
    });
  }

  void _refreshSalon() {
    ref.read(byZoneVmProvider.notifier).loadZoneStatus(widget.table.zoneId);
  }

  void _notify(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showAppSnackBar(
      SnackBar(content: Text(text), backgroundColor: error ? Colors.red : null),
    );
  }

  Future<void> _merge(ReviewAccount account) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unir a la cuenta actual'),
        content: Text(
          'Los ${account.items.length} productos de esta cuenta pasan a la '
          'cuenta de la mesa ${widget.table.code}. Después revisa la cuenta y '
          'quita los que se hayan vuelto a teclear.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Unir'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _resolve(account, merge: true);
  }

  Future<void> _void(ReviewAccount account) async {
    // Igual que «Anular orden»: el dueño pasa directo; cualquier otro rol,
    // con PIN de Supervisor o Administrador.
    if (!operatorIsOwner(ref)) {
      final authorized = await showPinVerificationModal(
        context,
        ref,
        level: PinAccessLevel.supervisor,
        title: 'Autorización para anular',
        subtitle:
            'Se requiere PIN de Supervisor o Administrador para anular esta cuenta.',
      );
      if (!authorized || !mounted) return;
    }
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const _VoidReasonDialog(),
    );
    if (reason == null || reason.trim().isEmpty || !mounted) return;
    await _resolve(account, merge: false, reason: reason.trim());
  }

  Future<void> _move(ReviewAccount account) async {
    // Igual que transferir/unir mesas: el dueño o quien tenga
    // 'ventas.mesas.mover_unir' pasa directo; los demás, con PIN de Supervisor.
    if (!operatorIsOwner(ref) &&
        !operatorHasPermission(ref, 'ventas.mesas.mover_unir')) {
      final authorized = await showPinVerificationModal(
        context,
        ref,
        level: PinAccessLevel.supervisor,
        title: 'Autorización para mover',
        subtitle:
            'Se requiere PIN de Supervisor o Administrador para mover esta cuenta a otra mesa.',
      );
      if (!authorized || !mounted) return;
    }
    final salon = ref.read(byZoneVmProvider);
    final targets = reviewMoveTargets(
      zones: salon.zones,
      statusByZone: salon.statusByZone,
      excludeTableId: widget.table.tableId,
    );
    if (targets.isEmpty) {
      _notify('No hay otras mesas en el salón.', error: true);
      return;
    }
    final format = currentBusinessCurrencyOrFallback(ref).formatAmount;
    final target = await showDialog<ReviewMoveTarget>(
      context: context,
      builder: (_) => _MoveTargetDialog(targets: targets, format: format),
    );
    if (target == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Mover a ${target.code}'),
        content: Text(
          target.occupied
              ? 'Los ${account.items.length} productos de esta cuenta se suman a '
                    'la cuenta de ${target.code} (${format(target.total)}). '
                    'Después revisa esa cuenta y quita los que se hayan vuelto a '
                    'teclear.'
              : 'Esta cuenta pasa a ser la cuenta de ${target.code}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Mover'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busyOrderId = account.orderId);
    try {
      final result = await ref
          .read(orderReviewRepositoryProvider)
          .moveToTable(account.orderId, target.tableId);
      if (!mounted) return;
      _refreshSalon();
      if (target.zoneId != widget.table.zoneId) {
        ref.read(byZoneVmProvider.notifier).loadZoneStatus(target.zoneId);
      }
      switch (result.resolution) {
        case ReviewResolution.moved:
          _notify('La cuenta pasó a ${target.code}.');
        case ReviewResolution.merged:
          _notify(
            'Se sumaron ${result.itemsMoved} productos a la cuenta de '
            '${target.code}. Revisa y quita los repetidos.',
          );
        case ReviewResolution.hasPayments:
          _notify(
            'Esta cuenta tiene cobros registrados: no se puede mover aquí. '
            'Revísala desde el Historial de ventas.',
            error: true,
          );
        case ReviewResolution.promoted:
        case ReviewResolution.voided:
        case ReviewResolution.alreadyResolved:
          _notify('Esta cuenta ya se resolvió.');
      }
      _reload();
    } catch (e) {
      _notify('No se pudo mover: ${FriendlyError.from(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busyOrderId = null);
    }
  }

  Future<void> _resolve(
    ReviewAccount account, {
    required bool merge,
    String? reason,
  }) async {
    setState(() => _busyOrderId = account.orderId);
    try {
      final result = await ref
          .read(orderReviewRepositoryProvider)
          .resolve(account.orderId, merge: merge, reason: reason);
      if (!mounted) return;
      _refreshSalon();
      switch (result.resolution) {
        case ReviewResolution.merged:
          _notify(
            'Se unieron ${result.itemsMoved} productos a la cuenta de la mesa. '
            'Revisa y quita los repetidos.',
          );
          Navigator.of(context).pop(true);
          return;
        case ReviewResolution.promoted:
          _notify('La cuenta recuperada ahora es la cuenta de la mesa.');
          Navigator.of(context).pop(true);
          return;
        case ReviewResolution.voided:
          _notify('Cuenta anulada como duplicado.');
        case ReviewResolution.hasPayments:
          _notify(
            'Esta cuenta tiene cobros registrados: no se puede unir ni anular '
            'aquí. Revísala desde el Historial de ventas.',
            error: true,
          );
        case ReviewResolution.moved:
        case ReviewResolution.alreadyResolved:
          _notify('Esta cuenta ya se resolvió.');
      }
      _reload();
    } catch (e) {
      _notify('No se pudo resolver: ${FriendlyError.from(e)}', error: true);
    } finally {
      if (mounted) setState(() => _busyOrderId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currency = currentBusinessCurrencyOrFallback(ref);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.call_split_rounded,
                    color: AppColors.destructive,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${widget.table.code} · cuentas por revisar',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cerrar',
                    onPressed: () => Navigator.of(context).pop(false),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Esta mesa tiene una cuenta que llegó de otro equipo. No se '
                'cobra ni se mezcla sola: revisa si sus productos ya se '
                'volvieron a teclear y únela a la cuenta actual o anúlala.',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: FutureBuilder<List<ReviewAccount>>(
                  future: _accounts,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'No se pudieron cargar: '
                            '${FriendlyError.from(snapshot.error)}',
                          ),
                          TextButton(
                            onPressed: _reload,
                            child: const Text('Reintentar'),
                          ),
                        ],
                      );
                    }
                    final accounts = snapshot.data ?? const <ReviewAccount>[];
                    if (accounts.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Text('No quedan cuentas por revisar.'),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      itemCount: accounts.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, i) => _ReviewAccountCard(
                        account: accounts[i],
                        format: currency.formatAmount,
                        busy: _busyOrderId == accounts[i].orderId,
                        disabled: _busyOrderId != null,
                        onMerge: () => _merge(accounts[i]),
                        onVoid: () => _void(accounts[i]),
                        onMove: () => _move(accounts[i]),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busyOrderId != null
                    ? null
                    : () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.table_restaurant_outlined),
                label: Text(
                  widget.table.total > 0
                      ? 'Abrir la cuenta de la mesa '
                            '(${currency.formatAmount(widget.table.total)})'
                      : 'Abrir la cuenta de la mesa',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewAccountCard extends StatelessWidget {
  final ReviewAccount account;
  final String Function(num) format;
  final bool busy;
  final bool disabled;
  final VoidCallback onMerge;
  final VoidCallback onVoid;
  final VoidCallback onMove;

  const _ReviewAccountCard({
    required this.account,
    required this.format,
    required this.busy,
    required this.disabled,
    required this.onMerge,
    required this.onVoid,
    required this.onMove,
  });

  @override
  Widget build(BuildContext context) {
    final at = account.reviewAt;
    const maxLines = 8;
    final shown = account.items.take(maxLines).toList(growable: false);
    final hidden = account.items.length - shown.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.destructive.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.destructive.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'Cuenta en revisión',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.destructive,
                ),
              ),
              const Spacer(),
              if (at != null)
                Text(
                  DateFormat('hh:mm a').format(at),
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                ),
            ],
          ),
          if (account.waiterName != null || account.tableCode != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (account.waiterName != null)
                  'Tomada por ${account.waiterName}',
                if (account.tableCode != null) account.tableCode!,
              ].join(' · '),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 4),
          Text(account.reasonLabel, style: const TextStyle(fontSize: 12.5)),
          const SizedBox(height: 8),
          for (final item in shown)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_qty(item.quantity)} × ${item.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(format(item.total)),
                ],
              ),
            ),
          if (hidden > 0)
            Text(
              '+$hidden más',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.mutedForeground,
              ),
            ),
          if (account.items.isEmpty)
            const Text(
              'Todavía sin productos (pueden estar llegando).',
              style: TextStyle(fontSize: 12.5),
            ),
          const Divider(height: 16),
          Row(
            children: [
              const Text(
                'Total',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                format(account.total),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (busy)
            const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: disabled ? null : onVoid,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.destructive,
                  ),
                  child: const Text('Anular (era duplicado)'),
                ),
                OutlinedButton(
                  onPressed: disabled ? null : onMove,
                  child: const Text('Mover a otra mesa'),
                ),
                FilledButton(
                  onPressed: disabled ? null : onMerge,
                  child: const Text('Unir a la cuenta actual'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static String _qty(double q) =>
      q == q.roundToDouble() ? q.toInt().toString() : q.toString();
}

class _VoidReasonDialog extends StatefulWidget {
  const _VoidReasonDialog();

  @override
  State<_VoidReasonDialog> createState() => _VoidReasonDialogState();
}

class _VoidReasonDialogState extends State<_VoidReasonDialog> {
  final _controller = TextEditingController(
    text: 'Duplicado: se volvió a teclear en la cuenta actual',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Anular cuenta en revisión'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 2,
        decoration: const InputDecoration(labelText: 'Motivo (obligatorio)'),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.destructive),
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Anular'),
        ),
      ],
    );
  }
}

/// Mesa a la que se puede mover una cuenta en revisión.
class ReviewMoveTarget {
  final String tableId;
  final String zoneId;
  final String code;
  final String zoneName;
  final bool occupied;
  final double total;

  const ReviewMoveTarget({
    required this.tableId,
    required this.zoneId,
    required this.code,
    required this.zoneName,
    required this.occupied,
    required this.total,
  });
}

/// Mesas del salón (las que ya cargó, en el orden de sus zonas) menos la de
/// la cuenta. «Ocupada» con el mismo criterio que pinta la tarjeta.
List<ReviewMoveTarget> reviewMoveTargets({
  required List<Zone> zones,
  required Map<String, List<TableStatus>> statusByZone,
  required String excludeTableId,
}) {
  final ordered = [...zones]
    ..sort((a, b) => a.sortIndex.compareTo(b.sortIndex));
  return [
    for (final zone in ordered)
      for (final t in statusByZone[zone.id] ?? const <TableStatus>[])
        if (t.tableId != excludeTableId)
          ReviewMoveTarget(
            tableId: t.tableId,
            zoneId: zone.id,
            code: t.code,
            zoneName: zone.name,
            occupied: !isTableEffectivelyEmpty(t),
            total: t.total,
          ),
  ];
}

class _MoveTargetDialog extends StatefulWidget {
  final List<ReviewMoveTarget> targets;
  final String Function(num) format;

  const _MoveTargetDialog({required this.targets, required this.format});

  @override
  State<_MoveTargetDialog> createState() => _MoveTargetDialogState();
}

class _MoveTargetDialogState extends State<_MoveTargetDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final shown = q.isEmpty
        ? widget.targets
        : widget.targets
              .where(
                (t) =>
                    t.code.toLowerCase().contains(q) ||
                    t.zoneName.toLowerCase().contains(q),
              )
              .toList(growable: false);
    return AlertDialog(
      title: const Text('¿A qué mesa la mueves?'),
      content: SizedBox(
        width: 420,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar mesa o zona',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('Ninguna mesa coincide.'))
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (_, i) {
                        final t = shown[i];
                        return ListTile(
                          dense: true,
                          title: Text(t.code),
                          subtitle: Text(t.zoneName),
                          trailing: Text(
                            t.occupied
                                ? 'Ocupada · ${widget.format(t.total)}'
                                : 'Libre',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: t.occupied
                                  ? AppColors.warning
                                  : AppColors.success,
                            ),
                          ),
                          onTap: () => Navigator.of(context).pop(t),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
