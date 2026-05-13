// Widget de saldo de caja en vivo (Sprint Caja Profesional - Fase B).
//
// Aparece arriba del sidebar de ventas cuando la caja está abierta.
// Muestra el saldo esperado actual en grande y, al hacer click, abre
// un modal con desglose completo (apertura + ventas + depósitos −
// retiros − gastos).
//
// Refresca automáticamente cada 30s vía Future polling para reflejar
// cambios sin requerir push realtime. Si el cajero acaba de cobrar,
// también puede invocar refreshSilently desde fuera.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';

class LiveCashBalanceCard extends ConsumerStatefulWidget {
  const LiveCashBalanceCard({super.key, this.compact = false});

  /// Modo compacto para sidebar angosto: solo muestra el saldo, sin label.
  final bool compact;

  @override
  ConsumerState<LiveCashBalanceCard> createState() =>
      _LiveCashBalanceCardState();
}

class _LiveCashBalanceCardState extends ConsumerState<LiveCashBalanceCard> {
  Timer? _poll;
  Map<String, dynamic>? _summary;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _fetch());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final cashierVm = ref.read(cashierViewModelProvider);
    final sessionId = cashierVm.lastSession?['id']?.toString();
    if (sessionId == null || cashierVm.lastSession?['status'] != 'open') {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final repo = ref.read(cashierRepositoryProvider);
      final summary = await repo.getSessionSummary(sessionId);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  double _num(String key) {
    final v = _summary?[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  String _formatMoney(double v) {
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

  @override
  Widget build(BuildContext context) {
    final cashierVm = ref.watch(cashierViewModelProvider);
    if (!cashierVm.isCashOpen) return const SizedBox.shrink();

    // Mientras carga, muestra placeholder con apertura conocida del
    // viewmodel para no titilar.
    if (_loading || _summary == null) {
      final start = (cashierVm.lastSession?['start_amount'] as num?)
              ?.toDouble() ??
          0;
      return _Shell(
        compact: widget.compact,
        title: 'Saldo en caja',
        amount: _formatMoney(start),
        subtitle: 'Cargando…',
        onTap: _showBreakdown,
      );
    }

    final expected = _num('expected_amount');
    final ventas = _num('cash_sales_net');
    final depositos = _num('total_deposits');
    final retiros = _num('total_withdrawals');
    final gastos = _num('total_expenses');
    final movs = (ventas + depositos - retiros - gastos);

    return _Shell(
      compact: widget.compact,
      title: 'Saldo en caja',
      amount: _formatMoney(expected),
      subtitle: movs == 0
          ? 'Sin movimientos aún'
          : '${movs >= 0 ? '+' : ''}${_formatMoney(movs)} hoy',
      onTap: _showBreakdown,
    );
  }

  void _showBreakdown() {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final start = _num('start_amount');
        final ventas = _num('cash_sales_net');
        final depositos = _num('total_deposits');
        final retiros = _num('total_withdrawals');
        final gastos = _num('total_expenses');
        final esperado = _num('expected_amount');

        return Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            width: 460,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.account_balance_wallet,
                        color: MangoColors.primaryOrange, size: 28),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Desglose de caja',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: MangoColors.darkGray,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'En vivo desde la apertura. Cambia con cada movimiento.',
                  style: TextStyle(fontSize: 12, color: MangoColors.muted),
                ),
                const SizedBox(height: 20),
                _BreakdownRow(label: 'Apertura',         amount: start,     sign: '+'),
                _BreakdownRow(label: 'Ventas efectivo',  amount: ventas,    sign: '+'),
                _BreakdownRow(label: 'Depósitos',        amount: depositos, sign: '+'),
                _BreakdownRow(label: 'Retiros',          amount: retiros,   sign: '−', isOut: true),
                _BreakdownRow(label: 'Gastos',           amount: gastos,    sign: '−', isOut: true),
                const Divider(height: 28, thickness: 1),
                Row(
                  children: [
                    const Text(
                      'Esperado en caja',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: MangoColors.darkGray,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatMoney(esperado),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        color: MangoColors.primaryOrange,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7ED),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFED7AA)),
                  ),
                  child: const Text(
                    'Este es el efectivo que debería haber en la caja '
                    'ahora mismo. Si contás algo distinto al cerrar, '
                    'el sistema registrará la diferencia.',
                    style: TextStyle(fontSize: 11, color: Color(0xFF92400E)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Shell extends StatelessWidget {
  final bool compact;
  final String title;
  final String amount;
  final String subtitle;
  final VoidCallback onTap;

  const _Shell({
    required this.compact,
    required this.title,
    required this.amount,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Toca para ver el desglose',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          margin: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFFEDD5), Color(0xFFFED7AA)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: MangoColors.primaryOrange.withValues(alpha: 0.5),
            ),
          ),
          child: compact
              ? Center(
                  child: Text(
                    amount,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF9A3412),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF9A3412),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      amount,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF7C2D12),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF9A3412),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final double amount;
  final String sign;
  final bool isOut;
  const _BreakdownRow({
    required this.label,
    required this.amount,
    required this.sign,
    this.isOut = false,
  });

  String _fmt(double v) {
    final whole = v.truncate();
    final decimals = ((v - whole) * 100).round().toString().padLeft(2, '0');
    final wholeStr = whole.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
          (m) => '${m[1]},',
        );
    return 'RD\$ $wholeStr.$decimals';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text(
              sign,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: isOut
                    ? const Color(0xFFEF4444)
                    : MangoColors.successGreen,
              ),
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                color: MangoColors.darkGray,
              ),
            ),
          ),
          Text(
            _fmt(amount),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: isOut
                  ? const Color(0xFFEF4444)
                  : MangoColors.darkGray,
            ),
          ),
        ],
      ),
    );
  }
}
