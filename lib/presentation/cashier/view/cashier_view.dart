import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/presentation/cashier/state/blind_cash_close_models.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/utils/responsive_utils.dart';
import 'package:mangopos/presentation/cashier/widgets/blind_cash_close_dialog.dart';
import 'package:mangopos/presentation/cashier/widgets/open_cash_dialog.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

class CashierView extends ConsumerStatefulWidget {
  const CashierView({super.key});

  @override
  ConsumerState<CashierView> createState() => _CashierViewState();
}

class _CashierViewState extends ConsumerState<CashierView> {
  Timer? _refreshTimer;
  String? _lastBusinessId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(cashierViewModelProvider).init();
    });

    // Auto-refresh every 30 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        ref.read(cashierViewModelProvider).init();
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _handleRefresh() async {
    await ref.read(cashierViewModelProvider).init();
  }

  @override
  Widget build(BuildContext context) {
    final appSession = ref.watch(sessionProvider);
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
      return const Scaffold(
        backgroundColor: Color(0xFFF2F2F2),
        body: Center(
          child: CircularProgressIndicator(color: MangoColors.primaryOrange),
        ),
      );
    }

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

              // Stats Cards
              _StatsCardsSection(viewModel: vm),
              SizedBox(height: context.hp(2.5)),

              // Action Cards (2x2 grid)
              _ActionCardsSection(
                isOpen: isOpen,
                onOpenCash: () => _showOpenCashDialog(context),
                onCloseCash: _showCloseCashDialog,
              ),
              SizedBox(height: context.hp(2.5)),

              // Recent Movements
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

    final pending = await ref
        .read(cashierViewModelProvider)
        .refreshPendingTablesCount();
    if (!mounted) return;

    var forceWithOpenTables = false;
    if (pending > 0) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Mesas abiertas'),
          content: Text(
            'Hay $pending mesa(s) con orden abierta. ¿Deseas cerrar la caja de todas formas?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
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
      input = await _buildCloseInput(session['id'].toString());
    } catch (_) {
      input = _fallbackInput();
    } finally {
      if (rootNavigator.canPop()) {
        rootNavigator.pop();
      }
    }

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => BlindCashCloseDialog(
        sessionId: session['id'].toString(),
        input: input,
        onCloseConfirmed: (result) async {
          final notes =
              'Cierre ciego | Efectivo: ${result.totalCounted} | Tarjetas: ${result.numericCard} | '
              'Transferencias: ${result.numericTransfer} | Total reportado: ${result.totalReported} | '
              'Diferencia: ${result.difference}';

          try {
            await ref
                .read(cashierRepositoryProvider)
                .closeSession(
                  sessionId: session['id'].toString(),
                  endAmount: result.totalCounted.toDouble(),
                  notes: notes,
                  forceWithOpenTables: forceWithOpenTables,
                );
            await ref.read(cashierViewModelProvider).init();
            if (!mounted) return;
            GoRouter.of(context).replace(AppRoutes.cashier);
          } catch (e) {
            if (!mounted) return;
            final msg = e.toString();
            final friendly = msg.contains('OPEN_TABLES_EXIST')
                ? 'Todavía hay mesas abiertas. Si deseas cerrar por cambio de turno, confirma el cierre con mesas abiertas.'
                : 'No se pudo cerrar la caja: $e';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(friendly), backgroundColor: Colors.red),
            );
          }
        },
      ),
    );
  }

  Future<CashCloseInput> _buildCloseInput(String sessionId) async {
    final repository = ref.read(cashierRepositoryProvider);
    final vm = ref.read(cashierViewModelProvider);

    final summary = await repository.getSessionSummary(sessionId);

    int toInt(dynamic value) {
      if (value == null) return 0;
      if (value is int) return value;
      if (value is num) return value.round();
      return int.tryParse(value.toString()) ?? 0;
    }

    int expectedCash = toInt(summary['expected_cash']);
    if (expectedCash <= 0) {
      expectedCash = toInt(summary['expected_amount']);
    }
    var expectedCard = toInt(summary['expected_card']);
    var expectedTransfer = toInt(summary['expected_transfer']);
    var totalSales = toInt(summary['total_sales_all_methods']);
    var transactionCount = toInt(summary['transaction_count']);

    if (expectedCard <= 0 && expectedTransfer <= 0 && totalSales <= 0) {
      final payments = await repository.getSessionPaymentsDetailed(sessionId);
      int cardPayments = 0;
      int transferPayments = 0;
      int totalPaid = 0;

      for (final payment in payments) {
        final amount = toInt(payment['amount']);
        totalPaid += amount;
        final code = (payment['method_code'] ?? '').toString().toLowerCase();
        final methodName = (payment['method_name'] ?? '')
            .toString()
            .toLowerCase();

        if (code == 'card' || methodName.contains('tarjet')) {
          cardPayments += amount;
        } else if (code == 'transfer' || methodName.contains('transfer')) {
          transferPayments += amount;
        }
      }

      expectedCard = cardPayments;
      expectedTransfer = transferPayments;
      if (totalSales <= 0) totalSales = totalPaid;
      if (transactionCount <= 0) transactionCount = payments.length;
    }

    final fallback = _fallbackInput();
    final hasRealData =
        expectedCash > 0 ||
        expectedCard > 0 ||
        expectedTransfer > 0 ||
        totalSales > 0;

    if (!hasRealData) return fallback;

    return CashCloseInput(
      expectedCash: expectedCash,
      expectedCard: expectedCard,
      expectedTransfer: expectedTransfer,
      totalSales: totalSales,
      transactionCount: transactionCount > 0
          ? transactionCount
          : fallback.transactionCount,
      cashierName: _resolveCashierName(),
      businessName: vm.businessName.trim().isNotEmpty
          ? vm.businessName
          : fallback.businessName,
    );
  }

  String _resolveCashierName() {
    final user = Supabase.instance.client.auth.currentUser;
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    final rawName =
        (metadata['full_name'] ??
                metadata['name'] ??
                metadata['display_name'] ??
                user?.email ??
                'Admin')
            .toString();
    return rawName.trim().isEmpty ? 'Admin' : rawName.trim();
  }

  CashCloseInput _fallbackInput() {
    final vm = ref.read(cashierViewModelProvider);
    return CashCloseInput(
      expectedCash: 28500,
      expectedCard: 12500,
      expectedTransfer: 4200,
      totalSales: 45200,
      transactionCount: 28,
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
          final date = DateTime.parse(dateStr);
          lastClosedText = DateFormat('dd/MM/yyyy, HH:mm').format(date);
        } catch (e) {
          lastClosedText = 'Fecha no disponible';
        }
      }
    }

    return Container(
      padding: EdgeInsets.all(context.wp(2.5)),
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
          Row(
            children: [
              IconButton(
                onPressed: () => context.go(AppRoutes.dashboard),
                tooltip: 'Volver',
                icon: const Icon(Icons.arrow_back),
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFF5F5F5),
                  foregroundColor: MangoColors.darkGray,
                ),
              ),
              SizedBox(width: context.wp(1.2)),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: context.iconSizeOf(10),
                        height: context.iconSizeOf(10),
                        decoration: BoxDecoration(
                          color: isOpen
                              ? MangoColors.successGreen
                              : Colors.grey[400],
                          shape: BoxShape.circle,
                          boxShadow: isOpen
                              ? [
                                  BoxShadow(
                                    color: MangoColors.successGreen.withValues(
                                      alpha: 0.3,
                                    ),
                                    blurRadius: 8,
                                    spreadRadius: 2,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                      SizedBox(width: context.wp(1.2)),
                      Text(
                        isOpen ? 'Caja Abierta' : 'Caja Cerrada',
                        style: TextStyle(
                          color: isOpen
                              ? MangoColors.successGreen
                              : Colors.grey[600],
                          fontSize: context.sp(13),
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: context.hp(0.8)),
                  Text(
                    registerName,
                    style: TextStyle(
                      fontSize: context.sp(28),
                      fontWeight: FontWeight.w800,
                      color: MangoColors.darkGray,
                      letterSpacing: -0.5,
                    ),
                  ),
                  SizedBox(height: context.hp(0.4)),
                  Text(
                    'Último cierre: $lastClosedText',
                    style: TextStyle(
                      fontSize: context.sp(12),
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
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
                  color: Colors.blue[600]!,
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
    return Container(
      padding: EdgeInsets.all(context.wp(2.2)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
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
                padding: EdgeInsets.all(context.wp(0.8)),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: context.iconSizeOf(20)),
              ),
              SizedBox(width: context.wp(1.2)),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: context.sp(12),
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: context.hp(1.2)),
          Text(
            value,
            style: TextStyle(
              fontSize: context.sp(20),
              fontWeight: FontWeight.w800,
              color: color,
              letterSpacing: -0.3,
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

  const _ActionCardsSection({
    required this.isOpen,
    required this.onOpenCash,
    required this.onCloseCash,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;

        if (isWide) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _ActionCard(
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
                  ),
                  SizedBox(width: context.wp(2)),
                  Expanded(
                    child: _ActionCard(
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
                  ),
                ],
              ),
              SizedBox(height: context.hp(2)),
              Row(
                children: [
                  Expanded(
                    child: _ActionCard(
                      icon: Icons.sync_alt_rounded,
                      iconColor: const Color(0xFF7C3AED),
                      iconBgColor: const Color(0xFFF3E8FF),
                      title: 'Ingresos y Egresos',
                      subtitle: 'Registrar depósitos, retiros y gastos',
                      buttonText: 'Registrar',
                      buttonColor: const Color(0xFF7C3AED),
                      enabled: isOpen,
                      onPressed: () =>
                          context.go(AppRoutes.cashierIncomeExpense),
                    ),
                  ),
                  SizedBox(width: context.wp(2)),
                  Expanded(
                    child: _ActionCard(
                      icon: Icons.history_rounded,
                      iconColor: Colors.blue[600]!,
                      iconBgColor: const Color(0xFFE3F2FD),
                      title: 'Historial de Caja',
                      subtitle: 'Ver movimientos anteriores',
                      buttonText: 'Ver',
                      buttonColor: Colors.blue[600]!,
                      enabled: true,
                      onPressed: () => context.go(AppRoutes.cashierHistory),
                    ),
                  ),
                  SizedBox(width: context.wp(2)),
                  Expanded(
                    child: _ActionCard(
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
                  ),
                ],
              ),
            ],
          );
        } else {
          return Column(
            children: [
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
              SizedBox(height: context.hp(2)),
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
              SizedBox(height: context.hp(2)),
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
              SizedBox(height: context.hp(2)),
              _ActionCard(
                icon: Icons.history_rounded,
                iconColor: Colors.blue[600]!,
                iconBgColor: const Color(0xFFE3F2FD),
                title: 'Historial de Caja',
                subtitle: 'Ver movimientos anteriores',
                buttonText: 'Ver',
                buttonColor: Colors.blue[600]!,
                enabled: true,
                onPressed: () => context.go(AppRoutes.cashierHistory),
              ),
              SizedBox(height: context.hp(2)),
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
            ],
          );
        }
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
    return Container(
      padding: EdgeInsets.all(context.wp(2.2)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
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
                padding: EdgeInsets.all(context.wp(1.8)),
                decoration: BoxDecoration(
                  color: enabled ? iconBgColor : Colors.grey[100],
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  icon,
                  color: enabled ? iconColor : Colors.grey[400],
                  size: context.iconSizeOf(32),
                ),
              ),
              SizedBox(width: context.wp(2)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: context.sp(15),
                        fontWeight: FontWeight.w700,
                        color: enabled
                            ? MangoColors.darkGray
                            : Colors.grey[500],
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: context.hp(0.4)),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: context.sp(11),
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: context.hp(1.5)),
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
                padding: EdgeInsets.symmetric(vertical: context.hp(1.4)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                buttonText,
                style: TextStyle(
                  fontSize: context.sp(13),
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

// ===== RECENT MOVEMENTS SECTION =====
class _RecentMovementsSection extends StatelessWidget {
  final CashierViewModel viewModel;

  const _RecentMovementsSection({required this.viewModel});

  @override
  Widget build(BuildContext context) {
    final movements = viewModel.recentMovements;

    return Container(
      padding: EdgeInsets.all(context.wp(2.5)),
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
              Text(
                'Movimientos Recientes',
                style: TextStyle(
                  fontSize: context.sp(18),
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                  letterSpacing: -0.3,
                ),
              ),
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
          SizedBox(height: context.hp(2)),

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
        borderRadius: BorderRadius.circular(20),
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
    final time = movement['created_at'] != null
        ? DateFormat('HH:mm').format(DateTime.parse(movement['created_at']))
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
