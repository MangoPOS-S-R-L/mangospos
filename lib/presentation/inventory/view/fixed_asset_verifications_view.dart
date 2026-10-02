// Activos fijos — historial de verificaciones (20261001_0050).
//
// Las abiertas arriba (con su avance: «18 de 30 revisados»), después las
// cerradas y canceladas con su resumen. Tocar una abre la verificación.
//
// Acá vive también el diálogo para ABRIR una verificación, que se usa desde
// esta pantalla y desde el botón «Verificar» de Activos fijos.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/app_toast.dart';
import '../../../core/utils/friendly_error.dart';
import '../../../data/repositories/fixed_assets_repository.dart';
import '../../../services/session/session_controller.dart';
import '../state/fixed_asset_verification_state.dart';
import '../state/fixed_assets_state.dart';
import 'fixed_asset_form_dialog.dart';
import 'fixed_assets_view.dart' show kFixedAssetsManagePermission;

String _fmtDateTime(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
}

/// Abre (o retoma) una verificación y navega a ella. Devuelve cuando el
/// usuario vuelve de la verificación (para que quien llama recargue).
Future<void> startFixedAssetVerification(
  BuildContext context, {
  required FixedAssetsRepository repo,
  required String businessId,
  required List<FixedAssetOption> warehouses,
}) async {
  final verification = await showDialog<FixedAssetVerification>(
    context: context,
    barrierDismissible: false,
    builder: (_) => StartVerificationDialog(
      repo: repo,
      businessId: businessId,
      warehouses: warehouses,
    ),
  );
  if (verification == null || !context.mounted) return;
  if (verification.resumed) {
    AppToast.info(
      context,
      'Ya había una verificación abierta de esta ubicación: la continúas.',
    );
  }
  await context.push(AppRoutes.fixedAssetVerification(verification.id));
}

/// Elegir la ubicación (o todas) y una nota; abre con el RPC y devuelve la
/// verificación (nueva o la que ya estaba abierta).
class StartVerificationDialog extends StatefulWidget {
  const StartVerificationDialog({
    super.key,
    required this.repo,
    required this.businessId,
    required this.warehouses,
  });

  final FixedAssetsRepository repo;
  final String businessId;
  final List<FixedAssetOption> warehouses;

  @override
  State<StartVerificationDialog> createState() =>
      _StartVerificationDialogState();
}

/// Valor del selector que significa «todas las ubicaciones».
const _allScope = '__todas__';

class _StartVerificationDialogState extends State<StartVerificationDialog> {
  late String _scope = widget.warehouses.isEmpty
      ? _allScope
      : widget.warehouses.first.id;
  final _notes = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final v = await widget.repo.startVerification(
        businessId: widget.businessId,
        warehouseId: _scope == _allScope ? null : _scope,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context, v);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = fixedAssetSaveError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 12 : 40,
        vertical: 24,
      ),
      title: const Text('Verificar activos'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Elige la ubicación que vas a recorrer. El sistema arma la '
                'lista de lo que debería estar ahí y tú confirmas lo que '
                'encuentras escaneando la etiqueta.',
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                key: const Key('verification-start-scope'),
                initialValue: _scope,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Ubicación',
                  isDense: true,
                ),
                items: [
                  for (final w in widget.warehouses)
                    DropdownMenuItem(
                      value: w.id,
                      child: Text(w.name, overflow: TextOverflow.ellipsis),
                    ),
                  const DropdownMenuItem(
                    value: _allScope,
                    child: Text(kAllLocationsLabel),
                  ),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _scope = v ?? _allScope),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Nota (opcional)',
                  hintText: 'Ej.: Conteo de cierre de mes',
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  key: const Key('verification-start-error'),
                  style: TextStyle(color: AppColors.destructive, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('verification-start-confirm'),
          onPressed: _saving ? null : _start,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Empezar'),
        ),
      ],
    );
  }
}

/// Pastilla de estado de una verificación.
class FixedAssetVerificationStatusBadge extends StatelessWidget {
  const FixedAssetVerificationStatusBadge(this.status, {super.key});

  final FixedAssetVerificationStatus status;

  @override
  Widget build(BuildContext context) {
    final color = status.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}

/// «28 en orden · 2 faltantes (RD$5,000.00) · 1 nuevo», del resumen.
String fixedAssetVerificationSummaryLabel(
  FixedAssetVerificationSummary s,
  BusinessCurrency money,
) {
  return [
    '${s.okCount} en orden',
    if (s.missingCount > 0)
      '${s.missingCount} con faltante (${money.formatAmount(s.missingValue)})',
    if (s.lostCount > 0) '${s.lostCount} dados por perdidos',
    if (s.pendingCount > 0) '${s.pendingCount} pendientes de búsqueda',
    if (s.misplacedCount > 0) '${s.misplacedCount} fuera de lugar',
    if (s.newCount > 0) '${s.newCount} ${s.newCount == 1 ? 'nuevo' : 'nuevos'}',
  ].join(' · ');
}

class FixedAssetVerificationsView extends ConsumerStatefulWidget {
  const FixedAssetVerificationsView({super.key});

