import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/core/network/supabase_config.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/utils/responsive_utils.dart';
import 'package:mangopos/presentation/cashier/widgets/blind_cash_close_dialog.dart';
import 'package:mangopos/presentation/cashier/widgets/open_cash_dialog.dart';
import 'package:mangopos/presentation/cashier/widgets/variance_confirm_dialog.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/data/repositories/cashier_repository.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/presentation/cashier/detailed_wizard/cash_close_detailed_wizard.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';
import 'package:mangopos/app/widgets/skeleton_loading.dart';

class CashierView extends ConsumerStatefulWidget {
  const CashierView({super.key});

  @override
  ConsumerState<CashierView> createState() => _CashierViewState();
}

class _CashierViewState extends ConsumerState<CashierView>
    with WidgetsBindingObserver {
  Timer? _refreshTimer;
  String? _lastBusinessId;
  bool _isVisible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cashierViewModelProvider).init();
    });

    // Auto-refresh every 30 seconds using silent refresh (no loading spinner)
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _isVisible) {
        ref.read(cashierViewModelProvider).refreshSilently();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isVisible = state == AppLifecycleState.resumed;
    if (_isVisible) {
      ref.read(cashierViewModelProvider).refreshSilently();
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _handleRefresh() async {
    await ref.read(cashierViewModelProvider).init();
  }

  @override
  Widget build(BuildContext context) {
    final appSession = ref.watch(sessionProvider);
    // Watch the full VM since CashierView is the main consumer and needs all data.
    // Sub-widgets receive data via constructor, so they don't watch independently.
    final vm = ref.watch(cashierViewModelProvider);
    final isLoading = vm.isLoading;
    final session = vm.lastSession;
    final isOpen = session != null && session['status'] == 'open';

    if (appSession.activeBusinessId != null &&
        appSession.activeBusinessId != _lastBusinessId) {
      _lastBusinessId = appSession.activeBusinessId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(cashierViewModelProvider).init();
        }
      });
    }

    if (isLoading && session == null) {
      return const CashierSkeleton();
    }

    final sessionCtrl = ref.read(sessionProvider.notifier);
    final canViewSummary = sessionCtrl.hasPermission('caja.arqueo_ver');
    final canViewMovements = sessionCtrl.hasPermission('caja.movimientos_ver');

    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F2),
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        color: MangoColors.primaryOrange,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(context.wp(2)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header section
              _HeaderSection(viewModel: vm, isOpen: isOpen),
              SizedBox(height: context.hp(2.5)),

              // Stats Cards - only for users with arqueo permission
              if (canViewSummary) ...[
                _StatsCardsSection(viewModel: vm),
                SizedBox(height: context.hp(2.5)),
              ],

              // Blind close info banner for cashiers without summary access
              if (!canViewSummary)
                _BlindCloseInfoBanner(isOpen: isOpen),

              // Action Cards
              _ActionCardsSection(
                isOpen: isOpen,
                onOpenCash: () => _showOpenCashDialog(context),
                onCloseCash: _showCloseCashDialog,
                canViewHistory: canViewSummary,
                canViewClosures: canViewSummary,
                canViewMovements: canViewMovements,
              ),
              SizedBox(height: context.hp(2.5)),

              // Recent Movements - only for users with summary access
              if (canViewSummary)
                _RecentMovementsSection(viewModel: vm),
            ],
          ),
        ),
      ),
    );
  }

  void _showOpenCashDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const OpenCashDialog(),
    );
  }

  Future<void> _showCloseCashDialog() async {
    final session = ref.read(cashierViewModelProvider).lastSession;
    if (session == null || session['status'] != 'open') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay una sesión de caja abierta'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Validar que la sesión pertenece al usuario actual
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null ||
        session['user_id']?.toString() != currentUserId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Esta sesión de caja no te pertenece. Solo el cajero que la abrió puede cerrarla.',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final pending = await ref
        .read(cashierViewModelProvider)
        .refreshPendingTablesCount();
    if (!mounted) return;

    var forceWithOpenTables = false;
    if (pending > 0) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: MangoColors.primaryOrange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  color: MangoColors.primaryOrange,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Órdenes abiertas',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 17,
                  color: MangoColors.darkGray,
                ),
              ),
            ],
          ),
          content: Text(
            'Hay $pending orden(es) activas sin cobrar o anular. ¿Deseas cerrar la caja de todas formas?',
            style: const TextStyle(
              color: MangoColors.darkGray,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              style: TextButton.styleFrom(
                foregroundColor: MangoColors.darkGray,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
              child: const Text(
                'Cancelar',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                textStyle: const TextStyle(fontWeight: FontWeight.w600),
              ),
              child: const Text('Continuar'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      forceWithOpenTables = true;
    }

    if (!mounted) return;

    final rootNavigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    CashCloseInput input;
    try {
      input = await _buildCloseInput(session);
    } catch (_) {
      input = _emptyCloseInput();
    } finally {
      if (rootNavigator.canPop()) {
        rootNavigator.pop();
      }
    }

    if (!mounted) return;

    // Sub-fase H · router strangler-fig: lee cash_close_mode del business y
    // monta el modo correcto. compact = dialog modal único existente;
    // detailed = wizard fullscreen de 3 pasos.
    final businessId = await BusinessResolver.ensure('auto');
    final mode = await ref
        .read(posSettingsRepositoryProvider)
        .getCashCloseMode(businessId);

    if (!mounted) return;

    if (mode == PosSettingsRepository.cashCloseDetailed) {
      await _openDetailedWizard(
        session: session,
        businessId: businessId,
        input: input,
        forceWithOpenTables: forceWithOpenTables,
      );
    } else {
      await _openCompactDialog(
        session: session,
        input: input,
        forceWithOpenTables: forceWithOpenTables,
      );
    }
  }

  Future<void> _openCompactDialog({
    required Map<String, dynamic> session,
    required CashCloseInput input,
    required bool forceWithOpenTables,
  }) async {
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => BlindCashCloseDialog(
        sessionId: session['id'].toString(),
        input: input,
        onCloseConfirmed: (result) async {
          final notes =
              'Cierre ciego | Efectivo: ${result.totalCounted} | Tarjetas: ${result.numericCard} | '
              'Transferencias: ${result.numericTransfer} | Total reportado: ${result.totalReported} | '
              'Dif. efectivo: ${result.cashDifference} | Dif. tarjeta: ${result.cardDifference} | '
              'Dif. transferencia: ${result.transferDifference} | Dif. total: ${result.totalDifference}';

          try {
            // Sprint Caja Pro Fase D — chequeo de varianza antes de
            // cerrar. Si la diferencia supera el umbral del negocio,
            // se pide nota obligatoria al admin/manager. Si cancela,
            // el cierre se aborta acá.
            final businessId =
                ref.read(sessionProvider).activeBusinessId ?? '';
            final closeResponse = await closeSessionWithVarianceCheck(
              context: context,
              ref: ref,
              businessId: businessId,
              sessionId: session['id'].toString(),
              endAmount: result.totalCounted.toDouble(),
              expectedCash: input.expectedCash.toDouble(),
              notes: notes,
              forceWithOpenTables: forceWithOpenTables,
            );
            if (closeResponse == null) {
              // Cancelado por el usuario en el dialog de varianza.
              return;
            }
            // Audit del modo usado (no bloquea si falla — se reintenta luego).
            unawaited(
              ref
                  .read(cashierRepositoryProvider)
                  .markSessionCloseMode(
                    sessionId: session['id'].toString(),
                    mode: PosSettingsRepository.cashCloseCompact,
                  )
                  .catchError((_) {}),
            );
            try {
              await ref.read(cashierViewModelProvider).init();
            } catch (e) {
              if (!SupabaseConfig.isTransientAuthRefreshError(e) &&
                  !SupabaseConfig.isAuthRefreshSchemaMismatchError(e)) {
                rethrow;
              }
            }
            if (!mounted) return;
            GoRouter.of(context).replace(AppRoutes.cashier);
          } catch (e) {
            String friendly;
            if (e is CashRegisterException) {
              switch (e.errorCode) {
                case 'OPEN_TABLES_EXIST':
                  final count = e.openTablesCount;
                  friendly = count != null
                      ? 'Hay $count mesa(s) abierta(s). Ciérralas primero o activa "Forzar cierre".'
                      : 'Hay mesas abiertas. Ciérralas primero o activa "Forzar cierre".';
                case 'SESSION_ALREADY_CLOSED':
                  friendly = 'Esta sesión de caja ya fue cerrada anteriormente.';
                case 'SESSION_NOT_FOUND':
                  friendly = 'No se encontró la sesión de caja.';
                default:
                  friendly = e.message;
              }
            } else if (SupabaseConfig.isTransientAuthRefreshError(e) ||
                SupabaseConfig.isAuthRefreshSchemaMismatchError(e)) {
              friendly = 'Error de autenticación transitorio. Verifica si la caja ya se cerró antes de reintentar.';
            } else {
              friendly = 'No se pudo cerrar la caja.';
            }
            throw Exception(friendly);
          }
        },
      ),
    );
  }

  Future<void> _openDetailedWizard({
    required Map<String, dynamic> session,
    required String businessId,
    required CashCloseInput input,
    required bool forceWithOpenTables,
  }) async {
    final sessionId = session['id'].toString();
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay usuario autenticado.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    final openedAt = DateTime.tryParse(
      session['opened_at']?.toString() ?? '',
    );

    final viewportSize = MediaQuery.of(context).size;
    final maxHeight = viewportSize.height * 0.90;
    final maxWidth = viewportSize.width < 760
        ? viewportSize.width - 32
        : 720.0;

    final didSign = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: maxHeight,
          ),
          child: CashCloseDetailedWizard(
            cashRegisterSessionId: sessionId,
            input: input,
            cashierName: input.cashierName,
            openedAt: openedAt,
            onCloseConfirmed: (snapshot) async {
              final repo = ref.read(cashierRepositoryProvider);
              await repo.recordDetailedCashClose(
                sessionId: sessionId,
                businessId: businessId,
                userId: userId,
                cashAmount: snapshot.cashAmount,
                cardAmount: snapshot.cardAmount,
                transferAmount: snapshot.transferAmount,
                denominations: snapshot.denominations,
                openingFloat: snapshot.openingFloat,
                supervisorNote: snapshot.supervisorNote,
              );
              final notes =
                  'Cierre detallado | Efectivo: ${snapshot.cashAmount} | '
                  'Tarjeta: ${snapshot.cardAmount} | '
                  'Transferencia: ${snapshot.transferAmount} | '
                  'Total reportado: ${snapshot.result.totalReported}';
              // Sprint Caja Pro Fase D — chequeo de varianza antes de
              // cerrar. Si supera el umbral del negocio, abre dialog
              // con nota obligatoria. Si el manager cancela, el cierre
              // se aborta antes del closeSession real.
              final closeResponse = await closeSessionWithVarianceCheck(
                context: context,
                ref: ref,
                businessId: businessId,
                sessionId: sessionId,
                endAmount: snapshot.cashAmount.toDouble(),
                expectedCash: input.expectedCash.toDouble(),
                notes: notes,
                forceWithOpenTables: forceWithOpenTables,
              );
              if (closeResponse == null) {
                throw const CashRegisterException(
                  errorCode: 'VARIANCE_CANCELLED',
                  message:
                      'Cierre cancelado por el usuario en alerta de varianza.',
                );
              }
              unawaited(
                repo
                    .markSessionCloseMode(
                      sessionId: sessionId,
                      mode: PosSettingsRepository.cashCloseDetailed,
                    )
                    .catchError((_) {}),
              );
            },
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (didSign == true) {
      try {
        await ref.read(cashierViewModelProvider).init();
      } catch (e) {
        if (!SupabaseConfig.isTransientAuthRefreshError(e) &&
            !SupabaseConfig.isAuthRefreshSchemaMismatchError(e)) {
          rethrow;
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Caja cerrada correctamente'),
          backgroundColor: MangoColors.successGreen,
        ),
      );
      GoRouter.of(context).replace(AppRoutes.cashier);
    }
  }

  Future<CashCloseInput> _buildCloseInput(Map<String, dynamic> session) async {
    final sessionId = session['id'].toString();
    final startAmount = (session['start_amount'] as num?)?.toInt() ?? 0;
    final repository = ref.read(cashierRepositoryProvider);
    final vm = ref.read(cashierViewModelProvider);

    // Toast-level precision: el RPC `fn_get_cash_session_summary` (migración
    // 20260514_0002) es la ÚNICA fuente de verdad para todos los esperados.
    // No re-calculamos por método en el cliente — eso provocó desfases
    // durante el ciclo de fixes del start_amount (sesión 4572afa5 mostró
    // +6,470 fantasma porque el cliente sumaba sin start_amount mientras
    // la DB ya lo incluía). Si el RPC devuelve un campo, lo respetamos
    // tal cual; si falta, asumimos 0.
    final summary = await repository.getSessionSummary(sessionId);

    int toInt(dynamic value) {
      if (value == null) return 0;
      if (value is int) return value;
      if (value is num) return value.round();
      return int.tryParse(value.toString()) ?? 0;
    }

    final expectedCash = toInt(summary['expected_cash']);
    final expectedCard = toInt(summary['expected_card']);
    final expectedTransfer = toInt(summary['expected_transfer']);
    final totalSales = toInt(summary['total_sales_all_methods']);
    final transactionCount = toInt(summary['transaction_count']);

    debugPrint(
      '[CashClose] session=$sessionId '
      'expected_cash=$expectedCash '
      'expected_card=$expectedCard '
      'expected_transfer=$expectedTransfer '
      'total_sales_all_methods=$totalSales '
      'transaction_count=$transactionCount '
      'start_amount=$startAmount',
    );

    final emptyInput = _emptyCloseInput();
    final hasRealData =
        expectedCash > 0 ||
        expectedCard > 0 ||
        expectedTransfer > 0 ||
        totalSales > 0;

    if (!hasRealData) return emptyInput;

    // Sprint Caja Pro — listado detallado de movimientos manuales
    // (deposit/withdrawal/expense) + razón resuelta. Se renderiza en
    // la hoja de cierre y en el ticket impreso para auditoría.
    final allTx = await repository.getSessionTransactions(sessionId);
    final reasonsCatalog =
        await repository.getCashTransactionReasons(businessId: vm.businessId ?? '');
    final reasonByCode = <String, String>{
      for (final r in reasonsCatalog) (r['code'] as String): (r['label'] as String),
    };
    final movements = allTx
        .where((tx) =>
            tx.type == 'deposit' ||
            tx.type == 'withdrawal' ||
            tx.type == 'expense')
        .map((tx) {
          // Resolver el label de la razón desde el catálogo cuando exista
          // un reason_code; si no, caer al texto libre (description).
          final code = tx.reasonCode;
          final label = (code != null && reasonByCode[code] != null)
              ? reasonByCode[code]
              : tx.description;
          return CashMovementEntry(
            type: tx.type,
            amount: tx.amount,
            reasonLabel: label,
            description: tx.description,
            createdAt: tx.createdAt,
          );
        })
        .toList(growable: false);

    return CashCloseInput(
      expectedCash: expectedCash,
      expectedCard: expectedCard,
      expectedTransfer: expectedTransfer,
      totalSales: totalSales,
      transactionCount: transactionCount > 0 ? transactionCount : 0,
      cashierName: _resolveCashierName(),
      businessName: vm.businessName.trim().isNotEmpty
          ? vm.businessName
          : emptyInput.businessName,
      startAmount: startAmount,
      // Sprint Caja Pro — desglose para el ticket de cierre.
      cashSalesNet: toInt(summary['cash_sales_net']),
      totalDeposits: toInt(summary['total_deposits']),
      totalWithdrawals: toInt(summary['total_withdrawals']),
      totalExpenses: toInt(summary['total_expenses']),
      movements: movements,
    );
  }

  /// Nombre y apellido del cajero para mostrar en cierres de caja y
  /// recibos impresos. NO usamos email como fallback: el cierre de caja
  /// queda físicamente impreso y exponer info sensible del personal
  /// (email corporativo) no corresponde. Si no hay nombre, mostramos
  /// 'Cajero' genérico.
  String _resolveCashierName() {
    final user = Supabase.instance.client.auth.currentUser;
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    final rawName =
        (metadata['full_name'] ??
                metadata['name'] ??
                metadata['display_name'] ??
                '')
            .toString();
    final trimmed = rawName.trim();
    return trimmed.isEmpty ? 'Cajero' : trimmed;
  }

  CashCloseInput _emptyCloseInput() {
    final vm = ref.read(cashierViewModelProvider);
    return CashCloseInput(
      expectedCash: 0,
      expectedCard: 0,
      expectedTransfer: 0,
      totalSales: 0,
      transactionCount: 0,
      cashierName: _resolveCashierName(),
      businessName: vm.businessName.trim().isNotEmpty
          ? vm.businessName
          : 'MangoPOS Restaurant',
    );
  }
}

