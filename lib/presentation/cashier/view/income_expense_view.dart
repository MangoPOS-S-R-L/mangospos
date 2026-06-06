import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/utils/app_toast.dart';
import 'package:mangopos/core/utils/app_time.dart';
import 'package:mangopos/data/models/payment_models.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/presentation/settings/more%20settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'package:mangopos/services/printing/print_ticket_service.dart';
import 'package:mangopos/services/session/session_controller.dart';

class IncomeExpenseView extends ConsumerStatefulWidget {
  const IncomeExpenseView({super.key});

  @override
  ConsumerState<IncomeExpenseView> createState() => _IncomeExpenseViewState();
}

class _IncomeExpenseViewState extends ConsumerState<IncomeExpenseView> {
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();
  String _selectedType = 'deposit';
  String? _selectedReasonCode;
  bool _isSubmitting = false;
  late Future<_ManualCashData?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<_ManualCashData?> _load() async {
    final cashierVM = ref.read(cashierViewModelProvider);
    final repository = ref.read(cashierRepositoryProvider);

    // 1. Primero intentamos usar la última sesión cargada en el ViewModel si está abierta
    Map<String, dynamic>? activeSessionData = cashierVM.lastSession;

    // 2. Si no es 'open', buscamos directamente la última sesión de la caja actual para confirmar su estado
    if (activeSessionData == null || activeSessionData['status'] != 'open') {
      final registerId = cashierVM.currentRegisterId;
      if (registerId != null) {
        activeSessionData = await repository.getLastSession(registerId);
      }
    }

    // Si sigue sin haber una caja abierta, retornamos null (mostrará pantalla de caja cerrada)
    if (activeSessionData == null || activeSessionData['status'] != 'open') {
      return null;
    }

    final session = CashRegisterSession.fromMap(activeSessionData);

    // Sprint Caja Pro — resolver business_id desde el cash_register
    // para cargar el catálogo de razones del negocio.
    String businessId = '';
    try {
      final crRow = await repository.getRegisterPrinterId(
        session.cashRegisterId,
      );
      // getRegisterPrinterId no devuelve business; vamos por otro path.
      // Truco: el cash_register tiene business_id, lo leemos directo.
      // (Si más adelante se usa BusinessResolver alcanza tambien.)
      businessId = crRow ?? '';
    } catch (_) {}
    if (businessId.isEmpty) {
      try {
        final cashierVm2 = ref.read(cashierViewModelProvider);
        businessId = cashierVm2.businessId ?? '';
      } catch (_) {}
    }

    final transactions = await repository.getSessionTransactions(session.id);
    final manualTransactions = transactions
        .where(
          (tx) =>
              tx.type == 'deposit' ||
              tx.type == 'withdrawal' ||
              tx.type == 'expense',
        )
        .toList();

    final reasons = businessId.isEmpty
        ? const <Map<String, dynamic>>[]
        : await repository.getCashTransactionReasons(businessId: businessId);

    return _ManualCashData(
      session: session,
      transactions: manualTransactions,
      reasons: reasons,
      businessId: businessId,
    );
  }

  Future<void> _refresh() async {
    await ref.read(cashierViewModelProvider).refreshSilently();
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
  }

