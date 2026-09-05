import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/app/widgets/date_range_modal.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/pos_settings_repository.dart';
import 'package:mangopos/data/utils/payment_amount_utils.dart';
import 'package:mangopos/presentation/cashier/widgets/annulment_process_dialog.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/presentation/sales/viewmodel/sales_viewmodel.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/services/session/session_controller.dart';
import 'package:mangopos/presentation/sales/widgets/pin_verification_modal.dart';
import 'package:mangopos/presentation/cashier/utils/invoice_reprint.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_colors.dart';
import 'package:mangopos/core/utils/friendly_error.dart';

String _formatQty(double qty) {
  if ((qty - qty.roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(0);
  }
  if ((qty * 10 - (qty * 10).roundToDouble()).abs() < 0.001) {
    return qty.toStringAsFixed(1);
  }
  return qty.toStringAsFixed(2);
}

/// Extrae el porcentaje numérico de una label tipo "ITBIS (18%)" /
/// "Propina Ley (10%)". Devuelve null si la label no encaja con el patrón
/// — el caller debe caer al path heurístico de absorción de gap.
final RegExp _rateInLabelRegex = RegExp(r'\((\d+(?:[.,]\d+)?)\s*%\)');

double? _parseRatePercent(({String label, double amount}) line) {
  final match = _rateInLabelRegex.firstMatch(line.label);
  if (match == null) return null;
  final raw = match.group(1)?.replaceAll(',', '.') ?? '';
  return double.tryParse(raw);
}

class SalesHistoryView extends ConsumerStatefulWidget {
  const SalesHistoryView({super.key});

  @override
  ConsumerState<SalesHistoryView> createState() => _SalesHistoryViewState();
}

class _SalesHistoryViewState extends ConsumerState<SalesHistoryView> {
  _SalesHistoryData? _data;
  bool _loading = false;
  String? _error;

  int _currentPage = 1;
  static const int _pageSize = 15;
  String? _searchQuery;
  DateTime? _fromDate;
  DateTime? _toDate;

  final _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final businessId = ref.read(sessionProvider).activeBusinessId;
    if (businessId == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final repository = ref.read(cashierRepositoryProvider);
      final result = await repository.getGlobalSalesHistoryPaged(
        businessId: businessId,
        page: _currentPage,
        pageSize: _pageSize,
        from: _fromDate,
        to: _toDate,
        searchTerm: _searchQuery,
      );

      if (mounted) {
        setState(() {
          _data = _SalesHistoryData(
            payments: result.payments,
            totalCount: result.totalCount,
          );
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = FriendlyError.from(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _reload() => _load();

  void _changePage(int page) {
    if (_currentPage == page) return;
    _currentPage = page;
    _load();
  }

  Future<void> _selectDateRange() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: SizedBox(
          width: 400,
          child: DateRangeModal(
            initialFrom: _fromDate,
            initialTo: _toDate,
            onApply: (from, to) {
              setState(() {
                _fromDate = DateTime(from.year, from.month, from.day);
                _toDate = DateTime(to.year, to.month, to.day, 23, 59, 59);
                _currentPage = 1;
              });
              _load();
            },
            onClear: () {
              setState(() {
                _fromDate = null;
                _toDate = null;
                _currentPage = 1;
              });
              _load();
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Historial de venta'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.cashier),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _data == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null && _data == null) {
      return _CashierInfoState(
        icon: Icons.error_outline,
        title: 'No se pudo cargar el historial',
        subtitle: _error!,
      );
    }

    final data = _data;
    if (data == null || (data.payments.isEmpty && _currentPage == 1 && _searchQuery == null && _fromDate == null)) {
      return const _CashierInfoState(
        icon: Icons.receipt_long_outlined,
        title: 'No hay ventas registradas',
        subtitle: 'Procesa ventas para ver movimientos en el historial.',
      );
    }

    final currency = NumberFormat.currency(
      symbol: 'RD\$',
      decimalDigits: 2,
    );

    final isMobile = ResponsiveHelper.isMobile(context);
    final outerPad = isMobile ? 12.0 : 24.0;
    return Padding(
      padding: EdgeInsets.all(outerPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          SizedBox(height: isMobile ? 4 : 8),
          // Mobile: search arriba, filtro de fecha abajo. Desktop: lado a lado.
          if (isMobile) ...[
            TextField(
              controller: _searchController,
              onChanged: (val) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 400), () {
                  setState(() {
                    _searchQuery = val.trim().isEmpty ? null : val.trim();
                    _currentPage = 1;
                  });
                  _load();
                });
              },
              decoration: InputDecoration(
                hintText: 'Buscar comprobante o cliente',
                hintStyle: const TextStyle(fontSize: 13),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          _debounce?.cancel();
                          setState(() {
                            _searchQuery = null;
                            _currentPage = 1;
                          });
                          _load();
                        },
                      )
                    : null,
                isDense: true,
                filled: true,
                fillColor: MangoColors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      const BorderSide(color: MangoColors.cardBorder),
                ),
              ),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: _selectDateRange,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: MangoColors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: MangoColors.cardBorder),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_outlined, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _fromDate == null || _toDate == null
                            ? 'Filtrar por fecha'
                            : '${DateFormat('dd MMM.').format(_fromDate!)} → ${DateFormat('dd MMM.').format(_toDate!)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (_fromDate != null)
                      InkWell(
                        onTap: () {
                          setState(() {
                            _fromDate = null;
                            _toDate = null;
                            _currentPage = 1;
                          });
                          _load();
                        },
                        child: const Icon(Icons.close, size: 16),
                      ),
                  ],
                ),
              ),
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (val) {
                      _debounce?.cancel();
                      _debounce = Timer(const Duration(milliseconds: 400), () {
                        setState(() {
                          _searchQuery = val.trim().isEmpty ? null : val.trim();
                          _currentPage = 1;
                        });
                        _load();
                      });
                    },
                    decoration: InputDecoration(
                      hintText: 'Buscar por comprobante o cliente',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _searchController.clear();
                                _debounce?.cancel();
                                setState(() {
                                  _searchQuery = null;
                                  _currentPage = 1;
                                });
                                _load();
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: MangoColors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: MangoColors.cardBorder,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                InkWell(
                  onTap: _selectDateRange,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: MangoColors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: MangoColors.cardBorder),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today_outlined, size: 18),
                        const SizedBox(width: 12),
                        Text(
                          _fromDate == null || _toDate == null
                              ? 'Filtrar por fecha'
                              : '${DateFormat('dd MMM.').format(_fromDate!)} → ${DateFormat('dd MMM.').format(_toDate!)}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (_fromDate != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: InkWell(
                              onTap: () {
                                setState(() {
                                  _fromDate = null;
                                  _toDate = null;
                                  _currentPage = 1;
                                });
                                _load();
                              },
                              child: const Icon(Icons.close, size: 16),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          SizedBox(height: isMobile ? 12 : 24),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: MangoColors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: MangoColors.cardBorder),
              ),
              child: Column(
                children: [
                  // Header de tabla solo en desktop — en móvil cada
                  // venta se renderiza como card.
                  if (!isMobile) ...[
                    _buildTableHeader(),
                    const Divider(height: 1),
                  ],
                  Expanded(
                    child: data.payments.isEmpty
                        ? Center(
                            child: Text(
                              _searchQuery != null || _fromDate != null
                                  ? 'No se encontraron resultados para los filtros aplicados.'
                                  : 'No hay ventas registradas.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: isMobile ? 13 : 14,
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: EdgeInsets.symmetric(
                              vertical: isMobile ? 6 : 0,
                            ),
                            itemCount: data.payments.length,
                            separatorBuilder: (_, _) => Divider(
                              height: isMobile ? 6 : 1,
                              color: isMobile
                                  ? Colors.transparent
                                  : MangoColors.cardBorder,
                            ),
                            itemBuilder: (context, index) => isMobile
                                ? _PaymentMobileCard(
                                    payment: data.payments[index],
                                    currency: currency,
                                    onRefresh: _reload,
                                  )
                                : _PaymentTableRow(
                                    payment: data.payments[index],
                                    currency: currency,
                                    onRefresh: _reload,
                                  ),
                          ),
                  ),
                  _buildTableFooter(data.totalCount),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      color: MangoColors.sidebarBg.withValues(alpha: 0.5),
      child: const Row(
        children: [
          Expanded(flex: 2, child: _HeaderText('Fecha')),
          Expanded(flex: 2, child: _HeaderText('Comprobante')),
          Expanded(flex: 2, child: _HeaderText('Mesero')),
          Expanded(flex: 2, child: _HeaderText('Cliente')),
          Expanded(flex: 2, child: _HeaderText('N° de documento')),
          Expanded(flex: 2, child: _HeaderText('Total')),
          Expanded(flex: 2, child: _HeaderText('Forma de pago')),
          SizedBox(
            width: 160,
            child: _HeaderText('Opciones', textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }

  Widget _buildTableFooter(int totalCount) {
    if (totalCount <= _pageSize) return const SizedBox.shrink();

    final totalPages = (totalCount / _pageSize).ceil();
    final start = (_currentPage - 1) * _pageSize + 1;
    final end = (_currentPage * _pageSize) > totalCount
        ? totalCount
        : (_currentPage * _pageSize);
    final isMobile = ResponsiveHelper.isMobile(context);

    return Padding(
      padding: EdgeInsets.all(isMobile ? 8 : 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              isMobile
                  ? '$start-$end de $totalCount'
                  : 'Mostrando $start - $end de $totalCount ventas',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: MangoColors.muted,
                fontSize: isMobile ? 11 : 13,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.first_page),
            onPressed: _currentPage > 1 ? () => _changePage(1) : null,
            visualDensity:
                isMobile ? VisualDensity.compact : VisualDensity.standard,
            iconSize: isMobile ? 18 : 24,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _currentPage > 1
                ? () => _changePage(_currentPage - 1)
                : null,
            visualDensity:
                isMobile ? VisualDensity.compact : VisualDensity.standard,
            iconSize: isMobile ? 18 : 24,
          ),
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 8 : 12,
              vertical: isMobile ? 4 : 6,
            ),
            decoration: BoxDecoration(
              color: MangoColors.primaryOrange,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '$_currentPage',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: isMobile ? 12 : 14,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _currentPage < totalPages
                ? () => _changePage(_currentPage + 1)
                : null,
            visualDensity:
                isMobile ? VisualDensity.compact : VisualDensity.standard,
            iconSize: isMobile ? 18 : 24,
          ),
          IconButton(
            icon: const Icon(Icons.last_page),
            onPressed: _currentPage < totalPages
                ? () => _changePage(totalPages)
                : null,
            visualDensity:
                isMobile ? VisualDensity.compact : VisualDensity.standard,
            iconSize: isMobile ? 18 : 24,
          ),
        ],
      ),
    );
  }
}

class _HeaderText extends StatelessWidget {
  final String text;
  final TextAlign textAlign;
  const _HeaderText(this.text, {this.textAlign = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: textAlign,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: MangoColors.muted,
      ),
    );
  }
}

class _PaymentTableRow extends ConsumerWidget with _PaymentActionsMixin {
  final Map<String, dynamic> payment;
  final NumberFormat currency;
  final VoidCallback onRefresh;

  const _PaymentTableRow({
    required this.payment,
    required this.currency,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final amount =
        (payment['net_amount'] as num?)?.toDouble() ??
        ((payment['amount'] as num?)?.toDouble() ?? 0);
    final createdAt = AppTime.tryParseServerToAst(payment['created_at']);
    final dateStr = createdAt == null
        ? '-'
        : DateFormat('dd/MM/yyyy').format(createdAt);
    final timeStr = createdAt == null
        ? '-'
        : DateFormat('hh:mm a').format(createdAt);

    final customerName =
        payment['customer_name']?.toString() ?? 'Público General';
    final ncf = payment['ncf_number']?.toString() ?? 'Ticket';
    final ncfType = payment['ncf_type_name']?.toString() ?? 'Boleta';
    final taxId = payment['customer_tax_id']?.toString() ?? '';
    final waiterName = payment['waiter_name']?.toString() ?? 'Servicio';
    final paymentId = payment['id']?.toString() ?? '';
    final orderId = payment['order_id']?.toString() ?? '';
    final checkId = payment['check_id']?.toString();
    final isVoided =
        payment['status'] == 'void' || payment['status'] == 'cancelled';

    return Container(
      color: isVoided ? Colors.red.withValues(alpha: 0.05) : null,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateStr,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    decoration: isVoided ? TextDecoration.lineThrough : null,
                  ),
                ),
                Text(
                  timeStr,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ncfType,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    decoration: isVoided ? TextDecoration.lineThrough : null,
                    color: isVoided ? Colors.red : null,
                  ),
                ),
                Text(
                  ncf,
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              waiterName,
              style: TextStyle(
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              customerName,
              style: TextStyle(
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          Expanded(flex: 2, child: Text(taxId.isEmpty ? '-' : taxId)),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(amount),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: isVoided ? Colors.red : null,
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              payment['payment_method_summary']?.toString() ?? '—',
              style: TextStyle(
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          SizedBox(
            width: 160,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.visibility_outlined, size: 20),
                  onPressed: () => _showDetailDialog(context, ref, payment),
                  tooltip: 'Ver detalle',
                  color: MangoColors.muted,
                  visualDensity: VisualDensity.compact,
                ),
                if (!isVoided) ...[
                  IconButton(
                    icon: const Icon(Icons.print_outlined, size: 20),
                    onPressed: () => _reprintInvoice(
                      context,
                      ref,
                      payment,
                    ),
                    tooltip: 'Reimprimir',
                    color: Colors.blue,
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.swap_horiz,
                      size: 20,
                      color: Colors.orange,
                    ),
                    onPressed: () =>
                        _editPaymentMethod(context, ref, payment),
                    tooltip: 'Editar tipo de pago',
                    visualDensity: VisualDensity.compact,
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.cancel_outlined,
                      size: 20,
                      color: Colors.redAccent,
                    ),
                    onPressed: () => _voidSale(
                      context,
                      ref,
                      paymentId,
                      orderId,
                      checkId: checkId,
                    ),
                    tooltip: 'Anular',
                    visualDensity: VisualDensity.compact,
                  ),
                ] else ...[
                  // Anulada: el botón deja de ser "anular" y pasa a ser la
                  // nota de crédito — reimprimirla, o emitirla si quedó
                  // pendiente. El RPC es idempotente, así que no hay forma de
                  // sacar dos notas del mismo comprobante.
                  IconButton(
                    icon: const Icon(
                      Icons.receipt_long_outlined,
                      size: 20,
                      color: Colors.deepPurple,
                    ),
                    onPressed: () => _creditNote(context, ref, payment),
                    tooltip: 'Nota de crédito',
                    visualDensity: VisualDensity.compact,
                  ),
                  const Padding(
                    padding: EdgeInsets.only(right: 8.0),
                    child: Text(
                      'ANULADA',
                      style: TextStyle(
                        color: Colors.red,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

mixin _PaymentActionsMixin {
  Map<String, dynamic> get payment;
  VoidCallback get onRefresh;
  NumberFormat get currency;

  /// Nota de crédito de una venta ANULADA: la emite si quedó pendiente y la
  /// imprime. Si ya existe, el RPC devuelve la misma y solo se reimprime —
  /// nunca salen dos notas del mismo comprobante.
  void _creditNote(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> payment,
  ) async {
    final fdId = payment['fiscal_document_id']?.toString() ?? '';
    if (fdId.isEmpty) {
      AppToast.info(context, 'Esta venta no tenía comprobante fiscal.');
      return;
    }

    final reason =
        payment['cancellation_reason']?.toString().trim().isNotEmpty == true
        ? payment['cancellation_reason'].toString().trim()
        : 'Anulación desde historial';

    final outcome = await showCreditNoteRetryDialog(
      context,
      ref,
      fiscalDocumentId: fdId,
      reason: reason,
    );
    if (!context.mounted) return;

    final pendiente = outcome.creditNotes.where((n) => n.needsAttention);
    if (pendiente.isNotEmpty) {
      AppToast.info(context, pendiente.first.message);
    }
    onRefresh();
  }

  /// Delega en [reprintInvoiceFromPayment]. El cuerpo se movió a
  /// `utils/invoice_reprint.dart` porque Cuentas por Cobrar reimprime la
  /// misma factura y no puede haber dos copias de las reglas fiscales.
  void _reprintInvoice(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> payment,
  ) {
    reprintInvoiceFromPayment(context, ref, payment);
  }

  void _voidSale(
    BuildContext context,
    WidgetRef ref,
    String paymentId,
    String orderId, {
    String? checkId,
  }) async {
    if (paymentId.isEmpty || orderId.isEmpty) return;

    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('pagos.anular_pago')) {
      AppToast.info(context, 'No tienes permiso para anular pagos.');
      return;
    }

    final session = ref.read(sessionProvider);
    final currentRole = session.activeRole;
    // Si el usuario ya es Administrador o Supervisor, no necesita PIN otra vez.
    final bool isManager =
        currentRole == PosRole.administrador ||
        currentRole == PosRole.supervisor;

    // Confirmación inicial
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Anular Venta'),
        content: const Text(
          '¿Está seguro que desea anular esta venta? Esta acción no se puede deshacer y ajustará el balance de caja.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No, volver'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Sí, anular'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    if (!context.mounted) return;

    // 1. Verificación de Autorización
    if (!isManager) {
      // Para roles que no son Admin/Super, pedimos el PIN de un supervisor.
      final authorized = await showPinVerificationModal(
        context,
        ref,
        level: PinAccessLevel.supervisor,
        title: 'Autorización Requerida',
        subtitle: 'Ingrese PIN de Supervisor para anular la venta',
      );
      if (!authorized) return;
    }

    if (!context.mounted) return;

    // 2. Pedir motivo de anulación (Requerido por el usuario)
    final reason = await _showAnulacionReasonDialog(context);
    if (reason == null) {
      return; // El usuario canceló o cerró el diálogo de nota.
    }

    // 3. Ejecutar anulación
    //
    // Va por el popup de proceso y no por una llamada suelta: con comprobante
    // fiscal la anulación no termina cuando se anula la venta — todavía falta
    // emitir la NOTA DE CRÉDITO que la reversa, mandarla a la DGII e
    // imprimirla. El popup muestra esos pasos y, si alguno queda pendiente,
    // lo dice ahí mismo en vez de dejarlo escondido.
    if (!context.mounted) return;
    final outcome = await showAnnulmentProcessDialog(
      context,
      ref,
      paymentId: paymentId,
      orderId: orderId,
      checkId: checkId,
      reason: reason.isEmpty ? 'Anulación desde historial' : reason,
    );

    if (!context.mounted) return;

    if (!outcome.annulled) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Error al anular'),
          content: Text(outcome.error ?? 'La venta no se pudo anular.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      );
      return;
    }

    // El detalle de la nota ya se vio en el popup; acá solo queda el remate.
    final pendiente = outcome.creditNotes.where((n) => n.needsAttention);
    if (pendiente.isNotEmpty) {
      AppToast.info(context, pendiente.first.message);
    } else {
      AppToast.success(context, 'Venta anulada correctamente.');
    }

    onRefresh();
  }

  /// Corrige el tipo de pago de una venta ya cobrada (error del cajero) sin
  /// tener que anularla. Soporta ventas con pago dividido: si hay más de un
  /// pago, el usuario elige cuál corregir. Requiere PIN de supervisor a roles
  /// no gerenciales (misma barrera que anular) y reusa el permiso
  /// `pagos.anular_pago` — corregir es menos destructivo que anular.
  void _editPaymentMethod(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> payment,
  ) async {
    if (!ref
        .read(sessionProvider.notifier)
        .hasPermission('pagos.anular_pago')) {
      AppToast.info(context, 'No tienes permiso para editar pagos.');
      return;
    }

    final isVoided =
        payment['status'] == 'void' || payment['status'] == 'cancelled';
    if (isVoided) {
      AppToast.info(context, 'La venta está anulada; no se puede editar.');
      return;
    }

    final businessId = ref.read(sessionProvider).activeBusinessId;
    final fdId = payment['fiscal_document_id']?.toString();
    final repPaymentId = payment['id']?.toString() ?? '';
    if (repPaymentId.isEmpty && (fdId == null || fdId.isEmpty)) return;

    try {
      final client = Supabase.instance.client;

      // Pagos que componen esta venta. Por `fiscal_document_id` obtenemos
      // exactamente los pagos que arman el resumen de método (incluye los de
      // un pago dividido/Mixto); si no hay fd, caemos al pago representativo.
      final selectCols =
          'id, amount, change_amount, payment_method_id, status, '
          'payment_methods(name, code)';
      final rawPayments = (fdId != null && fdId.isNotEmpty)
          ? await client
                .from('payments')
                .select(selectCols)
                .eq('fiscal_document_id', fdId)
                .eq('status', 'completed')
                .order('created_at')
          : await client
                .from('payments')
                .select(selectCols)
                .eq('id', repPaymentId)
                .eq('status', 'completed');
      final salePayments = List<Map<String, dynamic>>.from(rawPayments);
      if (salePayments.isEmpty) {
        if (!context.mounted) return;
        AppToast.info(context, 'No hay pagos activos para editar.');
        return;
      }

      // Métodos de pago activos del negocio.
      final rawMethods = await client
          .from('payment_methods')
          .select('id, name, code, is_active, position')
          .eq('business_id', businessId ?? '')
          .eq('is_active', true)
          .order('position');
      final methods = List<Map<String, dynamic>>.from(rawMethods);
      if (methods.isEmpty) {
        if (!context.mounted) return;
        AppToast.info(context, 'No hay métodos de pago configurados.');
        return;
      }

      if (!context.mounted) return;

      // 1) Elegir cuál pago corregir (solo si la venta tiene varios).
      Map<String, dynamic> target;
      if (salePayments.length == 1) {
        target = salePayments.first;
      } else {
        final picked = await _pickPaymentToEditDialog(context, salePayments);
        if (picked == null) return;
        target = picked;
      }

      if (!context.mounted) return;

      // 2) Elegir el nuevo método. Crédito queda fuera en ambas direcciones:
      // cambiar de/hacia crédito dejaría la cuenta por cobrar huérfana (o no
      // la crearía). El repo también lo bloquea como backstop.
      final codeById = {
        for (final m in methods)
          m['id']?.toString() ?? '': m['code']?.toString() ?? '',
      };
      final currentMethodId = target['payment_method_id']?.toString();
      if (codeById[currentMethodId ?? ''] == 'credit') {
        AppToast.info(
          context,
          'Los pagos a crédito no se pueden corregir aquí. Anula el pago '
          '(la cuenta por cobrar se cancela sola) y cobra de nuevo con el '
          'método correcto.',
        );
        return;
      }
      final selectableMethods = methods
          .where((m) => (m['code']?.toString() ?? '') != 'credit')
          .toList();
      final newMethodId = await _pickPaymentMethodDialog(
        context,
        selectableMethods,
        currentMethodId,
      );
      if (newMethodId == null || newMethodId == currentMethodId) return;

      if (!context.mounted) return;

      // 3) Autorización: PIN de supervisor para roles no gerenciales.
      final session = ref.read(sessionProvider);
      final role = session.activeRole;
      final isManager =
          role == PosRole.administrador || role == PosRole.supervisor;
      if (!isManager) {
        final authorized = await showPinVerificationModal(
          context,
          ref,
          level: PinAccessLevel.supervisor,
          title: 'Autorización requerida',
          subtitle: 'Ingrese PIN de Supervisor para editar el tipo de pago',
        );
        if (!authorized) return;
      }

      if (!context.mounted) return;
      AppToast.info(context, 'Actualizando tipo de pago...');

      await ref.read(salesRepositoryProvider).updatePaymentMethod(
            paymentId: target['id'].toString(),
            newMethodId: newMethodId,
          );

      if (!context.mounted) return;
      AppToast.success(context, 'Tipo de pago actualizado.');
      onRefresh();
    } catch (e) {
      if (!context.mounted) return;
      AppToast.error(context, 'No se pudo editar el tipo de pago: $e');
    }
  }

  /// Diálogo para elegir cuál pago corregir en una venta con pago dividido.
  Future<Map<String, dynamic>?> _pickPaymentToEditDialog(
    BuildContext context,
    List<Map<String, dynamic>> payments,
  ) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('¿Cuál pago quieres corregir?'),
        children: payments.map((p) {
          final method = p['payment_methods'] as Map<String, dynamic>?;
          final methodName = method?['name']?.toString() ?? 'Sin método';
          final net = netPaymentAmount(p['amount'], p['change_amount']);
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(context, p),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  const Icon(Icons.payments_outlined, size: 20),
                  const SizedBox(width: 12),
                  Expanded(child: Text(methodName)),
                  Text(
                    currency.format(net),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          );
        }).toList(growable: false),
      ),
    );
  }

  /// Diálogo para elegir el nuevo método de pago. Marca el método actual.
  Future<String?> _pickPaymentMethodDialog(
    BuildContext context,
    List<Map<String, dynamic>> methods,
    String? currentMethodId,
  ) {
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Nuevo tipo de pago'),
        children: methods.map((m) {
          final id = m['id']?.toString() ?? '';
          final name = m['name']?.toString() ?? 'Método';
          final isCurrent = id == currentMethodId;
          return SimpleDialogOption(
            onPressed: isCurrent ? null : () => Navigator.pop(context, id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    isCurrent
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: isCurrent ? MangoColors.primaryOrange : null,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    name,
                    style: TextStyle(
                      fontWeight:
                          isCurrent ? FontWeight.w700 : FontWeight.w500,
                      color: isCurrent ? MangoColors.muted : null,
                    ),
                  ),
                  if (isCurrent) ...[
                    const SizedBox(width: 8),
                    const Text(
                      '(actual)',
                      style: TextStyle(
                        fontSize: 11,
                        color: MangoColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }).toList(growable: false),
      ),
    );
  }

  Future<String?> _showAnulacionReasonDialog(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.report_problem_rounded,
                  color: MangoColors.primaryOrange,
                  size: 44,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Nota de Anulación',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Esta acción es definitiva. Deja una nota explicando brevemente el motivo de la anulación.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: MangoColors.muted,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: 'Escriba el motivo aquí...',
                  hintStyle: const TextStyle(
                    color: MangoColors.muted,
                    fontWeight: FontWeight.w400,
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF7F8FA),
                  contentPadding: const EdgeInsets.all(20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(
                      color: MangoColors.primaryOrange,
                      width: 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: const Text(
                        'Cancelar',
                        style: TextStyle(
                          color: MangoColors.muted,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: MangoColors.primaryOrange.withValues(
                              alpha: 0.3,
                            ),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: () =>
                            Navigator.pop(context, controller.text.trim()),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: MangoColors.primaryOrange,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Text(
                          'Anular Venta',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetailDialog(
    BuildContext context,
    WidgetRef ref,
    Map<String, dynamic> payment,
  ) async {
    final orderId = payment['order_id']?.toString() ?? '';
    if (orderId.isEmpty) return;

    // check_id del fd asociado al payment. Si != null, el fd corresponde a
    // una sub-cuenta y solo mostramos los items de ese check. Si es null,
    // el fd es full-order y mostramos items con check_id IS NULL (los que
    // se cobraron en el pago full-order final).
    final fdCheckId = payment['check_id']?.toString();

    final ncf = payment['ncf_number']?.toString() ?? 'Sin NCF';
    final ncfType = payment['ncf_type']?.toString() ?? '';
    final customerName =
        payment['customer_name']?.toString().trim().isNotEmpty == true
        ? payment['customer_name']!.toString()
        : 'Consumidor Final';
    final customerRnc = payment['customer_rnc']?.toString() ?? '';
    final createdAt = AppTime.tryParseServerToAst(payment['created_at']);
    final dateStr = createdAt == null
        ? '-'
        : DateFormat('dd/MM/yyyy hh:mm a').format(createdAt);

    final subtotal = (payment['subtotal'] as num?)?.toDouble() ?? 0;
    final itbis = (payment['itbis_amount'] as num?)?.toDouble() ?? 0;
    final serviceFee = (payment['service_fee'] as num?)?.toDouble() ?? 0;
    final total = (payment['total'] as num?)?.toDouble() ?? 0;

    // Future compartido: carga items + filtra por scope del fd + computa
    // summary, tax breakdown y modo de presentación del descuento una sola
    // vez. Tanto el render de items como el bloque de totales lo consumen
    // para que no haya double-fetch ni riesgo de que muestren conjuntos
    // distintos.
    final businessIdLocal = ref.read(sessionProvider).activeBusinessId;
    final posSettingsRepo = ref.read(posSettingsRepositoryProvider);
    final orderItemsFuture =
        () async {
          final itemsFuture = ref
              .read(salesRepositoryProvider)
              .getOrderItems(orderId, businessId: businessIdLocal);
          final otherFdsFuture = Supabase.instance.client
              .from('fiscal_documents')
              .select('check_id, status')
              .eq('order_id', orderId);
          final discountModeFuture =
              (businessIdLocal != null && businessIdLocal.isNotEmpty)
              ? posSettingsRepo.getDiscountDisplayMode(businessIdLocal)
              : Future.value(PosSettingsRepository.discountPreDiscount);
          final results = await Future.wait<dynamic>([
            itemsFuture,
            otherFdsFuture,
            discountModeFuture,
          ]);
          final loadedItems = results[0] as List<OrderItem>;
          final fds = List<Map<String, dynamic>>.from(results[1] as List);
          final discountMode = results[2] as String;
          final otherFdCheckIds = fds
              .where(
                (f) => f['check_id'] != null && f['status'] == 'active',
              )
              .map((f) => f['check_id'].toString())
              .toSet();
          // Filtro por scope del fd:
          //   - fd.check_id != NULL → solo items del check.
          //   - fd.check_id == NULL (full-order o remainder): items con
          //     check_id NULL O items en sub-cuentas SIN fd propio.
          final filteredItems = loadedItems.where((i) {
            if (i.status == 'void') return false;
            if (fdCheckId != null && fdCheckId.isNotEmpty) {
              return i.checkId == fdCheckId;
            }
            if (i.checkId == null) return true;
            return !otherFdCheckIds.contains(i.checkId);
          }).toList(growable: false);
          final summary = summarizeOrderPricing(null, filteredItems);
          final taxBreakdown = buildOrderTaxBreakdown(null, filteredItems);
          return (
            items: filteredItems,
            summary: summary,
            taxBreakdown: taxBreakdown,
            discountMode: discountMode,
          );
        }();

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 720),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // --- ENCABEZADO ESTILO FACTURA ---
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'FACTURA',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          ncf,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: MangoColors.muted,
                          ),
                        ),
                        if (ncfType.isNotEmpty)
                          Text(
                            'Tipo: $ncfType',
                            style: const TextStyle(
                              fontSize: 11,
                              color: MangoColors.muted,
                            ),
                          ),
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          dateStr,
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Orden #${orderId.substring(0, 8).toUpperCase()}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: MangoColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(),
                // --- CLIENTE ---
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cliente: $customerName',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (customerRnc.isNotEmpty)
                      Text(
                        'RNC/Cédula: $customerRnc',
                        style: const TextStyle(
                          fontSize: 12,
                          color: MangoColors.muted,
                        ),
                      ),
                    Text(
                      'Forma de pago: '
                      '${payment['payment_method_summary']?.toString() ?? '—'}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: MangoColors.muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(),
                const SizedBox(height: 4),
                // --- ITEMS ---
                const Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(
                        'Producto',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: MangoColors.muted,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        'Cant.',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: MangoColors.muted,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 90,
                      child: Text(
                        'Subtotal',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: MangoColors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: FutureBuilder<
                      ({
                        List<OrderItem> items,
                        OrderPricingSummary summary,
                        List<({String label, double amount})> taxBreakdown,
                        String discountMode,
                      })>(
                    future: orderItemsFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState ==
                          ConnectionState.waiting) {
                        return const SizedBox(
                          height: 100,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (snapshot.hasError) {
                        return SizedBox(
                          height: 80,
                          child: Center(
                            child: Text(
                              'Error: ${snapshot.error}',
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        );
                      }
                      final data = snapshot.data;
                      final items = data?.items ?? const <OrderItem>[];

                      if (items.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No se encontraron productos para esta factura.',
                            style: TextStyle(color: MangoColors.muted),
                          ),
                        );
                      }

                      // Factor de escala para que la suma de líneas
                      // (subtotal ex-tax por ítem) coincida con el
                      // `Subtotal` del breakdown abajo en CUALQUIER modo.
                      //   Modo A: subtotalBase = (total + descuento) /
                      //           (1 + tasa). Igual o ≈ summary.subtotal
                      //           → factor ≈ 1.
                      //   Modo B: subtotalBase = total / (1 + tasa).
                      //           Más chico que summary.subtotal por el
                      //           descuento → factor < 1 escala cada
                      //           línea proporcionalmente.
                      // Si no podemos parsear las tasas, factor = 1
                      // (mostramos los valores nativos del summary).
                      double lineScale = 1.0;
                      if (data != null) {
                        final summary = data.summary;
                        final taxBreakdown = data.taxBreakdown;
                        final rates = taxBreakdown
                            .map(_parseRatePercent)
                            .toList(growable: false);
                        final allRatesKnown =
                            taxBreakdown.isNotEmpty && !rates.contains(null);
                        final declaredRate = allRatesKnown
                            ? rates.fold<double>(
                                    0, (s, r) => s + (r ?? 0)) /
                                100.0
                            : 0.0;
                        // Check de tasas uniformes: si los items mezclan
                        // taxes (ej. takeout + dine-in), la tasa
                        // efectiva real difiere de la declarada y el
                        // recompute con `(total)/(1+tasa)` daría
                        // números incorrectos. En ese caso, lineScale=1
                        // (usar valores nativos del summary, que son
                        // correctos item por item).
                        final actualRate = summary.subtotal > 0.005
                            ? (summary.tax + summary.serviceFee) /
                                summary.subtotal
                            : 0.0;
                        final ratesAreUniform =
                            (actualRate - declaredRate).abs() < 0.001;
                        final canRecompute = allRatesKnown &&
                            declaredRate > 0 &&
                            ratesAreUniform;
                        if (canRecompute && summary.subtotal > 0.005) {
                          final isPostMode = data.discountMode ==
                              PosSettingsRepository.discountPostDiscount;
                          final discountForBase =
                              isPostMode ? 0.0 : summary.discounts;
                          final subtotalBase =
                              (total + discountForBase) / (1 + declaredRate);
                          lineScale = subtotalBase / summary.subtotal;
                        }
                      }

                      return ListView.separated(
                        shrinkWrap: true,
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const Divider(height: 12),
                        itemBuilder: (context, i) {
                          final item = items[i];
                          final itemQty = item.quantity <= 0
                              ? 1.0
                              : item.quantity;
                          final note = item.notes?.trim() ?? '';
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 5,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.productName,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    ...item.modifiers.map((m) {
                                      // Costo del modifier alineado al
                                      // backend (catalogGrossAmount):
                                      // qty_item × qty_modifier × precio.
                                      // `currency` ya incluye símbolo
                                      // "RD$" — no anteponerlo aquí o
                                      // sale duplicado.
                                      final modTotal =
                                          m.price * itemQty * m.qty;
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                          top: 2,
                                        ),
                                        child: Text(
                                          modTotal > 0
                                              ? '+ ${m.name} (+${currency.format(modTotal)})'
                                              : '+ ${m.name}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: MangoColors.muted,
                                          ),
                                        ),
                                      );
                                    }),
                                    if (note.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: 2,
                                        ),
                                        child: Text(
                                          'Nota: $note',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontStyle: FontStyle.italic,
                                            color: MangoColors.muted,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 40,
                                child: Text(
                                  _formatQty(item.quantity),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                              SizedBox(
                                width: 90,
                                child: Text(
                                  // `itemDisplayBaseTotal` da el subtotal
                                  // ex-tax por línea con modifiers
                                  // incluidos. Lo escalamos por
                                  // `lineScale` para que la suma de
                                  // líneas coincida exactamente con el
                                  // `Subtotal` del breakdown abajo en
                                  // cualquier modo (A o B). Capamos a 0
                                  // para cortesías históricas con
                                  // discount > subtotal (bug previo).
                                  currency.format(
                                    () {
                                      final base = itemDisplayBaseTotal(
                                        null,
                                        item,
                                      );
                                      final scaled = base * lineScale;
                                      return scaled < 0 ? 0.0 : scaled;
                                    }(),
                                  ),
                                  textAlign: TextAlign.right,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(),
                // --- TOTALES ---
                // Derivamos el bloque de totales desde los items (igual que
                // el ticket impreso vía summarizeOrderPricing), de forma
                // que modal y papel coincidan 1:1 y el descuento muestre
                // el RD$ real, no uno calculado por aritmética inversa.
                //
                // Fallback de seguridad: si la suma de items no cuadra con
                // el total guardado en fiscal_documents (>RD$1 de diff,
                // típico de órdenes editadas tras emitir el fd), volvemos
                // a los valores del fd y avisamos al cajero. El fd es la
                // fuente oficial de lo que se cobró.
                FutureBuilder<
                  ({
                    List<OrderItem> items,
                    OrderPricingSummary summary,
                    List<({String label, double amount})> taxBreakdown,
                    String discountMode,
                  })
                >(
                  future: orderItemsFuture,
                  builder: (context, snapshot) {
                    final data = snapshot.data;
                    final hasData =
                        snapshot.connectionState == ConnectionState.done &&
                        data != null &&
                        data.items.isNotEmpty;
                    // Si los items aún no cargan o vienen vacíos, mostramos
                    // los valores del fd con el descuento derivado por
                    // aritmética inversa (subtotal + tax + servicio − total).
                    if (!hasData) {
                      final discount = subtotal + itbis + serviceFee - total;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _invoiceTotalRow('Subtotal', subtotal, currency),
                          if (itbis > 0)
                            _invoiceTotalRow('ITBIS', itbis, currency),
                          if (serviceFee > 0)
                            _invoiceTotalRow(
                              'Servicio (10%)',
                              serviceFee,
                              currency,
                            ),
                          if (discount > 0.005)
                            _invoiceTotalRow(
                              'Descuento',
                              -discount,
                              currency,
                            ),
                          const SizedBox(height: 4),
                          _invoiceTotalRow(
                            'TOTAL',
                            total,
                            currency,
                            isTotal: true,
                          ),
                        ],
                      );
                    }

                    final summary = data.summary;
                    final taxBreakdown = data.taxBreakdown;
                    final mismatch = (summary.total - total).abs() > 1.0;

                    if (mismatch) {
                      // Items editados después de emitir el fd: la fuente
                      // oficial es el fd. Usamos sus valores y el descuento
                      // derivado, igual que el path anterior.
                      final discount = subtotal + itbis + serviceFee - total;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _invoiceTotalRow('Subtotal', subtotal, currency),
                          if (itbis > 0)
                            _invoiceTotalRow('ITBIS', itbis, currency),
                          if (serviceFee > 0)
                            _invoiceTotalRow(
                              'Servicio (10%)',
                              serviceFee,
                              currency,
                            ),
                          if (discount > 0.005)
                            _invoiceTotalRow(
                              'Descuento',
                              -discount,
                              currency,
                            ),
                          const SizedBox(height: 4),
                          _invoiceTotalRow(
                            'TOTAL',
                            total,
                            currency,
                            isTotal: true,
                          ),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Los productos cargados difieren del total '
                              'registrado en el comprobante; se muestran '
                              'los valores oficiales del fiscal document.',
                              style: const TextStyle(
                                fontSize: 10,
                                color: MangoColors.muted,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        ],
                      );
                    }

                    // Path nominal: recomputamos subtotal/impuestos según
                    // el modo elegido por el negocio para que la math
                    // siempre cuadre visualmente. Tasa efectiva = suma de
                    // tasas únicas extraídas de las labels de
                    // `taxBreakdown` (que ya vienen como "ITBIS (18%)",
                    // "Propina Ley (10%)", etc.).
                    //
                    //   Modo A (pre_discount, default):
                    //     subtotalBase = (total + descuento) / (1 + tasa)
                    //     Subtotal + ITBIS − Descuento = Total
                    //
                    //   Modo B (post_discount):
                    //     subtotalBase = total / (1 + tasa)
                    //     Subtotal + ITBIS = Total; descuento es nota.
                    //
                    // Si no podemos extraer la tasa de las labels (caso
                    // raro de comprobantes sin impuestos), caemos al
                    // path histórico de "absorber el gap en subtotal".
                    final rates = taxBreakdown
                        .map(_parseRatePercent)
                        .toList(growable: false);
                    final allRatesKnown =
                        taxBreakdown.isNotEmpty && !rates.contains(null);
                    final declaredRate = allRatesKnown
                        ? rates.fold<double>(0, (s, r) => s + (r ?? 0)) / 100.0
                        : 0.0;

                    final isPostMode = data.discountMode ==
                        PosSettingsRepository.discountPostDiscount;

                    // Detección de tasas uniformes: el recompute
                    // `(total)/(1+tasa)` asume que la tasa aplica a
                    // todo el subtotal. Si los items mezclan tasas
                    // (ej. takeout + dine-in), `summary.tax /
                    // summary.subtotal` da un ratio menor que la
                    // tasa declarada, y el recompute sale incorrecto.
                    // Cuando sucede caemos al path de absorción de
                    // gap (que usa los valores nativos del summary).
                    final actualRate = summary.subtotal > 0.005
                        ? (summary.tax + summary.serviceFee) /
                            summary.subtotal
                        : 0.0;
                    final ratesAreUniform =
                        (actualRate - declaredRate).abs() < 0.001;

                    if (allRatesKnown &&
                        declaredRate > 0 &&
                        ratesAreUniform) {
                      final discountForBase = isPostMode
                          ? 0.0
                          : summary.discounts;
                      final subtotalBase =
                          (total + discountForBase) / (1 + declaredRate);
                      final recomputedLines = <({
                        String label,
                        double amount,
                      })>[];
                      for (var i = 0; i < taxBreakdown.length; i++) {
                        final rate = rates[i] ?? 0;
                        recomputedLines.add((
                          label: taxBreakdown[i].label,
                          amount: subtotalBase * (rate / 100),
                        ));
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _invoiceTotalRow(
                            'Subtotal',
                            subtotalBase,
                            currency,
                          ),
                          ...recomputedLines.map(
                            (line) => _invoiceTotalRow(
                              line.label,
                              line.amount,
                              currency,
                            ),
                          ),
                          if (!isPostMode && summary.discounts > 0.005)
                            _invoiceTotalRow(
                              'Descuento',
                              -summary.discounts,
                              currency,
                            ),
                          const SizedBox(height: 4),
                          _invoiceTotalRow(
                            'TOTAL',
                            total,
                            currency,
                            isTotal: true,
                          ),
                          if (isPostMode && summary.discounts > 0.005)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                // `currency` ya incluye símbolo RD$.
                                'Esta venta incluye un descuento aplicado '
                                'de ${currency.format(summary.discounts)}.',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: MangoColors.muted,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      );
                    }

                    // Fallback (sin tasa parseable): comportamiento
                    // anterior — absorbemos el gap en el subtotal para
                    // que el sum visual cierre.
                    final taxSum = taxBreakdown.fold<double>(
                      0,
                      (s, e) => s + e.amount,
                    );
                    final accounted =
                        summary.subtotal + taxSum - summary.discounts;
                    final extras = summary.total - accounted;
                    final displaySubtotal = summary.subtotal + extras;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _invoiceTotalRow(
                          'Subtotal',
                          displaySubtotal,
                          currency,
                        ),
                        ...taxBreakdown.map(
                          (line) =>
                              _invoiceTotalRow(line.label, line.amount, currency),
                        ),
                        if (summary.discounts > 0.005)
                          _invoiceTotalRow(
                            'Descuento',
                            -summary.discounts,
                            currency,
                          ),
                        const SizedBox(height: 4),
                        _invoiceTotalRow(
                          'TOTAL',
                          summary.total,
                          currency,
                          isTotal: true,
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _reprintInvoice(context, ref, payment);
                      },
                      icon: const Icon(Icons.print_outlined, size: 18),
                      label: const Text('Reimprimir'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: MangoColors.successGreen,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: MangoColors.primaryOrange,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 10,
                        ),
                      ),
                      child: const Text('Cerrar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _invoiceTotalRow(
    String label,
    double amount,
    NumberFormat currency, {
    bool isTotal = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: isTotal ? 14 : 12,
              fontWeight: isTotal ? FontWeight.w800 : FontWeight.w500,
              color: isTotal ? null : MangoColors.muted,
            ),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 100,
            child: Text(
              currency.format(amount),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: isTotal ? 16 : 12,
                fontWeight: isTotal ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

}

class _PaymentMobileCard extends ConsumerWidget with _PaymentActionsMixin {
  @override
  final Map<String, dynamic> payment;
  final NumberFormat currency;
  @override
  final VoidCallback onRefresh;

  const _PaymentMobileCard({
    required this.payment,
    required this.currency,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final amount =
        (payment['net_amount'] as num?)?.toDouble() ??
        ((payment['amount'] as num?)?.toDouble() ?? 0);
    final createdAt = AppTime.tryParseServerToAst(payment['created_at']);
    final dateStr = createdAt == null
        ? '-'
        : DateFormat('dd/MM/yyyy').format(createdAt);
    final timeStr = createdAt == null
        ? '-'
        : DateFormat('hh:mm a').format(createdAt);

    final customerName =
        payment['customer_name']?.toString() ?? 'Público General';
    final ncf = payment['ncf_number']?.toString() ?? 'Ticket';
    final ncfType = payment['ncf_type_name']?.toString() ?? 'Boleta';
    final waiterName = payment['waiter_name']?.toString() ?? 'Servicio';
    final paymentId = payment['id']?.toString() ?? '';
    final orderId = payment['order_id']?.toString() ?? '';
    final checkId = payment['check_id']?.toString();
    final isVoided =
        payment['status'] == 'void' || payment['status'] == 'cancelled';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: isVoided ? Colors.red.withValues(alpha: 0.05) : MangoColors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isVoided ? Colors.red.withValues(alpha: 0.3) : MangoColors.cardBorder,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ncfType,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                          color: isVoided ? Colors.red : null,
                          decoration: isVoided ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ncf,
                        style: const TextStyle(
                          fontSize: 12,
                          color: MangoColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      currency.format(amount),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: isVoided ? Colors.red : MangoColors.darkGray,
                        decoration: isVoided ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$dateStr $timeStr',
                      style: const TextStyle(
                        fontSize: 11,
                        color: MangoColors.muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InfoRow(icon: Icons.person_outline, text: customerName, isVoided: isVoided),
                      const SizedBox(height: 4),
                      _InfoRow(icon: Icons.support_agent_outlined, text: waiterName, isVoided: isVoided),
                      const SizedBox(height: 4),
                      _InfoRow(
                        icon: Icons.payments_outlined,
                        text: payment['payment_method_summary']?.toString() ??
                            'Sin método',
                        isVoided: isVoided,
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.visibility_outlined, size: 20),
                      onPressed: () => _showDetailDialog(context, ref, payment),
                      color: MangoColors.muted,
                      visualDensity: VisualDensity.compact,
                    ),
                    if (!isVoided) ...[
                      IconButton(
                        icon: const Icon(Icons.print_outlined, size: 20),
                        onPressed: () => _reprintInvoice(context, ref, payment),
                        color: Colors.blue,
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        icon: const Icon(Icons.swap_horiz, size: 20),
                        onPressed: () =>
                            _editPaymentMethod(context, ref, payment),
                        color: Colors.orange,
                        tooltip: 'Editar tipo de pago',
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        icon: const Icon(Icons.cancel_outlined, size: 20),
                        onPressed: () => _voidSale(context, ref, paymentId, orderId, checkId: checkId),
                        color: Colors.redAccent,
                        visualDensity: VisualDensity.compact,
                      ),
                    ] else ...[
                      IconButton(
                        icon: const Icon(
                          Icons.receipt_long_outlined,
                          size: 20,
                        ),
                        onPressed: () => _creditNote(context, ref, payment),
                        color: Colors.deepPurple,
                        tooltip: 'Nota de crédito',
                        visualDensity: VisualDensity.compact,
                      ),
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Text(
                          'ANULADA',
                          style: TextStyle(
                            color: Colors.red,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool isVoided;

  const _InfoRow({required this.icon, required this.text, this.isVoided = false});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: MangoColors.muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: MangoColors.darkGray,
              decoration: isVoided ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _SalesHistoryData {
  final List<Map<String, dynamic>> payments;
  final int totalCount;

  const _SalesHistoryData({
    required this.payments,
    required this.totalCount,
  });
}

class _CashierInfoState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _CashierInfoState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}

