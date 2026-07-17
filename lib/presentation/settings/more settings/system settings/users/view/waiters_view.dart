import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/data/models/sales_models.dart';
import 'package:mangopos/data/repositories/employee_repository.dart';
import 'package:mangopos/data/utils/business_id_resolver.dart';
import 'package:mangopos/data/utils/order_pricing_utils.dart';
import 'package:mangopos/data/utils/payment_amount_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SettingsWaitersView extends StatefulWidget {
  final String businessId;
  const SettingsWaitersView({super.key, required this.businessId});

  @override
  State<SettingsWaitersView> createState() => _SettingsWaitersViewState();
}

class _SettingsWaitersViewState extends State<SettingsWaitersView> {
  final _repo = EmployeeRepository(Supabase.instance.client);
  final _search = TextEditingController();

  bool _loading = true;
  String? _error;
  String _shiftFilter = 'Todos';
  String _sortBy = 'Ventas actuales';
  bool _onlyActive = false;
  List<_WaiterMetric> _waiters = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final sb = Supabase.instance.client;

    try {
      final bid =
          await resolveBusinessIdOrNull(sb, widget.businessId) ??
          widget.businessId;

      final employees = await _repo.fetchEmployees(businessId: bid);
      final waiters = employees.where((employee) {
        final roles = employee.roles.map((role) => role.toLowerCase().trim());
        return roles.contains('waiter');
      }).toList(growable: false);

      final sessionsRaw = await sb
          .from('table_sessions')
          .select('id, waiter_user_id, opened_by, opened_by_employee_id')
          .eq('business_id', bid)
          .eq('origin', 'dine_in')
          .isFilter('closed_at', null);

      final sessions = List<Map<String, dynamic>>.from(sessionsRaw);
      final openSessionIds = sessions
          .map((row) => row['id']?.toString().trim())
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toList(growable: false);

      final pendingBySessionId = <String, double>{};
      if (openSessionIds.isNotEmpty) {
        final openOrdersRaw = List<Map<String, dynamic>>.from(
          await sb
              .from('orders')
              .select(
                'id,session_id,status_ext,subtotal,tax,service_fee,discounts,total,created_at,closed_at',
              )
              .inFilter('session_id', openSessionIds)
              .isFilter('closed_at', null)
              .not('status_ext', 'in', '(paid,void)'),
        );

        final orderIds = openOrdersRaw
            .map((row) => row['id']?.toString().trim())
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toList(growable: false);

        final itemsByOrderId = <String, List<OrderItem>>{};
        final closedCheckIdsByOrderId = <String, Set<String>>{};

        if (orderIds.isNotEmpty) {
          final itemRows = List<Map<String, dynamic>>.from(
            await sb
                .from('order_items')
                .select(
                  'id,order_id,product_id,product_name,sku,qty,quantity,unit_price,subtotal,discounts,tax,total,check_id,is_takeout,status,notes,tax_mode,tax_rate,created_at',
                )
                .inFilter('order_id', orderIds)
                .not('status', 'in', '(paid,void)'),
          );

          final checkRows = List<Map<String, dynamic>>.from(
            await sb
                .from('order_checks')
                .select('id,order_id,is_closed')
                .inFilter('order_id', orderIds),
          );

          for (final itemRow in itemRows) {
            final item = OrderItem.fromMap(itemRow);
            final orderId = item.orderId.trim();
            if (orderId.isEmpty) continue;
            itemsByOrderId.putIfAbsent(orderId, () => <OrderItem>[]).add(item);
          }

          for (final checkRow in checkRows) {
            final checkId = checkRow['id']?.toString().trim();
            final orderId = checkRow['order_id']?.toString().trim();
            if (orderId == null || orderId.isEmpty) continue;
            if (checkRow['is_closed'] != true) continue;
            if (checkId == null || checkId.isEmpty) continue;
            closedCheckIdsByOrderId.putIfAbsent(orderId, () => <String>{}).add(checkId);
          }
        }

        for (final orderRow in openOrdersRaw) {
          final order = Order.fromMap(orderRow);
          final sessionId = order.sessionId.trim();
          if (sessionId.isEmpty) continue;
          final closedCheckIds = closedCheckIdsByOrderId[order.id] ?? const <String>{};
          final pendingItems = (itemsByOrderId[order.id] ?? const <OrderItem>[])
              .where((item) => !closedCheckIds.contains(item.checkId))
              .toList(growable: false);
          final pendingTotal = summarizeOrderPricing(order, pendingItems).total;
          pendingBySessionId[sessionId] =
              (pendingBySessionId[sessionId] ?? 0) + pendingTotal;
        }
      }

      final dayRange = AppTime.todayRangeUtc();
      final paidOrdersRaw = await sb
          .from('payments')
          .select('order_id, amount, change_amount, orders!inner(session_id, table_sessions!inner(business_id, origin, waiter_user_id, opened_by, opened_by_employee_id))')
          .eq('status', 'completed')
          .eq('business_id', bid)
          .gte('created_at', dayRange.fromUtc.toIso8601String())
          .lt('created_at', dayRange.toUtc.toIso8601String());

      // Dueño de una sesión, con la MISMA prioridad que v_zone_table_status:
      // empleado que abrió vía PIN (multimesero) > waiter_user_id > opened_by.
      // En multimesero waiter_user_id/opened_by traen la cuenta compartida del
      // dispositivo, así que sin opened_by_employee_id todas las mesas caían
      // en el usuario logueado y el mesero real quedaba en 0.
      String? ownerKeyOf(Map<String, dynamic>? session) {
        final employeeId =
            session?['opened_by_employee_id']?.toString().trim();
        if (employeeId != null && employeeId.isNotEmpty) {
          return 'emp:$employeeId';
        }
        final waiterUserId = session?['waiter_user_id']?.toString().trim();
        if (waiterUserId != null && waiterUserId.isNotEmpty) {
          return 'usr:$waiterUserId';
        }
        final openedBy = session?['opened_by']?.toString().trim();
        if (openedBy != null && openedBy.isNotEmpty) {
          return 'usr:$openedBy';
        }
        return null;
      }

      final paidSalesByOwner = <String, double>{};
      for (final payment in List<Map<String, dynamic>>.from(paidOrdersRaw)) {
        final order = payment['orders'] as Map<String, dynamic>?;
        final tableSession = order?['table_sessions'] as Map<String, dynamic>?;
        final origin = tableSession?['origin']?.toString().trim();
        if (origin != 'dine_in') continue;

        final ownerKey = ownerKeyOf(tableSession);
        if (ownerKey == null) continue;

        paidSalesByOwner[ownerKey] =
            (paidSalesByOwner[ownerKey] ?? 0) +
            netPaymentAmount(payment['amount'], payment['change_amount']);
      }

      final openTablesByOwner = <String, int>{};
      final pendingByOwner = <String, double>{};

      for (final session in sessions) {
        final ownerKey = ownerKeyOf(session);
        final sessionId = session['id']?.toString().trim();
        if (ownerKey == null) continue;
        if (sessionId == null || sessionId.isEmpty) continue;

        openTablesByOwner[ownerKey] = (openTablesByOwner[ownerKey] ?? 0) + 1;
        pendingByOwner[ownerKey] =
            (pendingByOwner[ownerKey] ?? 0) + (pendingBySessionId[sessionId] ?? 0);
      }

      // Cada sesión cae en UNO solo de los dos buckets (emp: o usr:), así
      // que sumar ambos por empleado no duplica.
      double sumOwner(Map<String, double> map, Employee employee) {
        final byEmployee = map['emp:${employee.id}'] ?? 0;
        final userId = employee.userId?.trim();
        final byUser = (userId == null || userId.isEmpty)
            ? 0.0
            : (map['usr:$userId'] ?? 0);
        return byEmployee + byUser;
      }

      int sumOwnerInt(Map<String, int> map, Employee employee) {
        final byEmployee = map['emp:${employee.id}'] ?? 0;
        final userId = employee.userId?.trim();
        final byUser = (userId == null || userId.isEmpty)
            ? 0
            : (map['usr:$userId'] ?? 0);
        return byEmployee + byUser;
      }

      final metrics = waiters
          .map(
            (employee) => _WaiterMetric(
              employee: employee,
              openTables: sumOwnerInt(openTablesByOwner, employee),
              currentSales: sumOwner(paidSalesByOwner, employee),
              pendingSales: sumOwner(pendingByOwner, employee),
            ),
          )
          .toList()
        ..sort((a, b) => b.currentSales.compareTo(a.currentSales));

      if (!mounted) return;
      setState(() {
        _waiters = metrics;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Error al cargar mozos: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final shiftOptions = <String>{'Todos', ..._waiters.map((w) => w.shiftLabel)}.toList();

    final filtered = _waiters.where((waiter) {
      final search = _search.text.trim().toLowerCase();
      final matchesSearch =
          search.isEmpty ||
          waiter.employee.fullName.toLowerCase().contains(search) ||
          waiter.employee.email.toLowerCase().contains(search) ||
          waiter.employee.phone.toLowerCase().contains(search);
      final matchesActive = !_onlyActive || waiter.employee.status == 'active';
      final matchesShift = _shiftFilter == 'Todos' || waiter.shiftLabel == _shiftFilter;
      return matchesSearch && matchesActive && matchesShift;
    }).toList(growable: true);

    filtered.sort((a, b) {
      if (_sortBy == 'Mesas abiertas') {
        final byTables = b.openTables.compareTo(a.openTables);
        if (byTables != 0) return byTables;
        return b.currentSales.compareTo(a.currentSales);
      }
      if (_sortBy == 'Pendiente por cobrar') {
        final byPending = b.pendingSales.compareTo(a.pendingSales);
        if (byPending != 0) return byPending;
        return b.openTables.compareTo(a.openTables);
      }
      final bySales = b.currentSales.compareTo(a.currentSales);
      if (bySales != 0) return bySales;
      return b.openTables.compareTo(a.openTables);
    });

    final totalOpenTables = _waiters.fold<int>(0, (sum, item) => sum + item.openTables);
    final totalCurrentSales = _waiters.fold<double>(0, (sum, item) => sum + item.currentSales);
    final totalPendingSales = _waiters.fold<double>(0, (sum, item) => sum + item.pendingSales);
    final activeWaiters = _waiters.where((item) => item.employee.status == 'active').length;
    final topWaiter = filtered.isEmpty ? (_waiters.isEmpty ? null : _waiters.first) : filtered.first;

    return Scaffold(
      backgroundColor: const Color(0xFFFAF8F6),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.4,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.dashboard),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Mozos',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            Text(
              'Cobrado y pendiente por cobrar por mozo',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ],
        ),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                        const SizedBox(height: 10),
                        OutlinedButton(onPressed: _load, child: const Text('Reintentar')),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _KpiCard(
                              title: 'Total mozos',
                              value: '${_waiters.length}',
                              icon: Icons.groups_2_outlined,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _KpiCard(
                              title: 'Activos',
                              value: '$activeWaiters',
                              icon: Icons.verified_user,
                              accent: const Color(0xFF22C55E),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _KpiCard(
                              title: 'Mesas abiertas',
                              value: '$totalOpenTables',
                              icon: Icons.table_restaurant_outlined,
                              accent: const Color(0xFF3B82F6),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _KpiCard(
                              title: 'Ventas actuales',
                              value: _formatMoney(totalCurrentSales),
                              icon: Icons.attach_money_rounded,
                              accent: const Color(0xFFF59E0B),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _KpiCard(
                              title: 'Pendiente por cobrar',
                              value: _formatMoney(totalPendingSales),
                              icon: Icons.receipt_long_outlined,
                              accent: const Color(0xFFEF4444),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      if (topWaiter != null) ...[
                        _TopWaiterCard(metric: topWaiter, formatMoney: _formatMoney),
                        const SizedBox(height: 14),
                      ],
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade200),
                          boxShadow: [
                            BoxShadow(
                              blurRadius: 12,
                              offset: const Offset(0, 3),
                              color: Colors.black.withValues(alpha: 0.04),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 4,
                                  child: TextField(
                                    controller: _search,
                                    decoration: InputDecoration(
                                      hintText: 'Buscar por nombre, email o teléfono...',
                                      prefixIcon: const Icon(Icons.search),
                                      filled: true,
                                      fillColor: const Color(0xFFF6F6F7),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  flex: 2,
                                  child: DropdownButtonFormField<String>(
                                    initialValue: _sortBy,
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'Ventas actuales',
                                        child: Text('Ventas actuales'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'Pendiente por cobrar',
                                        child: Text('Pendiente por cobrar'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'Mesas abiertas',
                                        child: Text('Mesas abiertas'),
                                      ),
                                    ],
                                    decoration: InputDecoration(
                                      labelText: 'Ordenar por',
                                      labelStyle: const TextStyle(color: Color(0xFFFF7F1F)),
                                      filled: true,
                                      fillColor: const Color(0xFFFFF2E8),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: BorderSide.none,
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: const BorderSide(color: Color(0xFFFFD7B8)),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(14),
                                        borderSide: const BorderSide(color: Color(0xFFFF7F1F), width: 1.4),
                                      ),
                                    ),
                                    dropdownColor: Colors.white,
                                    iconEnabledColor: const Color(0xFFFF7F1F),
                                    onChanged: (value) => setState(() => _sortBy = value ?? 'Ventas actuales'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                FilterChip(
                                  label: const Text('Solo activos'),
                                  labelStyle: TextStyle(
                                    color: _onlyActive ? Colors.white : const Color(0xFFFF7F1F),
                                    fontWeight: FontWeight.w600,
                                  ),
                                  selected: _onlyActive,
                                  onSelected: (value) => setState(() => _onlyActive = value),
                                  backgroundColor: const Color(0xFFFFF2E8),
                                  selectedColor: const Color(0xFFFF7F1F),
                                  checkmarkColor: Colors.white,
                                  side: const BorderSide(color: Color(0xFFFFD7B8)),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: shiftOptions
                                  .map(
                                    (shift) => ChoiceChip(
                                      label: Text(shift),
                                      labelStyle: TextStyle(
                                        color: _shiftFilter == shift ? Colors.white : const Color(0xFFFF7F1F),
                                        fontWeight: FontWeight.w600,
                                      ),
                                      selected: _shiftFilter == shift,
                                      onSelected: (_) => setState(() => _shiftFilter = shift),
                                      backgroundColor: const Color(0xFFFFF2E8),
                                      selectedColor: const Color(0xFFFF7F1F),
                                      side: const BorderSide(color: Color(0xFFFFD7B8)),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                    ),
                                  )
                                  .toList(growable: false),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Card(
                        color: Colors.white,
                        elevation: 0.6,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: Colors.grey.shade200),
                        ),
                        child: Column(
                          children: [
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                              child: Row(
                                children: [
                                  Expanded(flex: 3, child: _HeaderLabel('Mozo')),
                                  Expanded(flex: 2, child: _HeaderLabel('Estado')),
                                  Expanded(flex: 2, child: _HeaderLabel('Departamento')),
                                  Expanded(flex: 2, child: _HeaderLabel('Mesas abiertas')),
                                  Expanded(flex: 2, child: _HeaderLabel('Ventas actuales')),
                                  Expanded(flex: 2, child: _HeaderLabel('Pendiente')),
                                ],
                              ),
                            ),
                            const Divider(height: 1),
                            if (filtered.isEmpty)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 24),
                                child: Text('No se encontraron mozos para los filtros actuales.'),
                              )
                            else
                              ...filtered.map((waiter) => _WaiterRow(metric: waiter)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  String _formatMoney(double value) {
    // RD usa formato US (,000.00) — no español europeo (.000,00).
    // El locale 'es_DO' en Dart intl cae al patrón español de España
    // (separador miles `.`). Forzamos `en_US` para que los miles sean
    // `,` que es lo correcto para Dominicana.
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$ ',
      decimalDigits: 0,
    );
    return currency.format(value);
  }
}

class _WaiterMetric {
  final Employee employee;
  final int openTables;
  final double currentSales;
  final double pendingSales;

  const _WaiterMetric({
    required this.employee,
    required this.openTables,
    required this.currentSales,
    required this.pendingSales,
  });

  String get shiftLabel {
    final raw = employee.workSchedule?.trim();
    if (raw == null || raw.isEmpty) return 'Sin turno';
    return raw;
  }
}

class _TopWaiterCard extends StatelessWidget {
  const _TopWaiterCard({required this.metric, required this.formatMoney});

  final _WaiterMetric metric;
  final String Function(double value) formatMoney;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFE0C2)),
        boxShadow: [
          BoxShadow(
            blurRadius: 12,
            offset: const Offset(0, 3),
            color: Colors.black.withValues(alpha: 0.04),
          ),
        ],
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 24,
            backgroundColor: Color(0xFFFFF2E8),
            foregroundColor: Color(0xFFFF7F1F),
            child: Icon(Icons.emoji_events_outlined),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Top mozo del momento',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 2),
                Text(
                  metric.employee.fullName,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                Text(
                  '${metric.openTables} mesas abiertas · ${formatMoney(metric.currentSales)} cobradas · ${formatMoney(metric.pendingSales)} pendientes',
                  style: TextStyle(color: Colors.grey[700]),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.title,
    required this.value,
    required this.icon,
    this.accent,
  });

  final String title;
  final String value;
  final IconData icon;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? const Color(0xFFFF7F1F);
    return Card(
      color: Colors.white,
      elevation: 0.6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.12),
              foregroundColor: color,
              child: Icon(icon),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 2),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderLabel extends StatelessWidget {
  const _HeaderLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontWeight: FontWeight.w700,
        color: Colors.grey[700],
      ),
    );
  }
}

class _WaiterRow extends StatelessWidget {
  const _WaiterRow({required this.metric});

  final _WaiterMetric metric;

  @override
  Widget build(BuildContext context) {
    final employee = metric.employee;
    // RD usa formato US (,000) — ver nota en _WaitersViewState._formatMoney
    final currency = NumberFormat.currency(
      locale: 'en_US',
      symbol: 'RD\$ ',
      decimalDigits: 0,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: const Color(0xFFFFF2E8),
                  foregroundColor: const Color(0xFFFF7F1F),
                  child: Text(employee.initials),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(employee.fullName, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(
                        employee.email.isNotEmpty ? employee.email : employee.phone,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _StatusPill(status: employee.status),
            ),
          ),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(employee.department ?? '-'),
                Text(
                  employee.position ?? 'Mesero',
                  style: TextStyle(color: Colors.grey[600], fontSize: 12),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              '${metric.openTables}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(metric.currentSales),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              currency.format(metric.pendingSales),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    late final Color background;
    late final Color foreground;
    late final String label;

    switch (status) {
      case 'active':
        background = const Color(0xFFE8F8EE);
        foreground = const Color(0xFF15803D);
        label = 'Activo';
        break;
      case 'inactive':
        background = const Color(0xFFF1F5F9);
        foreground = const Color(0xFF475569);
        label = 'Inactivo';
        break;
      default:
        background = const Color(0xFFFFF4E5);
        foreground = const Color(0xFFB45309);
        label = 'Cambio clave';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foreground,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}
