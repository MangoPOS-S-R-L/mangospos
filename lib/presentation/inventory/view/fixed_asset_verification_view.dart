// Activos fijos — UNA verificación (levantamiento físico, 20261001_0050).
//
// Se recorre la ubicación escaneando la etiqueta de cada cosa (con la
// pistola, sin tocar el campo, o escribiendo el código):
//   · estaba en la lista y es una pieza → queda «encontrado» al instante;
//   · estaba en la lista y es un grupo («Silla ×40») → «¿Cuántas hay?»;
//   · está registrado en OTRA ubicación → «¿Lo encontraste aquí?» (queda
//     «fuera de lugar»);
//   · está dado de baja → se explica que primero hay que reactivarlo;
//   · el código no existe → se ofrece registrarlo en el acto.
//
// Al cerrar solo se decide lo que no cuadra: faltantes (pendiente de búsqueda
// o perdido), sobrantes, fuera de lugar y estados distintos. Nada se aplica
// solo. Cerrada o cancelada, la pantalla es de solo lectura.
//
// Ver: `inventario.activos.acceso` (la ruta). Escribir:
// `inventario.activos.gestionar` (acá y en cada RPC).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router/routes.dart';
import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_radius.dart';
import '../../../core/theme/app_shadows.dart';
import '../../../core/utils/app_toast.dart';
import '../../../data/repositories/fixed_assets_repository.dart';
import '../../../services/session/session_controller.dart';
import '../../sales/widgets/pos_barcode_scanner.dart';
import '../services/fixed_assets_pdf.dart';
import '../state/fixed_asset_verification_state.dart';
import '../state/fixed_assets_state.dart';
import 'fixed_asset_detail_dialog.dart' show FixedAssetStatusBadge;
import 'fixed_asset_form_dialog.dart';
import 'fixed_asset_verifications_view.dart'
    show
        FixedAssetVerificationStatusBadge,
        fixedAssetVerificationSummaryLabel;
import 'fixed_assets_view.dart' show kFixedAssetsManagePermission;

String _fmtDateTime(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.day)}/${two(l.month)}/${l.year} ${two(l.hour)}:${two(l.minute)}';
}

Color _groupColor(VerificationLineGroup g) {
  switch (g) {
    case VerificationLineGroup.pending:
      return AppColors.mutedForeground;
    case VerificationLineGroup.found:
      return AppColors.success;
    case VerificationLineGroup.difference:
      return AppColors.warning;
    case VerificationLineGroup.misplaced:
      return AppColors.info;
    case VerificationLineGroup.isNew:
      return AppColors.reserved;
  }
}

/// Lo que devuelve el diálogo «¿Cuántas hay?».
@immutable
class _FoundResult {
  const _FoundResult(this.found, this.observedToSend, this.notes);

  final int found;

  /// Lo que se manda como `p_observed_status`: null = conservar lo anotado;
  /// el estado ACTUAL del activo = «sin cambio» (borra lo anotado).
  final FixedAssetStatus? observedToSend;
  final String? notes;
}

class FixedAssetVerificationView extends ConsumerStatefulWidget {
  const FixedAssetVerificationView({super.key, required this.verificationId});

  final String verificationId;

  @override
  ConsumerState<FixedAssetVerificationView> createState() =>
      _FixedAssetVerificationViewState();
}