  Future<void> _submit(_ManualCashData data) async {
    if (_isSubmitting) return;

    // Defensa en profundidad — el form no debería renderizarse sin este
    // permiso, pero validamos también acá por si una versión vieja del
    // widget (cache, hot reload) bypassa el gate.
    final canCreate = ref
        .read(sessionProvider.notifier)
        .hasPermission('caja.movimientos_crear');
    if (!canCreate) {
      AppToast.error(
        context,
        'No tenés permiso para registrar movimientos de caja.',
      );
      return;
    }

    final amount = double.tryParse(_amountController.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      AppToast.info(context, 'Ingresa un monto válido');
      return;
    }

    // La descripción es opcional ahora — la razón estructurada la
    // reemplaza para auditoría. Si el cajero igual la deja, la
    // guardamos como nota libre adicional.
    final description = _descriptionController.text.trim();

    final reasonCode = _selectedReasonCode;
    if (reasonCode == null || reasonCode.isEmpty) {
      AppToast.warning(context, 'Selecciona una razón antes de continuar');
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      // Vía viewmodel: si no hay red, encola el movimiento (cash_transaction)
      // en vez de perderlo. `appliedOnline=false` → quedó offline.
      final appliedOnline = await ref
          .read(cashierViewModelProvider)
          .createManualTransaction(
            sessionId: data.session.id,
            amount: amount,
            type: _selectedType,
            reasonCode: reasonCode,
            description: description.isEmpty ? null : description,
          );

      // Sprint Caja Pro — Print receipt fire-and-forget. Si falla la
      // impresión NO bloqueamos el flujo: el movimiento ya quedó
      // registrado en BD. Solo logueamos.
      final reasonLabel = data.reasons
          .firstWhere(
            (r) => r['code'] == reasonCode,
            orElse: () => <String, dynamic>{'label': reasonCode},
          )['label']
          ?.toString();
      _printMovementReceipt(
        movementType: _selectedType,
        amount: amount,
        reasonLabel: reasonLabel ?? reasonCode,
        description: description.isEmpty ? null : description,
        sessionId: data.session.id,
      );

      _amountController.clear();
      _descriptionController.clear();
      setState(() => _selectedReasonCode = null);
      await _refresh();

      if (!mounted) return;
      if (appliedOnline) {
        AppToast.success(
          context,
          '${_labelForType(_selectedType)} registrado correctamente',
        );
      } else {
        AppToast.warning(
          context,
          '${_labelForType(_selectedType)} guardado sin conexión. Se sincronizará al reconectar.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'No se pudo registrar el movimiento: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('Ingresos y Egresos'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go(AppRoutes.cashier),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<_ManualCashData?>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            if (snapshot.hasError) {
              return _InfoState(
                icon: Icons.error_outline,
                title: 'No se pudo cargar la caja',
                subtitle: '${snapshot.error}',
              );
            }

            final data = snapshot.data;
            if (data == null) {
              return const _InfoState(
                icon: Icons.lock_outline,
                title: 'No hay una caja abierta',
                subtitle:
                    'Debes aperturar una caja antes de registrar ingresos o egresos.',
              );
            }

            final deposits = data.transactions
                .where((tx) => tx.type == 'deposit')
                .fold<double>(0, (sum, tx) => sum + tx.amount);
            final withdrawals = data.transactions
                .where((tx) => tx.type == 'withdrawal')
                .fold<double>(0, (sum, tx) => sum + tx.amount);
            final expenses = data.transactions
                .where((tx) => tx.type == 'expense')
                .fold<double>(0, (sum, tx) => sum + tx.amount);

            final isMobile = ResponsiveHelper.isMobile(context);
            final pad = isMobile ? 12.0 : 24.0;
            return ListView(
              padding: EdgeInsets.all(pad),
              children: [
                LayoutBuilder(
                  builder: (context, c) {
                    // En móvil: 3 cards en una fila con Expanded; en
                    // tablet/desktop: Wrap con ancho fijo 240.
                    if (isMobile) {
                      return Row(
                        children: [
                          Expanded(
                            child: _MetricCard(
                              title: 'Depósitos',
                              value: deposits,
                              color: MangoColors.successGreen,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _MetricCard(
                              title: 'Retiros',
                              value: withdrawals,
                              color: MangoColors.primaryOrange,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _MetricCard(
                              title: 'Gastos',
                              value: expenses,
                              color: Colors.red,
                            ),
                          ),
                        ],
                      );
                    }
                    return Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: [
                        _MetricCard(
                          title: 'Depósitos',
                          value: deposits,
                          color: MangoColors.successGreen,
                        ),
                        _MetricCard(
                          title: 'Retiros',
                          value: withdrawals,
                          color: MangoColors.primaryOrange,
                        ),
                        _MetricCard(
                          title: 'Gastos',
                          value: expenses,
                          color: Colors.red,
                        ),
                      ],
                    );
                  },
                ),
                SizedBox(height: isMobile ? 14 : 24),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth > 980;
                    if (isWide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: _buildForm(data)),
                          const SizedBox(width: 24),
                          Expanded(flex: 6, child: _buildList(data)),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        _buildForm(data),
                        SizedBox(height: isMobile ? 14 : 24),
                        _buildList(data),
                      ],
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Sprint Caja Pro — Imprime el recibo del movimiento que acabamos
  /// de registrar. Resuelve la impresora vinculada a la caja registradora
  /// (`cash_registers.receipt_printer_id`) y, si no existe, busca una
  /// del área `cashier`/`fiscal` como fallback. Fire-and-forget: si la
  /// impresión falla no bloqueamos al cajero, el movimiento ya quedó
  /// guardado.
  Future<void> _printMovementReceipt({
    required String movementType,
    required double amount,
    required String reasonLabel,
    String? description,
    required String sessionId,
  }) async {
    try {
      final cashierVm = ref.read(cashierViewModelProvider);
      final registerId = cashierVm.currentRegisterId;
      final repo = ref.read(printingPrintersRepositoryProvider);

      // 1. Impresora asignada al cash_register.
      var printer = registerId == null
          ? null
          : await ref.read(cashierRepositoryProvider).getRegisterPrinterId(registerId)
              .then((pid) async => pid == null
                  ? null
                  : await repo.getPrinter(pid));

      // 2. Fallback: impresora de área cashier/fiscal.
      if (printer == null) {
        final session = ref.read(sessionProvider);
        final businessId = session.activeBusinessId;
        if (businessId == null || businessId.isEmpty) return;
        printer = await repo.getAssignedPrinterForType(
          businessId: businessId,
          preferredAreaCodes: const ['cashier', 'fiscal'],
          printsPrebills: false,
          printsReceipts: true,
        );
      }
      if (printer == null) return;

      // 3. Generar y mandar.
      final session = ref.read(sessionProvider);
      final businessName = (session.activeBusinessName ?? 'MangoPOS').trim();
      final cashierName = session.userName ?? '';

      final ticket = PrintTicketService.generateCashMovementReceipt(
        businessName: businessName.isEmpty ? 'MangoPOS' : businessName,
        movementType: movementType,
        amount: amount,
        reasonLabel: reasonLabel,
        description: description,
        cashierName: cashierName,
        sessionId: sessionId,
        when: DateTime.now(),
      );

      await repo.printEscPos(
        printer: printer,
        data: ticket.escPosCommands,
        kind: 'cash_movement',
        areaCode: 'cashier',
        idempotencyKey: 'cashmov-$sessionId-${DateTime.now().millisecondsSinceEpoch}',
      );
    } catch (e) {
      // Fire-and-forget: solo logueamos.
      debugPrint('[CashMovement] recibo no impreso: $e');
    }
  }

  /// Sprint Caja Pro — Razón obligatoria. La validación final está en
  /// la RPC (`fn_cash_transaction_create`) — acá solo filtramos las
  /// razones del catálogo que aplican al tipo seleccionado.
  Widget _buildReasonDropdown(_ManualCashData data) {
    final filtered = data.reasons
        .where((r) =>
            r['applies_to'] == null ||
            r['applies_to'] == _selectedType)
        .toList(growable: false);

    if (filtered.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEB),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFFDE68A)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'No hay razones configuradas para este tipo de movimiento. '
              'Configúralas (o pídele al admin) en '
              'Ajustes → Razones de Ingresos y Egresos.',
              style: TextStyle(fontSize: 12, color: Color(0xFF92400E)),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => context.go(AppRoutes.settingsCashReasons),
                icon: const Icon(Icons.settings, size: 16),
                label: const Text('Ir a configurar'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF92400E),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        ),
      );
    }

    // Si la razón seleccionada no aplica al tipo actual, la limpiamos.
    final stillValid = _selectedReasonCode != null &&
        filtered.any((r) => r['code'] == _selectedReasonCode);
    if (_selectedReasonCode != null && !stillValid) {
      // Diferir el reset al próximo frame para no llamar setState en build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedReasonCode = null);
      });
    }

    return DropdownButtonFormField<String>(
      initialValue: stillValid ? _selectedReasonCode : null,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Razón del movimiento',
        helperText: 'Obligatorio para auditoría',
        border: OutlineInputBorder(),
      ),
      items: filtered.map((r) {
        final requiresPin = r['requires_pin'] == true;
        return DropdownMenuItem<String>(
          value: r['code']?.toString(),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  r['label']?.toString() ?? r['code']?.toString() ?? '',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (requiresPin)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: Color(0xFFEA580C),
                  ),
                ),
            ],
          ),
        );
      }).toList(),
      onChanged: (v) => setState(() => _selectedReasonCode = v),
    );
  }

  Widget _buildForm(_ManualCashData data) {
    // Permiso de escritura. Si el usuario no lo tiene (típicamente un
    // cajero sin acceso a movimientos), mostramos un aviso bloqueante
    // en vez del formulario. La lista de movimientos sí sigue visible
    // — el cajero puede consultarlos.
    final canCreate = ref
        .read(sessionProvider.notifier)
        .hasPermission('caja.movimientos_crear');

    if (!canCreate) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7ED),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.lock_outline,
                color: MangoColors.primaryOrange,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Solo lectura',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'No tenés permiso para registrar depósitos, retiros o '
                    'gastos. Pedile a un supervisor o administrador que '
                    'haga el movimiento. Sí podés ver los movimientos '
                    'existentes abajo.',
                    style: TextStyle(
                      fontSize: 12,
                      color: MangoColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final isMobile = ResponsiveHelper.isMobile(context);
    return Container(
      padding: EdgeInsets.all(isMobile ? 14 : 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Registrar movimiento',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: isMobile ? 16 : null,
                ),
          ),
          SizedBox(height: isMobile ? 4 : 6),
          Text(
            'Sesión ${data.session.id.substring(0, 8).toUpperCase()} abierta el ${DateFormat('dd/MM/yyyy HH:mm').format(AppTime.astFromInstant(data.session.openedAt))}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: isMobile ? 11 : 13,
            ),
          ),
          SizedBox(height: isMobile ? 14 : 20),
          SegmentedButton<String>(
            // En móvil ocultamos los íconos para que entren las 3 segments.
            segments: [
              ButtonSegment(
                value: 'deposit',
                label: const Text('Ingreso'),
                icon: isMobile ? null : const Icon(Icons.south_west),
              ),
              ButtonSegment(
                value: 'withdrawal',
                label: const Text('Retiro'),
                icon: isMobile ? null : const Icon(Icons.north_east),
              ),
              ButtonSegment(
                value: 'expense',
                label: const Text('Gasto'),
                icon: isMobile ? null : const Icon(Icons.money_off),
              ),
            ],
            selected: {_selectedType},
            onSelectionChanged: (selection) {
              setState(() {
                _selectedType = selection.first;
                _selectedReasonCode = null;
              });
            },
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Monto',
              hintText: '0.00',
              prefixText: 'RD\$ ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          // Sprint Caja Pro — razón obligatoria.
          _buildReasonDropdown(data),
          const SizedBox(height: 16),
          TextField(
            controller: _descriptionController,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Descripción (opcional)',
              hintText: _hintForType(_selectedType),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isSubmitting ? null : () => _submit(data),
              style: ElevatedButton.styleFrom(
                backgroundColor: _colorForType(_selectedType),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              icon: _isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(_iconForType(_selectedType)),
              label: Text(
                _isSubmitting
                    ? 'Guardando...'
                    : 'Registrar ${_labelForType(_selectedType)}',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(_ManualCashData data) {
    final isMobile = ResponsiveHelper.isMobile(context);
    return Container(
      padding: EdgeInsets.all(isMobile ? 14 : 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isMobile
                ? 'Movimientos de la sesión'
                : 'Movimientos manuales de la sesión',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: isMobile ? 15 : null,
                ),
          ),
          SizedBox(height: isMobile ? 12 : 16),
          if (data.transactions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('Aún no hay ingresos o egresos manuales.'),
              ),
            )
          else
            ...data.transactions.map(
              (tx) => _ManualMovementTile(transaction: tx),
            ),
        ],
      ),
    );
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'deposit':
        return MangoColors.successGreen;
      case 'withdrawal':
        return MangoColors.primaryOrange;
      case 'expense':
        return const Color(0xFFDC2626);
      default:
        return MangoColors.primaryOrange;
    }
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'deposit':
        return Icons.south_west;
      case 'withdrawal':
        return Icons.north_east;
      case 'expense':
        return Icons.money_off;
      default:
        return Icons.receipt_long;
    }
  }

  String _labelForType(String type) {
    switch (type) {
      case 'deposit':
        return 'ingreso';
      case 'withdrawal':
        return 'retiro';
      case 'expense':
        return 'gasto';
      default:
        return 'movimiento';
    }
  }

  String _hintForType(String type) {
    switch (type) {
      case 'deposit':
        return 'Ej: fondo adicional, reposición de caja';
      case 'withdrawal':
        return 'Ej: retiro parcial, traslado a bóveda';
      case 'expense':
        return 'Ej: compra de hielo, limpieza, mensajería';
      default:
        return 'Describe el movimiento';
    }
  }
}