// ===== HEADER SECTION =====
class _HeaderSection extends StatelessWidget {
  final CashierViewModel viewModel;
  final bool isOpen;

  const _HeaderSection({required this.viewModel, required this.isOpen});

  @override
  Widget build(BuildContext context) {
    final session = viewModel.lastSession;
    final registerName = viewModel.currentRegisterName.trim().isNotEmpty
        ? viewModel.currentRegisterName.trim()
        : 'Caja sin configurar';

    // Format last closed date
    String lastClosedText = 'Sin registros';
    if (session != null) {
      final dateStr = session['closed_at'] ?? session['opened_at'];
      if (dateStr != null) {
        try {
          final date = AppTime.tryParseServerToAst(dateStr);
          if (date == null) {
            throw const FormatException('invalid date');
          }
          lastClosedText = DateFormat('dd/MM/yyyy, HH:mm').format(date);
        } catch (e) {
          lastClosedText = 'Fecha no disponible';
        }
      }
    }

    final isMobile = context.isMobile;
    return Container(
      padding: EdgeInsets.all(isMobile ? 12 : context.wp(2.5)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                IconButton(
                  onPressed: () {
                    if (context.canPop()) {
                      context.pop();
                    } else {
                      context.go(AppRoutes.dashboard);
                    }
                  },
                  tooltip: 'Volver',
                  icon: const Icon(Icons.arrow_back),
                  style: IconButton.styleFrom(
                    backgroundColor: const Color(0xFFF5F5F5),
                    foregroundColor: MangoColors.darkGray,
                    minimumSize: Size(
                      isMobile ? 36 : 40,
                      isMobile ? 36 : 40,
                    ),
                  ),
                ),
                SizedBox(width: isMobile ? 8 : context.wp(1.2)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: isMobile ? 8 : context.iconSizeOf(10),
                            height: isMobile ? 8 : context.iconSizeOf(10),
                            decoration: BoxDecoration(
                              color: isOpen
                                  ? MangoColors.successGreen
                                  : Colors.grey[400],
                              shape: BoxShape.circle,
                              boxShadow: isOpen
                                  ? [
                                      BoxShadow(
                                        color: MangoColors.successGreen
                                            .withValues(alpha: 0.3),
                                        blurRadius: 8,
                                        spreadRadius: 2,
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                          SizedBox(width: isMobile ? 6 : context.wp(1.2)),
                          Flexible(
                            child: Text(
                              isOpen ? 'Caja Abierta' : 'Caja Cerrada',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: isOpen
                                    ? MangoColors.successGreen
                                    : Colors.grey[600],
                                fontSize: isMobile ? 11 : context.sp(13),
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: isMobile ? 4 : context.hp(0.8)),
                      Text(
                        registerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isMobile ? 17 : context.sp(28),
                          fontWeight: FontWeight.w800,
                          color: MangoColors.darkGray,
                          letterSpacing: -0.5,
                        ),
                      ),
                      SizedBox(height: isMobile ? 2 : context.hp(0.4)),
                      Text(
                        'Último cierre: $lastClosedText',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: isMobile ? 10.5 : context.sp(12),
                          color: Colors.grey[600],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (isMobile)
            IconButton(
              onPressed: () {
                context.go('/sales/by-zone');
              },
              tooltip: 'Ir a Mesas',
              icon: const Icon(
                Icons.table_restaurant_rounded,
                color: Colors.white,
              ),
              style: IconButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: () {
                context.go('/sales/by-zone');
              },
              icon: Icon(
                Icons.table_restaurant_rounded,
                color: Colors.white,
                size: context.iconSizeOf(20),
              ),
              label: Text(
                'Ir a Mesas',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: context.sp(14),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: MangoColors.primaryOrange,
                elevation: 0,
                padding: EdgeInsets.symmetric(
                  horizontal: context.wp(2.5),
                  vertical: context.hp(1.8),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                shadowColor: MangoColors.primaryOrange.withValues(alpha: 0.3),
              ),
            ),
        ],
      ),
    );
  }
}

// ===== STATS CARDS SECTION =====
class _StatsCardsSection extends StatelessWidget {
  final CashierViewModel viewModel;

  const _StatsCardsSection({required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final summary = viewModel.todaySummary;
    final income = summary['total_income'] ?? 0.0;
    final expenses = summary['total_expenses'] ?? 0.0;
    final balance = income - expenses;
    final transactions = summary['transaction_count'] ?? 0;
    final moneyFormat = NumberFormat('#,##0', 'es_DO');

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;

        if (isWide) {
          return Row(
            children: [
              Expanded(
                child: _StatCard(
                  title: 'Ingresos Hoy',
                  value: 'RD\$ ${moneyFormat.format(income)}',
                  icon: Icons.trending_up_rounded,
                  color: MangoColors.successGreen,
                ),
              ),
              SizedBox(width: context.wp(2)),
              Expanded(
                child: _StatCard(
                  title: 'Egresos Hoy',
                  value: 'RD\$ ${moneyFormat.format(expenses)}',
                  icon: Icons.trending_down_rounded,
                  color: Colors.red[600]!,
                ),
              ),
              SizedBox(width: context.wp(2)),
              Expanded(
                child: _StatCard(
                  title: 'Balance',
                  value: 'RD\$ ${moneyFormat.format(balance)}',
                  icon: Icons.account_balance_wallet_rounded,
                  color: MangoColors.primaryOrange,
                ),
              ),
              SizedBox(width: context.wp(2)),
              Expanded(
                child: _StatCard(
                  title: 'Transacciones',
                  value: '$transactions',
                  icon: Icons.receipt_long_rounded,
                  color: MangoColors.primaryOrange,
                ),
              ),
            ],
          );
        } else {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      title: 'Ingresos Hoy',
                      value: 'RD\$ ${moneyFormat.format(income)}',
                      icon: Icons.trending_up_rounded,
                      color: MangoColors.successGreen,
                    ),
                  ),
                  SizedBox(width: context.wp(2)),
                  Expanded(
                    child: _StatCard(
                      title: 'Egresos Hoy',
                      value: 'RD\$ ${moneyFormat.format(expenses)}',
                      icon: Icons.trending_down_rounded,
                      color: Colors.red[600]!,
                    ),
                  ),
                ],
              ),
              SizedBox(height: context.hp(2)),
              Row(
                children: [
                  Expanded(
                    child: _StatCard(
                      title: 'Balance',
                      value: 'RD\$ ${moneyFormat.format(balance)}',
                      icon: Icons.account_balance_wallet_rounded,
                      color: MangoColors.primaryOrange,
                    ),
                  ),
                  SizedBox(width: context.wp(2)),
                  Expanded(
                    child: _StatCard(
                      title: 'Transacciones',
                      value: '$transactions',
                      icon: Icons.receipt_long_rounded,
                      color: Colors.blue[600]!,
                    ),
                  ),
                ],
              ),
            ],
          );
        }
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = context.isMobile;
    return Container(
      padding: EdgeInsets.all(isMobile ? 10 : context.wp(2.2)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.1), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(isMobile ? 6 : context.wp(0.8)),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: isMobile ? 16 : context.iconSizeOf(20),
                ),
              ),
              SizedBox(width: isMobile ? 6 : context.wp(1.2)),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isMobile ? 10.5 : context.sp(12),
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: isMobile ? 6 : context.hp(1.2)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: isMobile ? 15 : context.sp(20),
                fontWeight: FontWeight.w800,
                color: color,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===== ACTION CARDS SECTION =====
class _ActionCardsSection extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onOpenCash;
  final VoidCallback onCloseCash;
  final bool canViewHistory;
  final bool canViewClosures;
  final bool canViewMovements;