class _FixedAssetVerificationViewState
    extends ConsumerState<FixedAssetVerificationView> {
  static const _pageSize = 150;

  bool _loading = true;
  bool _migrationMissing = false;
  String? _error;
  String? _businessId;
  FixedAssetVerification? _v;
  List<FixedAsset> _assets = const [];
  List<FixedAssetOption> _warehouses = const [];
  List<FixedAssetOption> _employees = const [];
  VerificationLineGroup? _group;
  String _query = '';
  int _visible = _pageSize;

  final _scanCtrl = TextEditingController();
  final _scanFocus = FocusNode();
  final _searchCtrl = TextEditingController();

  /// Hay un diálogo abierto: un escaneo en este momento abriría otro encima.
  bool _dialogOpen = false;

  /// Cerrando o cancelando.
  bool _working = false;

  /// Activos con un RPC en vuelo (se deshabilitan sus botones).
  final Set<String> _busyAssets = {};

  /// Los escaneos se atienden en orden, uno a la vez.
  Future<void> _scanQueue = Future.value();
  String? _lastCode;
  DateTime? _lastCodeAt;

  bool _canManage = false;
  BusinessCurrency _money = BusinessCurrency.fallbackDop;

  FixedAssetsRepository get _repo => ref.read(fixedAssetsRepositoryProvider);

  bool get _writable => _canManage && (_v?.isOpen ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _scanCtrl.dispose();
    _scanFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Carga ────────────────────────────────────────────────────────────────

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
      final verification = await _repo.getVerification(widget.verificationId);
      // Los activos (para resolver los códigos), bodegas y empleados (para
      // el alta en el acto) son accesorios: si fallan, se puede seguir.
      final extras = await Future.wait<Object>([
        _repo
            .listAssets(businessId)
            .catchError((_) => const <FixedAsset>[]),
        _repo
            .listWarehouses(businessId)
            .catchError((_) => const <FixedAssetOption>[]),
        _repo
            .listEmployees(businessId)
            .catchError((_) => const <FixedAssetOption>[]),
      ]);
      if (!mounted) return;
      setState(() {
        _v = verification;
        _assets = extras[0] as List<FixedAsset>;
        _warehouses = extras[1] as List<FixedAssetOption>;
        _employees = extras[2] as List<FixedAssetOption>;
        _loading = false;
        _migrationMissing = false;
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
        _error = fixedAssetSaveError(e);
      });
    }
  }

  Future<void> _reloadVerification() async {
    try {
      final v = await _repo.getVerification(widget.verificationId);
      if (!mounted) return;
      setState(() => _v = v);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, fixedAssetSaveError(e));
    }
  }

  Future<void> _reloadAssets() async {
    final businessId = _businessId;
    if (businessId == null) return;
    try {
      final rows = await _repo.listAssets(businessId);
      if (!mounted) return;
      setState(() => _assets = rows);
    } catch (_) {
      // Sin la lista fresca se trabaja con la que había.
    }
  }

  // ── Escaneo ──────────────────────────────────────────────────────────────

  /// El campo «Escanea o escribe el código».
  void _onFieldSubmitted(String text) {
    final code = text.trim();
    _scanCtrl.clear();
    _enqueue(code);
    _scanFocus.requestFocus();
  }

  /// La pistola (teclado HID), con o sin foco en el campo. Si el campo tiene
  /// foco, lo escrito ahí manda: el despachador pudo cortar el código si la
  /// persona hizo una pausa a mitad.
  void _onPistolScan(String code) {
    final typed = _scanCtrl.text.trim();
    final effective = _scanFocus.hasFocus &&
            typed.isNotEmpty &&
            normalizeFixedAssetCode(typed).endsWith(normalizeFixedAssetCode(code))
        ? typed
        : code;
    _scanCtrl.clear();
    _enqueue(effective);
  }

  void _enqueue(String code) {
    if (code.isEmpty || !_writable) return;
    final now = DateTime.now();
    // El mismo código dos veces en un instante es el mismo escaneo llegando
    // por los dos caminos (campo + pistola).
    final last = _lastCode;
    final lastAt = _lastCodeAt;
    if (last != null &&
        lastAt != null &&
        normalizeFixedAssetCode(last) == normalizeFixedAssetCode(code) &&
        now.difference(lastAt) < const Duration(milliseconds: 700)) {
      return;
    }
    _lastCode = code;
    _lastCodeAt = now;
    if (_dialogOpen) {
      AppToast.warning(
        context,
        'Termina lo que tienes abierto antes de escanear otra etiqueta.',
      );
      return;
    }
    _scanQueue = _scanQueue
        .then((_) => _handleCode(code))
        .catchError((Object e) {
          if (mounted) AppToast.error(context, fixedAssetSaveError(e));
        });
  }

  Future<T?> _openDialog<T>(WidgetBuilder builder) async {
    setState(() => _dialogOpen = true);
    try {
      return await showDialog<T>(
        context: context,
        barrierDismissible: false,
        builder: builder,
      );
    } finally {
      if (mounted) {
        setState(() => _dialogOpen = false);
        if (_writable) _scanFocus.requestFocus();
      }
    }
  }

  Future<void> _handleCode(String code) async {
    final v = _v;
    if (v == null || !v.isOpen) return;
    var asset = findFixedAssetByCode(_assets, code);
    if (asset == null) {
      // Pudo darse de alta en otra terminal hace un momento.
      await _reloadAssets();
      asset = findFixedAssetByCode(_assets, code);
    }
    if (!mounted) return;
    if (asset == null) return _askCreateUnknown(code);
    if (asset.status.isRetired) return _explainRetired(asset);

    final line = v.lineFor(asset.id);
    if (line != null && line.expected) {
      final expectedQty = line.expectedQty ?? asset.quantity;
      if (expectedQty <= 1) {
        await _check(
          asset.id,
          found: 1,
          success: 'Encontrado: ${asset.name}',
        );
        return;
      }
      final r = await _openDialog<_FoundResult>(
        (_) => _FoundDialog(
          title: '¿Cuántas hay?',
          assetLabel: '${asset!.code} · ${asset.name}',
          expectedQty: expectedQty,
          initialFound: line.foundQty ?? expectedQty,
          initialObserved: line.observedStatus,
          assetStatus: asset.status,
          minFound: 0,
          confirmLabel: 'Guardar',
        ),
      );
      if (r != null) await _checkWith(asset.id, r, asset.name);
      return;
    }

    // Registrado en otra ubicación (o en ninguna), o ya anotado como fuera
    // de lugar / nuevo en esta verificación.
    final isNewLine = line?.isNew ?? false;
    final sameWarehouse =
        !v.isAllLocations && asset.warehouseId == v.warehouseId;
    final String title;
    final String? message;
    if (isNewLine) {
      title = 'Se registró en esta verificación';
      message = 'Corrige la cantidad encontrada si hace falta.';
    } else if (v.isAllLocations || sameWarehouse) {
      title = 'No estaba en la lista al abrir la verificación';
      message = '¿Lo encontraste?';
    } else {
      final where =
          asset.warehouseName.isEmpty ? 'ninguna ubicación' : asset.warehouseName;
      title = 'Este activo está registrado en $where';
      message = '¿Lo encontraste aquí, en ${v.warehouseName}?';
    }
    final r = await _openDialog<_FoundResult>(
      (_) => _FoundDialog(
        key: const Key('verification-misplaced-dialog'),
        title: title,
        message: message,
        assetLabel: '${asset!.code} · ${asset.name}',
        initialFound: line?.foundQty ?? asset.quantity,
        initialObserved: line?.observedStatus,
        assetStatus: asset.status,
        minFound: 1,
        confirmLabel: isNewLine ? 'Guardar' : 'Sí, está aquí',
      ),
    );
    if (r != null) await _checkWith(asset.id, r, asset.name);
  }

  Future<void> _explainRetired(FixedAsset asset) async {
    await _openDialog<void>(
      (ctx) => AlertDialog(
        key: const Key('verification-retired-dialog'),
        title: Text('${asset.code} está dado de baja'),
        content: Text(
          '«${asset.name}» se dio de baja'
          '${asset.retiredReason == null ? '' : ' (${asset.retiredReason})'}. '
          'Si de verdad está aquí, reactívalo desde su ficha en Activos fijos '
          'y vuelve a escanearlo.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Future<void> _askCreateUnknown(String code) async {
    final create = await _openDialog<bool>(
      (ctx) => AlertDialog(
        key: const Key('verification-unknown-dialog'),
        title: const Text('Código no registrado'),
        content: Text('El código «$code» no está registrado. ¿Registrarlo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('No'),
          ),
          FilledButton(
            key: const Key('verification-unknown-create'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Registrarlo'),
          ),
        ],
      ),
    );
    if (create == true && mounted) await _addAsset(code: code);
  }

  // ── Acciones sobre las líneas ────────────────────────────────────────────

  FixedAsset? _assetById(String id) {
    for (final a in _assets) {
      if (a.id == id) return a;
    }
    return null;
  }

  Future<void> _check(
    String assetId, {
    required int found,
    FixedAssetStatus? observed,
    String? notes,
    String? success,
  }) async {
    final v = _v;
    if (v == null) return;
    setState(() => _busyAssets.add(assetId));
    try {
      final line = await _repo.checkVerificationLine(
        verificationId: v.id,
        assetId: assetId,
        foundQty: found,
        observedStatus: observed,
        notes: notes,
      );
      if (!mounted) return;
      setState(() => _v = _v!.withLine(line));
      if (success != null) AppToast.success(context, success);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, fixedAssetSaveError(e));
      if (e.toString().contains('FIXED_ASSET_VERIFICATION_NOT_OPEN')) {
        await _reloadVerification();
      }
    } finally {
      if (mounted) setState(() => _busyAssets.remove(assetId));
    }
  }

  Future<void> _checkWith(String assetId, _FoundResult r, String name) =>
      _check(
        assetId,
        found: r.found,
        observed: r.observedToSend,
        notes: r.notes,
        success: r.found == 0 ? 'Anotado: $name no está' : 'Anotado: $name',
      );

  Future<void> _markPresent(FixedAssetVerificationLine l) => _check(
        l.assetId,
        found: l.expectedQty ?? 1,
        success: 'Encontrado: ${l.assetName}',
      );

  Future<void> _markMissing(FixedAssetVerificationLine l) => _check(
        l.assetId,
        found: 0,
        success: 'Anotado: ${l.assetName} no está',
      );

  Future<void> _editLine(FixedAssetVerificationLine l) async {
    final asset = _assetById(l.assetId);
    final r = await _openDialog<_FoundResult>(
      (_) => _FoundDialog(
        title: 'Lo encontrado',
        assetLabel: '${l.assetCode} · ${l.assetName}',
        expectedQty: l.expected ? l.expectedQty : null,
        initialFound: l.foundQty ?? l.expectedQty ?? 1,
        initialObserved: l.observedStatus,
        assetStatus: asset?.status ?? l.expectedStatus,
        minFound: l.expected ? 0 : 1,
        confirmLabel: 'Guardar',
      ),
    );
    if (r != null) await _checkWith(l.assetId, r, l.assetName);
  }

  Future<void> _undo(FixedAssetVerificationLine l) async {
    final v = _v;
    if (v == null) return;
    setState(() => _busyAssets.add(l.assetId));
    try {
      final r = await _repo.uncheckVerificationLine(
        verificationId: v.id,
        assetId: l.assetId,
      );
      if (!mounted) return;
      setState(() {
        if (r.removed) {
          _v = _v!.withoutLine(l.assetId);
        } else if (r.line != null) {
          _v = _v!.withLine(r.line!);
        }
      });
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, fixedAssetSaveError(e));
    } finally {
      if (mounted) setState(() => _busyAssets.remove(l.assetId));
    }
  }

  Future<void> _addAsset({String? code}) async {
    final v = _v;
    final businessId = _businessId;
    if (v == null || businessId == null) return;
    final locked = v.isAllLocations
        ? null
        : FixedAssetOption(v.warehouseId!, v.warehouseName);
    FixedAssetVerificationLine? createdLine;
    final asset = await _openDialog<FixedAsset>(
      (_) => FixedAssetFormDialog(
        repo: _repo,
        businessId: businessId,
        warehouses: _warehouses,
        employees: _employees,
        knownCategories: fixedAssetCategoriesIn(_assets),
        money: _money,
        initialCode: code,
        lockedWarehouse: locked,
        title: code == null ? 'Registrar activo' : 'Registrar «$code»',
        onCreate: (draft, requestId) async {
          final r = await _repo.addVerificationAsset(
            verificationId: v.id,
            draft: draft,
            clientRequestId: requestId,
          );
          createdLine = r.line;
          return r.asset;
        },
      ),
    );
    if (asset == null || !mounted) return;
    setState(() {
      _assets = sortFixedAssetsByCode([
        for (final a in _assets)
          if (a.id != asset.id) a,
        asset,
      ]);
      final line = createdLine;
      if (line != null) _v = _v!.withLine(line);
    });
  }

  // ── Cerrar, cancelar, acta ───────────────────────────────────────────────

  Future<void> _close() async {
    final v = _v;
    if (v == null) return;
    final plan = VerificationClosePlan.from(v);
    final result = await _openDialog<VerificationCloseResult>(
      (_) => VerificationCloseDialog(
        verification: v,
        plan: plan,
        money: _money,
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _working = true);
    try {
      final closed = await _repo.closeVerification(
        verificationId: v.id,
        decisions: result.decisions,
        notes: result.notes,
      );
      if (!mounted) return;
      setState(() => _v = closed);
      AppToast.success(context, '${closed.title} cerrada.');
      unawaited(_reloadAssets());
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, fixedAssetSaveError(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _cancel() async {
    final v = _v;
    if (v == null) return;
    final reason = await _openDialog<String>(
      (_) => const _CancelDialog(),
    );
    if (reason == null || !mounted) return;
    setState(() => _working = true);
    try {
      final cancelled = await _repo.cancelVerification(
        verificationId: v.id,
        reason: reason,
      );
      if (!mounted) return;
      setState(() => _v = cancelled);
      AppToast.info(context, '${cancelled.title} cancelada.');
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, fixedAssetSaveError(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _printAct() async {
    final v = _v;
    final businessId = _businessId;
    if (v == null || businessId == null) return;
    try {
      final businessName = await _repo.getBusinessName(businessId);
      await FixedAssetsPdf.printVerificationAct(
        verification: v,
        businessName: businessName,
        printedBy: ref.read(sessionProvider).userName,
        currency: _money,
      );
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo generar el acta: $e');
    }
  }

  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.inventoryFixedAssetVerifications);
    }
  }

  // ── Pantalla ─────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider.notifier);
    ref.watch(sessionProvider);
    _canManage = session.hasPermission(kFixedAssetsManagePermission);
    _money = currentBusinessCurrencyOrFallback(ref);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: BarcodeScanListener(
        enabled: _writable,
        onScan: _onPistolScan,
        child: LayoutBuilder(
          builder: (context, c) {
            final pad = c.maxWidth >= 700 ? 24.0 : 12.0;
            final width = c.maxWidth - pad * 2;
            return RefreshIndicator(
              onRefresh: _reloadVerification,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.all(pad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _content(width),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _content(double width) {
    final back = IconButton(
      tooltip: 'Volver',
      icon: const Icon(Icons.arrow_back),
      onPressed: _back,
    );
    if (_migrationMissing) {
      return [
        back,
        const _Notice(
          key: Key('verification-migration-missing'),
          icon: Icons.construction_rounded,
          color: AppColors.warning,
          text:
              'Falta aplicar la migración '
              '20261001_0050_fixed_asset_verification.sql en Supabase.',
        ),
      ];
    }
    if (_loading && _v == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 80),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final v = _v;
    if (v == null) {
      return [
        back,
        _Notice(
          icon: Icons.error_outline,
          color: AppColors.destructive,
          text: _error ?? 'No se pudo cargar la verificación.',
          action: TextButton.icon(
            onPressed: _bootstrap,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reintentar'),
          ),
        ),
      ];
    }

    final wide = width >= 900;
    final counts = countVerificationGroups(v.lines);
    final filtered = filterVerificationLines(
      v.lines,
      group: _group,
      query: _query,
    );
    final shown = filtered.take(_visible).toList(growable: false);

    return [
      _header(v, back, width),
      const SizedBox(height: 14),
      if (_writable) ...[_scanBar(), const SizedBox(height: 14)],
      if (v.status == FixedAssetVerificationStatus.closed && v.summary != null)
        ...[_SummaryCard(verification: v, money: _money), const SizedBox(height: 14)],
      if (v.status == FixedAssetVerificationStatus.cancelled) ...[
        _Notice(
          icon: Icons.block_rounded,
          color: AppColors.mutedForeground,
          text:
              'Cancelada${v.closedByName == null ? '' : ' por ${v.closedByName}'}'
              '${v.closedAt == null ? '' : ' el ${_fmtDateTime(v.closedAt)}'}. '
              'Motivo: ${v.cancelReason ?? '—'}. Lo que se registró durante '
              'ella se quedó en Activos fijos.',
        ),
        const SizedBox(height: 14),
      ],
      _filters(counts, v.lines.length, width),
      const SizedBox(height: 10),
      _Card(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (filtered.isEmpty)
              Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  v.lines.isEmpty
                      ? 'Esta ubicación no tenía activos registrados. '
                            'Escanea o agrega lo que encuentres.'
                      : 'Nada en este grupo.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.mutedForeground),
                ),
              )
            else ...[
              if (wide) const _LinesHeader(),
              for (final l in shown)
                _LineTile(
                  line: l,
                  wide: wide,
                  writable: _writable,
                  busy: _busyAssets.contains(l.assetId),
                  closed: v.status == FixedAssetVerificationStatus.closed,
                  verificationWarehouse: v.warehouseName,
                  onPresent: () => _markPresent(l),
                  onMissing: () => _markMissing(l),
                  onEdit: () => _editLine(l),
                  onUndo: () => _undo(l),
                ),
              if (filtered.length > shown.length)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: TextButton.icon(
                      onPressed: () => setState(() => _visible += _pageSize),
                      icon: const Icon(Icons.expand_more),
                      label: Text(
                        'Ver más (${filtered.length - shown.length} restantes)',
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    ];
  }

  Widget _header(FixedAssetVerification v, Widget back, double width) {
    final progress = v.progress;
    final muted = TextStyle(fontSize: 13, color: AppColors.mutedForeground);
    final started = [
      'Iniciada ${_fmtDateTime(v.startedAt)}',
      if ((v.startedByName ?? '').isNotEmpty) 'por ${v.startedByName}',
    ].join(' ');
    final closedLine = v.status == FixedAssetVerificationStatus.closed
        ? [
            'Cerrada ${_fmtDateTime(v.closedAt)}',
            if ((v.closedByName ?? '').isNotEmpty) 'por ${v.closedByName}',
          ].join(' ')
        : null;

    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          key: const Key('verification-act'),
          onPressed: _working ? null : _printAct,
          icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
          label: Text(v.isOpen ? 'Acta (borrador)' : 'Acta'),
        ),
        if (_writable) ...[
          OutlinedButton.icon(
            key: const Key('verification-add'),
            onPressed: _working ? null : () => _addAsset(),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Agregar activo'),
          ),
          FilledButton.icon(
            key: const Key('verification-close'),
            onPressed: _working ? null : _close,
            icon: const Icon(Icons.task_alt_rounded, size: 18),
            label: const Text('Cerrar verificación'),
          ),
          TextButton(
            key: const Key('verification-cancel'),
            onPressed: _working ? null : _cancel,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.destructive,
            ),
            child: const Text('Cancelar verificación'),
          ),
        ],
      ],
    );

    return _Card(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              back,
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            v.fullTitle,
                            key: const Key('verification-title'),
                            style: TextStyle(
                              fontSize: width >= 600 ? 24 : 20,
                              fontWeight: FontWeight.w800,
                              color: AppColors.foreground,
                            ),
                          ),
                          FixedAssetVerificationStatusBadge(v.status),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(started, style: muted),
                      if (closedLine != null) Text(closedLine, style: muted),
                      if ((v.notes ?? '').isNotEmpty)
                        Text('Nota: ${v.notes}', style: muted),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress.fraction,
                    minHeight: 8,
                    backgroundColor: AppColors.muted,
                    color: AppColors.success,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    progress.label,
                    if (progress.extrasLabel.isNotEmpty) progress.extrasLabel,
                  ].join(' · '),
                  key: const Key('verification-progress'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.foreground,
                  ),
                ),
                const SizedBox(height: 12),
                actions,
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _scanBar() {
    return _Card(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('verification-scan'),
            controller: _scanCtrl,
            focusNode: _scanFocus,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: _onFieldSubmitted,
            decoration: InputDecoration(
              labelText: 'Escanea o escribe el código',
              hintText: 'Ej.: AF-00012',
              isDense: true,
              prefixIcon: const Icon(Icons.qr_code_scanner_rounded),
              suffixIcon: IconButton(
                tooltip: 'Buscar código',
                icon: const Icon(Icons.keyboard_return_rounded),
                onPressed: () => _onFieldSubmitted(_scanCtrl.text),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Con la pistola no hace falta tocar el campo: escanea y listo.',
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }

  Widget _filters(
    Map<VerificationLineGroup, int> counts,
    int total,
    double width,
  ) {
    Widget chip(VerificationLineGroup? g, String label, int count) {
      return ChoiceChip(
        key: ValueKey('verification-group-${g?.name ?? 'all'}'),
        label: Text('$label ($count)'),
        selected: _group == g,
        onSelected: (_) => setState(() {
          _group = g;
          _visible = _pageSize;
        }),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        chip(null, 'Todos', total),
        for (final g in VerificationLineGroup.values)
          chip(g, g.label, counts[g] ?? 0),
        SizedBox(
          width: width < 600 ? width : 260,
          child: TextField(
            key: const Key('verification-search'),
            controller: _searchCtrl,
            onChanged: (q) => setState(() {
              _query = q;
              _visible = _pageSize;
            }),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filtrar por código o nombre',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Piezas ─────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.border),
        boxShadow: AppShadows.cardElevated,
      ),
      child: child,
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: TextStyle(color: AppColors.foreground)),
                if (action != null) ...[const SizedBox(height: 8), action!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.verification, required this.money});

  final FixedAssetVerification verification;
  final BusinessCurrency money;

  @override
  Widget build(BuildContext context) {
    final s = verification.summary!;
    Widget stat(String label, String value, Color color) => Container(
          constraints: const BoxConstraints(minWidth: 130),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              Text(
                label,
                style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
              ),
            ],
          ),
        );
    return _Card(
      key: const Key('verification-summary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Resultado',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            fixedAssetVerificationSummaryLabel(s, money),
            style: TextStyle(fontSize: 13, color: AppColors.mutedForeground),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              stat('En orden', '${s.okCount}', AppColors.success),
              stat(
                'Valor faltante',
                money.formatAmount(s.missingValue),
                AppColors.destructive,
              ),
              stat('Dados por perdidos', '${s.lostCount}', AppColors.reserved),
              stat(
                'Pendientes de búsqueda',
                '${s.pendingCount}',
                AppColors.warning,
              ),
              stat('Fuera de lugar', '${s.misplacedCount}', AppColors.info),
              stat('Nuevos', '${s.newCount}', AppColors.reserved),
              stat(
                'Valor encontrado',
                money.formatAmount(s.foundValue),
                AppColors.success,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// Columnas de la tabla ancha (flex).
const _cCode = 2;
const _cName = 5;
const _cCounts = 4;
const _cStatus = 3;
const _cActions = 5;

class _LinesHeader extends StatelessWidget {
  const _LinesHeader();

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w800,
      color: AppColors.mutedForeground,
    );
    Widget cell(String t, int flex) =>
        Expanded(flex: flex, child: Text(t, style: style));
    return Container(
      color: AppColors.accent,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          cell('Código', _cCode),
          cell('Activo', _cName),
          cell('Conteo', _cCounts),
          cell('Estado', _cStatus),
          cell('', _cActions),
        ],
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.line,
    required this.wide,
    required this.writable,
    required this.busy,
    required this.closed,
    required this.verificationWarehouse,
    required this.onPresent,
    required this.onMissing,
    required this.onEdit,
    required this.onUndo,
  });

  final FixedAssetVerificationLine line;
  final bool wide;
  final bool writable;
  final bool busy;
  final bool closed;
  final String verificationWarehouse;
  final VoidCallback onPresent;
  final VoidCallback onMissing;
  final VoidCallback onEdit;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final l = line;
    final group = l.group;
    final color = _groupColor(group);
    final muted = TextStyle(fontSize: 12, color: AppColors.mutedForeground);
    final detail = [
      if (l.isMisplaced)
        'Registrado en ${l.registeredWarehouseName ?? 'ninguna ubicación'}',
      if (closed && l.resolution != null)
        fixedAssetResolutionLabel(l.resolution),
      if ((l.notes ?? '').isNotEmpty) '«${l.notes}»',
    ].join(' · ');

    final groupChip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        group.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
    final observed = l.hasConditionChange
        ? FixedAssetStatusBadge(l.observedStatus!, dense: true)
        : null;

    final actions = writable
        ? Wrap(
            spacing: 4,
            runSpacing: 4,
            alignment: wide ? WrapAlignment.end : WrapAlignment.start,
            children: [
              if (l.expected && l.foundQty != l.expectedQty)
                _ActionButton(
                  key: ValueKey('line-ok-${l.assetId}'),
                  icon: Icons.check_rounded,
                  label: 'Está',
                  color: AppColors.success,
                  onPressed: busy ? null : onPresent,
                ),
              if (l.expected && l.foundQty != 0)
                _ActionButton(
                  key: ValueKey('line-missing-${l.assetId}'),
                  icon: Icons.close_rounded,
                  label: 'No está',
                  color: AppColors.destructive,
                  onPressed: busy ? null : onMissing,
                ),
              _ActionButton(
                key: ValueKey('line-edit-${l.assetId}'),
                icon: Icons.edit_outlined,
                label: 'Cantidad / estado',
                onPressed: busy ? null : onEdit,
              ),
              if (l.isChecked && !l.isNew)
                _ActionButton(
                  key: ValueKey('line-undo-${l.assetId}'),
                  icon: Icons.undo_rounded,
                  label: 'Deshacer',
                  onPressed: busy ? null : onUndo,
                ),
            ],
          )
        : null;

    if (wide) {
      return Container(
        key: ValueKey('verification-line-${l.assetId}'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.cardDivider)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: _cCode,
              child: Text(
                l.assetCode,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.foreground,
                ),
              ),
            ),
            Expanded(
              flex: _cName,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.assetName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.foreground,
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                ],
              ),
            ),
            Expanded(
              flex: _cCounts,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.countsLabel,
                    style: TextStyle(fontSize: 13, color: AppColors.foreground),
                  ),
                  const SizedBox(height: 2),
                  groupChip,
                ],
              ),
            ),
            Expanded(
              flex: _cStatus,
              child: Align(
                alignment: Alignment.centerLeft,
                child: observed ?? Text('Sin cambio', style: muted),
              ),
            ),
            Expanded(
              flex: _cActions,
              child: busy
                  ? const Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : (actions ?? const SizedBox.shrink()),
            ),
          ],
        ),
      );
    }

    return Container(
      key: ValueKey('verification-line-${l.assetId}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.cardDivider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l.assetCode,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(child: groupChip),
              if (busy) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Text(
            l.assetName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            l.countsLabel,
            style: TextStyle(fontSize: 13, color: AppColors.foreground),
          ),
          if (detail.isNotEmpty) Text(detail, style: muted),
          if (observed != null) ...[const SizedBox(height: 4), observed],
          if (actions != null) ...[const SizedBox(height: 6), actions],
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color ?? AppColors.foreground,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}

// ── Diálogos ───────────────────────────────────────────────────────────────

/// «¿Cuántas hay?» + estado visto (opcional) + nota.
class _FoundDialog extends StatefulWidget {
  const _FoundDialog({
    super.key,
    required this.title,
    required this.assetLabel,
    required this.initialFound,
    required this.minFound,
    required this.confirmLabel,
    this.message,
    this.expectedQty,
    this.initialObserved,
    this.assetStatus,
  });

  final String title;
  final String? message;
  final String assetLabel;
  final int? expectedQty;
  final int initialFound;
  final FixedAssetStatus? initialObserved;

  /// Estado registrado del activo: mandarlo = «sin cambio».
  final FixedAssetStatus? assetStatus;
  final int minFound;
  final String confirmLabel;

  @override
  State<_FoundDialog> createState() => _FoundDialogState();
}

class _FoundDialogState extends State<_FoundDialog> {
  late final _qty = TextEditingController(text: '${widget.initialFound}');
  final _notes = TextEditingController();

  /// null = «Sin cambio».
  late FixedAssetStatus? _observed = widget.initialObserved;
  String? _error;

  @override
  void dispose() {
    _qty.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _bump(int delta) {
    final current = int.tryParse(_qty.text.trim()) ?? 0;
    final next = current + delta;
    if (next < widget.minFound) return;
    setState(() => _qty.text = '$next');
  }

  void _save() {
    final found = int.tryParse(_qty.text.trim());
    if (found == null || found < widget.minFound) {
      setState(
        () => _error = widget.minFound == 0
            ? 'Escribe cuántas hay (0 si no está).'
            : 'Escribe cuántas hay (al menos 1).',
      );
      return;
    }
    // «Sin cambio» después de haber anotado algo = mandar el estado actual
    // del activo, que el servidor guarda como «sin cambio». Si no se había
    // anotado nada, null (conservar) es lo mismo y más seguro.
    final FixedAssetStatus? send;
    if (_observed != null) {
      send = _observed;
    } else if (widget.initialObserved != null &&
        widget.assetStatus != null &&
        !widget.assetStatus!.isRetired) {
      send = widget.assetStatus;
    } else {
      send = null;
    }
    final notes = _notes.text.trim();
    Navigator.pop(
      context,
      _FoundResult(found, send, notes.isEmpty ? null : notes),
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 12 : 40,
        vertical: 24,
      ),
      title: Text(widget.title),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.assetLabel,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.foreground,
                ),
              ),
              if (widget.message != null) ...[
                const SizedBox(height: 6),
                Text(widget.message!),
              ],
              if (widget.expectedQty != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Esperado: ${widget.expectedQty}',
                  style: TextStyle(color: AppColors.mutedForeground),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  IconButton.outlined(
                    tooltip: 'Una menos',
                    onPressed: () => _bump(-1),
                    icon: const Icon(Icons.remove_rounded),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      key: const Key('verification-found-qty'),
                      controller: _qty,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(
                        labelText: 'Encontradas',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _save(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: 'Una más',
                    onPressed: () => _bump(1),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                'Estado visto (opcional)',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: AppColors.mutedForeground,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    key: const Key('verification-observed-none'),
                    label: const Text('Sin cambio'),
                    selected: _observed == null,
                    onSelected: (_) => setState(() => _observed = null),
                  ),
                  for (final s in FixedAssetStatus.selectable)
                    if (s != widget.assetStatus)
                      ChoiceChip(
                        key: ValueKey('verification-observed-${s.wire}'),
                        avatar: Icon(s.icon, size: 16, color: s.color),
                        label: Text(s.label),
                        selected: _observed == s,
                        onSelected: (_) => setState(() => _observed = s),
                      ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Nota (opcional)',
                  hintText: 'Ej.: le falta una pata',
                  isDense: true,
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(color: AppColors.destructive, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          key: const Key('verification-found-confirm'),
          onPressed: _save,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _CancelDialog extends StatefulWidget {
  const _CancelDialog();

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 12 : 40,
        vertical: 24,
      ),
      title: const Text('Cancelar verificación'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No se aplica nada de lo contado. Lo que registraste durante '
              'la verificación se queda en Activos fijos.',
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('verification-cancel-reason'),
              controller: _reason,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Motivo *',
                hintText: 'Ej.: se abrió por error',
                isDense: true,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: AppColors.destructive, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Volver'),
        ),
        FilledButton(
          key: const Key('verification-cancel-confirm'),
          style: FilledButton.styleFrom(backgroundColor: AppColors.destructive),
          onPressed: () {
            final reason = _reason.text.trim();
            if (reason.isEmpty) {
              setState(() => _error = 'Escribe el motivo de la cancelación.');
              return;
            }
            Navigator.pop(context, reason);
          },
          child: const Text('Cancelar verificación'),
        ),
      ],
    );
  }
}

/// Lo que devuelve el diálogo de cierre.
@immutable
class VerificationCloseResult {
  const VerificationCloseResult(this.decisions, this.notes);

  final List<Map<String, String>> decisions;
  final String? notes;
}

/// Cierre: SOLO lo que no cuadra, con los valores por defecto de
/// [VerificationCloseChoices.defaults]. Público para poder probarlo solo.
class VerificationCloseDialog extends StatefulWidget {
  const VerificationCloseDialog({
    super.key,
    required this.verification,
    required this.plan,
    required this.money,
  });

  final FixedAssetVerification verification;
  final VerificationClosePlan plan;
  final BusinessCurrency money;

  @override
  State<VerificationCloseDialog> createState() =>
      _VerificationCloseDialogState();
}

class _VerificationCloseDialogState extends State<VerificationCloseDialog> {
  late VerificationCloseChoices _choices = VerificationCloseChoices.defaults(
    widget.plan,
  );
  final _notes = TextEditingController();

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Widget _section(String title, String? subtitle, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: AppColors.foreground,
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
            ),
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }

  Widget _lineHeader(FixedAssetVerificationLine l, String detail) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${l.assetCode} · ${l.assetName}',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.foreground,
            ),
          ),
          Text(
            detail,
            style: TextStyle(fontSize: 12, color: AppColors.mutedForeground),
          ),
        ],
      ),
    );
  }

  Widget _check(
    String action,
    FixedAssetVerificationLine l,
    Set<String> selected,
    String label,
    String subtitle,
  ) {
    return CheckboxListTile(
      key: ValueKey('close-$action-${l.assetId}'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected.contains(l.assetId),
      onChanged: (on) => setState(
        () => _choices = _choices.toggle(action, l.assetId, on ?? false),
      ),
      title: Text('${l.assetCode} · ${l.assetName}'),
      subtitle: Text('$label · $subtitle'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final money = widget.money;
    final v = widget.verification;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final progress = v.progress;
    final lostValue = _choices.lostValue(plan);

    return AlertDialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: narrow ? 10 : 40,
        vertical: 24,
      ),
      title: Text('Cerrar ${v.title}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${progress.label}.'
                '${progress.checked < progress.expected ? ' Lo que no se revisó cuenta como faltante.' : ''}',
              ),
              if (plan.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Todo cuadra: no hay nada que decidir.',
                    key: const Key('close-all-ok'),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.success,
                    ),
                  ),
                ),
              if (plan.shortfalls.isNotEmpty)
                _section(
                  'Faltantes (${plan.shortfalls.length})',
                  'Si no decides nada, queda «pendiente de búsqueda» y el '
                      'activo no cambia.',
                  [
                    for (final l in plan.shortfalls) ...[
                      _lineHeader(
                        l,
                        [
                          'Esperado ${l.expectedQty ?? 0}',
                          l.foundQty == null
                              ? 'sin revisar'
                              : 'encontrado ${l.foundQty}',
                          'faltan ${l.shortfall} '
                              '(${money.formatAmount(l.missingValue)})',
                        ].join(' · '),
                      ),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          ChoiceChip(
                            key: ValueKey('close-pending-${l.assetId}'),
                            label: const Text('Pendiente de búsqueda'),
                            selected: !_choices.markLost.contains(l.assetId),
                            onSelected: (_) => setState(
                              () => _choices = _choices.toggle(
                                'mark_lost',
                                l.assetId,
                                false,
                              ),
                            ),
                          ),
                          ChoiceChip(
                            key: ValueKey('close-mark_lost-${l.assetId}'),
                            label: Text(
                              l.found == 0
                                  ? 'Marcar perdido'
                                  : 'Bajar cantidad a ${l.found}',
                            ),
                            selected: _choices.markLost.contains(l.assetId),
                            onSelected: (_) => setState(
                              () => _choices = _choices.toggle(
                                'mark_lost',
                                l.assetId,
                                true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              if (plan.surpluses.isNotEmpty)
                _section('Sobrantes (${plan.surpluses.length})', null, [
                  for (final l in plan.surpluses)
                    _check(
                      'set_quantity',
                      l,
                      _choices.setQuantity,
                      'Actualizar cantidad a ${l.foundQty}',
                      'esperado ${l.expectedQty ?? 0}',
                    ),
                ]),
              if (plan.misplaced.isNotEmpty)
                plan.canMove
                    ? _section('Fuera de lugar (${plan.misplaced.length})', null, [
                        for (final l in plan.misplaced)
                          _check(
                            'move_here',
                            l,
                            _choices.moveHere,
                            'Trasladar a ${v.warehouseName}',
                            'registrado en '
                                '${l.registeredWarehouseName ?? 'ninguna ubicación'}',
                          ),
                      ])
                    : _section(
                        'Fuera de lugar (${plan.misplaced.length})',
                        'En una verificación de todas las ubicaciones no hay a '
                            'dónde trasladar: quedan anotados en el acta.',
                        const [],
                      ),
              if (plan.conditionChanges.isNotEmpty)
                _section(
                  'Estado distinto (${plan.conditionChanges.length})',
                  null,
                  [
                    for (final l in plan.conditionChanges)
                      _check(
                        'apply_condition',
                        l,
                        _choices.applyCondition,
                        'Cambiar estado a ${l.observedStatus!.label}',
                        'registrado: ${l.expectedStatus?.label ?? '—'}',
                      ),
                  ],
                ),
              if (plan.shortfalls.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  'Valor faltante: ${money.formatAmount(plan.missingValue)}'
                  ' · se da por perdido: ${money.formatAmount(lostValue)}',
                  key: const Key('close-missing-value'),
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: AppColors.foreground,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(
                  labelText: 'Nota del cierre (opcional)',
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Volver'),
        ),
        FilledButton(
          key: const Key('close-confirm'),
          onPressed: () {
            final notes = _notes.text.trim();
            Navigator.pop(
              context,
              VerificationCloseResult(
                _choices.toDecisions(plan),
                notes.isEmpty ? null : notes,
              ),
            );
          },
          child: const Text('Cerrar verificación'),
        ),
      ],
    );
  }
}