  @override
  ConsumerState<FixedAssetVerificationsView> createState() =>
      _FixedAssetVerificationsViewState();
}

class _FixedAssetVerificationsViewState
    extends ConsumerState<FixedAssetVerificationsView> {
  bool _loading = true;
  bool _migrationMissing = false;
  String? _error;
  String? _businessId;
  List<FixedAssetVerification> _items = const [];
  List<FixedAssetOption> _warehouses = const [];

  FixedAssetsRepository get _repo => ref.read(fixedAssetsRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final businessId = await _repo.resolveBusinessId();
      if (businessId == null) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'No se pudo resolver el negocio activo.';
        });
        return;
      }
      _businessId = businessId;
      _warehouses = await _repo
          .listWarehouses(businessId)
          .catchError((_) => const <FixedAssetOption>[]);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = FriendlyError.from(e);
      });
    }
  }

  Future<void> _load() async {
    final businessId = _businessId;
    if (businessId == null) return;
    setState(() => _loading = true);
    try {
      final rows = await _repo.listVerifications(businessId);
      if (!mounted) return;
      setState(() {
        _items = rows;
        _loading = false;
        _migrationMissing = false;
        _error = null;
      });
    } on FixedAssetVerificationMigrationMissing {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _migrationMissing = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = FriendlyError.from(e);
      });
    }
  }

  Future<void> _start() async {
    final businessId = _businessId;
    if (businessId == null) return;
    await startFixedAssetVerification(
      context,
      repo: _repo,
      businessId: businessId,
      warehouses: _warehouses,
    );
    if (mounted) await _load();
  }

  Future<void> _open(FixedAssetVerification v) async {
    await context.push(AppRoutes.fixedAssetVerification(v.id));
    if (mounted) await _load();
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.inventoryFixedAssets);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider.notifier);
    ref.watch(sessionProvider);
    final canManage = session.hasPermission(kFixedAssetsManagePermission);
    final money = currentBusinessCurrencyOrFallback(ref);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: LayoutBuilder(
        builder: (context, c) {
          final pad = c.maxWidth >= 700 ? 24.0 : 14.0;
          return RefreshIndicator(
            onRefresh: _load,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(canManage),
                  const SizedBox(height: 18),
                  ..._body(money, canManage),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _header(bool canManage) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconButton(
              tooltip: 'Volver',
              icon: const Icon(Icons.arrow_back),
              onPressed: _back,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'Verificaciones de activos',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            IconButton.filledTonal(
              tooltip: 'Actualizar',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
            if (canManage)
              FilledButton.icon(
                key: const Key('verifications-new'),
                onPressed: _loading || _migrationMissing ? null : _start,
                icon: const Icon(Icons.fact_check_outlined, size: 18),
                label: const Text('Nueva verificación'),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _body(BusinessCurrency money, bool canManage) {
    if (_migrationMissing) {
      return const [
        _Notice(
          key: Key('verifications-migration-missing'),
          icon: Icons.construction_rounded,
          color: AppColors.warning,
          text:
              'Falta aplicar la migración '
              '20261001_0050_fixed_asset_verification.sql en Supabase.',
        ),
      ];
    }
    if (_error != null && _items.isEmpty) {
      return [
        _Notice(
          icon: Icons.error_outline,
          color: AppColors.destructive,
          text: _error!,
        ),
      ];
    }
    if (_loading && _items.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 80),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_items.isEmpty) {
      return [
        _Notice(
          icon: Icons.fact_check_outlined,
          color: AppColors.mutedForeground,
          text: canManage
              ? 'Todavía no hay verificaciones. Toca «Nueva verificación», '
                    'elige una ubicación y escanea lo que encuentres.'
              : 'Todavía no hay verificaciones.',
        ),
      ];
    }
    return [
      for (final v in _items) ...[
        _VerificationCard(
          verification: v,
          money: money,
          onTap: () => _open(v),
        ),
        const SizedBox(height: 10),
      ],
    ];
  }
}

class _VerificationCard extends StatelessWidget {
  const _VerificationCard({
    required this.verification,
    required this.money,
    required this.onTap,
  });

  final FixedAssetVerification verification;
  final BusinessCurrency money;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final v = verification;
    final muted = TextStyle(fontSize: 12.5, color: AppColors.mutedForeground);
    final who = [
      'Iniciada ${_fmtDateTime(v.startedAt)}',
      if ((v.startedByName ?? '').isNotEmpty) 'por ${v.startedByName}',
    ].join(' ');
    final progress = v.progress;
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: InkWell(
        key: ValueKey('verification-card-${v.id}'),
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: AppColors.border),
            boxShadow: AppShadows.cardElevated,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      v.fullTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: AppColors.foreground,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FixedAssetVerificationStatusBadge(v.status),
                ],
              ),
              const SizedBox(height: 4),
              Text(who, style: muted),
              const SizedBox(height: 8),
              if (v.isOpen) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress.fraction,
                    minHeight: 6,
                    backgroundColor: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    progress.label,
                    if (progress.extrasLabel.isNotEmpty) progress.extrasLabel,
                  ].join(' · '),
                  style: muted,
                ),
              ] else if (v.status == FixedAssetVerificationStatus.cancelled)
                Text('Cancelada: ${v.cancelReason ?? '—'}', style: muted)
              else if (v.summary != null)
                Text(
                  fixedAssetVerificationSummaryLabel(v.summary!, money),
                  style: muted,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: TextStyle(color: AppColors.foreground)),
          ),
        ],
      ),
    );
  }
}