  const _ActionCardsSection({
    required this.isOpen,
    required this.onOpenCash,
    required this.onCloseCash,
    this.canViewHistory = true,
    this.canViewClosures = true,
    this.canViewMovements = true,
  });

  @override
  Widget build(BuildContext context) {
    // Core actions always visible
    final coreCards = <Widget>[
      _ActionCard(
        icon: Icons.lock_open_rounded,
        iconColor: MangoColors.successGreen,
        iconBgColor: const Color(0xFFE8F5E9),
        title: 'Apertura de Caja',
        subtitle: 'Iniciar turno con monto inicial',
        buttonText: 'Aperturar',
        buttonColor: MangoColors.successGreen,
        enabled: !isOpen,
        onPressed: onOpenCash,
      ),
      _ActionCard(
        icon: Icons.lock_rounded,
        iconColor: Colors.red[600]!,
        iconBgColor: const Color(0xFFFFEBEE),
        title: 'Cierre de Caja',
        subtitle: 'Finalizar turno y cuadrar',
        buttonText: 'Cerrar',
        buttonColor: Colors.red[600]!,
        enabled: isOpen,
        onPressed: onCloseCash,
      ),
    ];

    // Conditional cards based on permissions
    if (canViewMovements) {
      coreCards.add(
        _ActionCard(
          icon: Icons.sync_alt_rounded,
          iconColor: const Color(0xFF7C3AED),
          iconBgColor: const Color(0xFFF3E8FF),
          title: 'Ingresos y Egresos',
          subtitle: 'Registrar depósitos, retiros y gastos',
          buttonText: 'Registrar',
          buttonColor: const Color(0xFF7C3AED),
          enabled: isOpen,
          onPressed: () => context.go(AppRoutes.cashierIncomeExpense),
        ),
      );
    }
    if (canViewHistory) {
      coreCards.add(
        _ActionCard(
          icon: Icons.history_rounded,
          iconColor: Colors.blue[600]!,
          iconBgColor: const Color(0xFFE3F2FD),
          title: 'Historial de venta',
          subtitle: 'Revisar ventas pasadas',
          buttonText: 'Ver',
          buttonColor: Colors.blue[600]!,
          enabled: true,
          onPressed: () => context.go(AppRoutes.cashierHistory),
        ),
      );
    }
    if (canViewClosures) {
      coreCards.add(
        _ActionCard(
          icon: Icons.settings_rounded,
          iconColor: MangoColors.primaryOrange,
          iconBgColor: const Color(0xFFFFF3E0),
          title: 'Gestión de Cierres',
          subtitle: 'Revisar y anotar cierres',
          buttonText: 'Gestionar',
          buttonColor: MangoColors.primaryOrange,
          enabled: true,
          onPressed: () => context.go(AppRoutes.cashierClosures),
        ),
      );
      // 2026-05-13: removida la card "Salud de cajas" de la app POS.
      // El dashboard NOC cross-tenant (con force-close, semáforo,
      // alertas) se traslada a mango_administrador. Ver PRD-12.
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;
        final gap = SizedBox(
          width: isWide ? context.wp(2) : 0,
          height: isWide ? 0 : context.hp(2),
        );

        if (isWide) {
          // Lay out in rows of 2-3
          final rows = <Widget>[];
          for (var i = 0; i < coreCards.length; i += 3) {
            final end =
                (i + 3 > coreCards.length) ? coreCards.length : i + 3;
            final rowCards = coreCards.sublist(i, end);
            rows.add(
              Row(
                children: [
                  for (var j = 0; j < rowCards.length; j++) ...[
                    if (j > 0) SizedBox(width: context.wp(2)),
                    Expanded(child: rowCards[j]),
                  ],
                  // Fill remaining space if row has < 3 cards
                  if (rowCards.length < 3)
                    for (var k = 0; k < 3 - rowCards.length; k++) ...[
                      SizedBox(width: context.wp(2)),
                      const Expanded(child: SizedBox.shrink()),
                    ],
                ],
              ),
            );
          }
          return Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) SizedBox(height: context.hp(2)),
                rows[i],
              ],
            ],
          );
        }

        // Narrow: stack vertically
        return Column(
          children: [
            for (var i = 0; i < coreCards.length; i++) ...[
              if (i > 0) gap,
              coreCards[i],
            ],
          ],
        );
      },
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBgColor;
  final String title;
  final String subtitle;
  final String buttonText;
  final Color buttonColor;
  final bool enabled;
  final VoidCallback onPressed;

  const _ActionCard({
    required this.icon,
    required this.iconColor,
    required this.iconBgColor,
    required this.title,
    required this.subtitle,
    required this.buttonText,
    required this.buttonColor,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = context.isMobile;
    return Container(
      padding: EdgeInsets.all(isMobile ? 12 : context.wp(2.2)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: enabled
              ? iconColor.withValues(alpha: 0.15)
              : Colors.grey.withValues(alpha: 0.15),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(isMobile ? 8 : context.wp(1.8)),
                decoration: BoxDecoration(
                  color: enabled ? iconBgColor : Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: enabled ? iconColor : Colors.grey[400],
                  size: isMobile ? 22 : context.iconSizeOf(32),
                ),
              ),
              SizedBox(width: isMobile ? 10 : context.wp(2)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isMobile ? 13 : context.sp(15),
                        fontWeight: FontWeight.w700,
                        color: enabled
                            ? MangoColors.darkGray
                            : Colors.grey[500],
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: isMobile ? 2 : context.hp(0.4)),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: isMobile ? 10.5 : context.sp(11),
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: isMobile ? 10 : context.hp(1.5)),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: enabled ? onPressed : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: buttonColor,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey[300],
                disabledForegroundColor: Colors.grey[500],
                elevation: 0,
                padding: EdgeInsets.symmetric(
                  vertical: isMobile ? 10 : context.hp(1.4),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                buttonText,
                style: TextStyle(
                  fontSize: isMobile ? 12 : context.sp(13),
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===== BLIND CLOSE INFO BANNER =====
class _BlindCloseInfoBanner extends StatelessWidget {
  final bool isOpen;
  const _BlindCloseInfoBanner({required this.isOpen});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: context.hp(2.5)),
      padding: EdgeInsets.all(context.wp(2.5)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF2563EB).withValues(alpha: 0.15),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(context.wp(1.5)),
            decoration: BoxDecoration(
              color: const Color(0xFF2563EB).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.visibility_off_rounded,
              color: const Color(0xFF2563EB),
              size: context.iconSizeOf(28),
            ),
          ),
          SizedBox(width: context.wp(2)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cierre de caja a ciegas',
                  style: TextStyle(
                    fontSize: context.sp(15),
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
                SizedBox(height: context.hp(0.5)),
                Text(
                  isOpen
                      ? 'Tu caja esta abierta. Al cerrar, contaras el efectivo, tarjetas y transferencias sin ver los montos esperados. Esto asegura un arqueo limpio y transparente.'
                      : 'Tu caja esta cerrada. Abre la caja para iniciar tu turno. Al cierre, realizaras un conteo a ciegas para garantizar la transparencia del arqueo.',
                  style: TextStyle(
                    fontSize: context.sp(12),
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                  ),
                ),
                SizedBox(height: context.hp(1)),
                Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: context.iconSizeOf(14),
                      color: Colors.grey[500],
                    ),
                    SizedBox(width: context.wp(0.5)),
                    Expanded(
                      child: Text(
                        'Los totales de ventas solo son visibles para administradores y supervisores.',
                        style: TextStyle(
                          fontSize: context.sp(11),
                          color: Colors.grey[500],
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ===== RECENT MOVEMENTS SECTION =====
class _RecentMovementsSection extends StatelessWidget {
  final CashierViewModel viewModel;

  const _RecentMovementsSection({required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final movements = viewModel.recentMovements;
    final isMobile = context.isMobile;

    return Container(
      padding: EdgeInsets.all(isMobile ? 12 : context.wp(2.5)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  isMobile ? 'Movimientos' : 'Movimientos Recientes',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isMobile ? 14 : context.sp(18),
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              if (!isMobile)
                Row(
                  children: [
                    _FilterChip(
                      label: 'Ingreso',
                      color: MangoColors.successGreen,
                    ),
                    SizedBox(width: context.wp(1)),
                    _FilterChip(label: 'Egreso', color: Colors.red[600]!),
                  ],
                ),
            ],
          ),
          SizedBox(height: isMobile ? 12 : context.hp(2)),

          if (movements.isEmpty)
            Center(
              child: Padding(
                padding: EdgeInsets.all(context.hp(4)),
                child: Column(
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      size: context.iconSizeOf(64),
                      color: Colors.grey[300],
                    ),
                    SizedBox(height: context.hp(2)),
                    Text(
                      'No hay movimientos recientes',
                      style: TextStyle(
                        fontSize: context.sp(14),
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: movements.length,
              separatorBuilder: (_, index) =>
                  Divider(height: context.hp(2.5), color: Colors.grey[200]),
              itemBuilder: (context, index) {
                final movement = movements[index];
                return _MovementItem(movement: movement);
              },
            ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final Color color;

  const _FilterChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.wp(1.5),
        vertical: context.hp(0.6),
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: context.iconSizeOf(8),
            height: context.iconSizeOf(8),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          SizedBox(width: context.wp(0.7)),
          Text(
            label,
            style: TextStyle(
              fontSize: context.sp(11),
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _MovementItem extends StatelessWidget {
  final Map<String, dynamic> movement;

  const _MovementItem({required this.movement});

  @override
  Widget build(BuildContext context) {
    final isIncome = movement['type'] == 'income';
    final description = movement['description'] ?? 'Sin descripción';
    final amount = movement['amount'] ?? 0.0;
    final movementAt = AppTime.tryParseServerToAst(movement['created_at']);
    final time = movementAt != null
        ? DateFormat('HH:mm').format(movementAt)
        : '--:--';

    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(context.wp(1.2)),
          decoration: BoxDecoration(
            color: isIncome
                ? MangoColors.successGreen.withValues(alpha: 0.12)
                : Colors.red.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(
            isIncome
                ? Icons.arrow_downward_rounded
                : Icons.arrow_upward_rounded,
            color: isIncome ? MangoColors.successGreen : Colors.red[600],
            size: context.iconSizeOf(20),
          ),
        ),
        SizedBox(width: context.wp(1.8)),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                description,
                style: TextStyle(
                  fontSize: context.sp(14),
                  fontWeight: FontWeight.w700,
                  color: MangoColors.darkGray,
                  letterSpacing: -0.1,
                ),
              ),
              SizedBox(height: context.hp(0.3)),
              Text(
                time,
                style: TextStyle(
                  fontSize: context.sp(11),
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Text(
          '${isIncome ? '+' : '-'}RD\$ ${NumberFormat('#,##0').format(amount)}',
          style: TextStyle(
            fontSize: context.sp(15),
            fontWeight: FontWeight.w800,
            color: isIncome ? MangoColors.successGreen : Colors.red[600],
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }
}