class _ManualCashData {
  final CashRegisterSession session;
  final List<CashTransaction> transactions;
  final List<Map<String, dynamic>> reasons;
  final String businessId;

  const _ManualCashData({
    required this.session,
    required this.transactions,
    required this.reasons,
    required this.businessId,
  });
}

class _MetricCard extends StatelessWidget {
  final String title;
  final double value;
  final Color color;

  const _MetricCard({
    required this.title,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final isMobile = ResponsiveHelper.isMobile(context);
    return Container(
      width: isMobile ? null : 240,
      padding: EdgeInsets.all(isMobile ? 10 : 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: isMobile ? 6 : 8,
              vertical: isMobile ? 4 : 8,
            ),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: isMobile ? 10 : 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ),
          SizedBox(height: isMobile ? 8 : 16),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              NumberFormat.currency(
                symbol: 'RD\$ ',
                decimalDigits: isMobile ? 0 : 2,
              ).format(value),
              maxLines: 1,
              style: TextStyle(
                fontSize: isMobile ? 15 : 22,
                fontWeight: FontWeight.w900,
                color: MangoColors.darkGray,
                letterSpacing: -0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualMovementTile extends StatelessWidget {
  final CashTransaction transaction;

  const _ManualMovementTile({required this.transaction});

  @override
  Widget build(BuildContext context) {
    final isDeposit = transaction.type == 'deposit';
    final color = switch (transaction.type) {
      'deposit' => Colors.blue,
      'withdrawal' => const Color(0xFFF97316),
      'expense' => Colors.red,
      _ => Colors.grey,
    };

    final isMobile = ResponsiveHelper.isMobile(context);
    return Container(
      margin: EdgeInsets.only(bottom: isMobile ? 8 : 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.1)),
      ),
      child: ListTile(
        contentPadding: EdgeInsets.symmetric(
          horizontal: isMobile ? 10 : 16,
          vertical: isMobile ? 0 : 4,
        ),
        dense: isMobile,
        visualDensity:
            isMobile ? VisualDensity.compact : VisualDensity.standard,
        leading: Container(
          padding: EdgeInsets.all(isMobile ? 7 : 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(
            switch (transaction.type) {
              'deposit' => Icons.arrow_downward_rounded,
              'withdrawal' => Icons.arrow_upward_rounded,
              'expense' => Icons.shopping_bag_outlined,
              _ => Icons.receipt_long,
            },
            color: color,
            size: isMobile ? 16 : 20,
          ),
        ),
        title: Text(
          transaction.description ?? 'Movimiento',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: MangoColors.darkGray,
            fontSize: isMobile ? 13 : 14,
          ),
        ),
        subtitle: Text(
          '${DateFormat('dd MMM hh:mm a').format(AppTime.astFromInstant(transaction.createdAt))} · ${_typeLabel(transaction.type)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: isMobile ? 10.5 : 12,
            color: MangoColors.muted,
          ),
        ),
        trailing: Text(
          '${isDeposit ? '+' : '-'}RD\$ ${transaction.amount.toStringAsFixed(isMobile ? 0 : 2)}',
          style: TextStyle(
            fontWeight: FontWeight.w900,
            fontSize: isMobile ? 13 : 16,
            color: color,
          ),
        ),
      ),
    );
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'deposit':
        return 'Ingreso';
      case 'withdrawal':
        return 'Retiro';
      case 'expense':
        return 'Gasto';
      default:
        return type;
    }
  }
}

class _InfoState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _InfoState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFF5F5F7),
      child: Center(
        child: Container(
          margin: const EdgeInsets.all(40),
          padding: const EdgeInsets.all(48),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(32),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          constraints: const BoxConstraints(maxWidth: 450),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: MangoColors.primaryOrange.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 56, color: MangoColors.primaryOrange),
              ),
              const SizedBox(height: 32),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: MangoColors.darkGray,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: MangoColors.muted,
                  fontSize: 16,
                  height: 1.5,
                ),
              ),
              if (icon == Icons.lock_outline) ...[
                const SizedBox(height: 40),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => context.go(AppRoutes.cashier),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: MangoColors.primaryOrange,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Ir a Apertura de Caja',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
