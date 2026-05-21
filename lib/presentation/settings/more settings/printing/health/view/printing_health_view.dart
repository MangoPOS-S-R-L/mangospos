// Sprint 5 — Pantalla "Salud de impresión".
//
// Muestra al admin en una sola vista:
//   1. Banner naranja arriba si hay jobs failed terminales (>=5 retries).
//   2. Sección "Estado de impresoras" — cards con semáforo:
//        🟢 verde   — operativa, sin jobs en cola.
//        🟡 amarillo — en cola, heartbeat algo viejo, o failed transitorios.
//        🔴 rojo    — offline o jobs terminales.
//   3. Sección "Cola pendiente" — lista de jobs activos con acciones:
//        - Reintentar  → resetea retry_count y status='pending'.
//        - Cancelar    → status='cancelled' (el cajero reimprime manual).
//
// Realtime: el ViewModel se suscribe a print_jobs + printers del
// business. Cualquier cambio dispara refresh (con debounce 500ms).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:mangopos/app/router/routes.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

import '../state/printing_health_state.dart';
import '../viewmodel/printing_health_viewmodel.dart';

class PrintingHealthView extends ConsumerStatefulWidget {
  const PrintingHealthView({super.key, this.businessId = 'auto'});

  final String businessId;

  @override
  ConsumerState<PrintingHealthView> createState() => _PrintingHealthViewState();
}

class _PrintingHealthViewState extends ConsumerState<PrintingHealthView> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref
          .read(printingHealthViewModelProvider.notifier)
          .initialize(businessId: widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(printingHealthViewModelProvider);
    final vm = ref.read(printingHealthViewModelProvider.notifier);

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        backgroundColor: MangoColors.white,
        foregroundColor: MangoColors.darkGray,
        elevation: 0.6,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Regresar',
          onPressed: () => Navigator.of(context).canPop()
              ? Navigator.of(context).pop()
              : context.go(AppRoutes.printingBase),
        ),
        title: const Text('Salud de impresión'),
      ),
      body: RefreshIndicator(
        color: MangoColors.primaryOrange,
        onRefresh: vm.refresh,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (state.terminalFailedJobsCount > 0)
              _AlertBanner(count: state.terminalFailedJobsCount),
            if (state.terminalFailedJobsCount > 0) const SizedBox(height: 20),

            _SummaryRow(state: state),
            const SizedBox(height: 24),

            const _SectionTitle('Estado de impresoras'),
            const SizedBox(height: 12),
            if (state.loading && state.printers.isEmpty)
              const _LoadingBlock()
            else if (state.printers.isEmpty)
              const _EmptyTile('No hay impresoras configuradas.')
            else
              ...state.printers.map((p) => _PrinterHealthCard(printer: p)),

            const SizedBox(height: 28),

            const _SectionTitle('Cola pendiente'),
            const SizedBox(height: 12),
            if (state.activeJobs.isEmpty && !state.loading)
              const _EmptyTile(
                'No hay tickets pendientes. Todo imprimió directo.',
              )
            else
              ...state.activeJobs.map(
                (j) => _PrintJobRow(
                  job: j,
                  onRetry: () => vm.retryJob(j.id),
                  onCancel: () => vm.cancelJob(j.id),
                ),
              ),

            const SizedBox(height: 24),
            if (state.lastUpdatedAt != null)
              Center(
                child: Text(
                  'Última actualización: ${_formatTime(state.lastUpdatedAt!)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: MangoColors.muted,
                  ),
                ),
              ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: Text(
                    'Aviso: ${state.error!}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFB91C1C),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}

// ─── Widgets ───────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w800,
        color: MangoColors.darkGray,
      ),
    );
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
              '$count ticket${count == 1 ? '' : 's'} no pudo imprimirse tras '
              '5 intentos. Revisa la cola debajo y elige reintentar o '
              'cancelar.',
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

class _SummaryRow extends StatelessWidget {
  final PrintingHealthState state;
  const _SummaryRow({required this.state});

  @override
  Widget build(BuildContext context) {
    final ok = state.printers
        .where((p) => p.level == PrinterHealthLevel.ok)
        .length;
    final warn = state.printers
        .where((p) => p.level == PrinterHealthLevel.warning)
        .length;
    final down = state.printers
        .where((p) => p.level == PrinterHealthLevel.down)
        .length;
    return Row(
      children: [
        Expanded(
          child: _SummaryTile(
            label: 'Operativas',
            value: ok,
            color: MangoColors.successGreen,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SummaryTile(
            label: 'Con atención',
            value: warn,
            color: const Color(0xFFF59E0B),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SummaryTile(
            label: 'Sin respuesta',
            value: down,
            color: const Color(0xFFEF4444),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _SummaryTile(
            label: 'En cola',
            value: state.jobsInFlight,
            color: MangoColors.primaryOrange,
          ),
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  final String label;
  final int value;
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
            '$value',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(fontSize: 12, color: MangoColors.muted),
          ),
        ],
      ),
    );
  }
}

class _PrinterHealthCard extends StatelessWidget {
  final PrinterHealth printer;
  const _PrinterHealthCard({required this.printer});

  Color _bgColor() {
    switch (printer.level) {
      case PrinterHealthLevel.ok:
        return const Color(0xFFEFFDF4);
      case PrinterHealthLevel.warning:
        return const Color(0xFFFFFBEB);
      case PrinterHealthLevel.down:
        return const Color(0xFFFEF2F2);
    }
  }

  Color _borderColor() {
    switch (printer.level) {
      case PrinterHealthLevel.ok:
        return MangoColors.successGreen;
      case PrinterHealthLevel.warning:
        return const Color(0xFFF59E0B);
      case PrinterHealthLevel.down:
        return const Color(0xFFEF4444);
    }
  }

  String _statusLabel() {
    // Slice C: si el agent reportó status granular, mostrarlo — es más
    // específico que el agregado (no_paper > "Con atención").
    final granular = printer.granularStatusLabel;
    if (granular != null) return granular;
    switch (printer.level) {
      case PrinterHealthLevel.ok:
        return 'Operativa';
      case PrinterHealthLevel.warning:
        return 'Con atención';
      case PrinterHealthLevel.down:
        return printer.online ? 'Tickets sin imprimir' : 'Sin respuesta';
    }
  }

  String _formatLastSeen() {
    final ls = printer.lastSeen;
    if (ls == null) return 'Sin heartbeat';
    final age = DateTime.now().toUtc().difference(ls.toUtc());
    if (age.inSeconds < 60) return 'Hace ${age.inSeconds}s';
    if (age.inMinutes < 60) return 'Hace ${age.inMinutes}m';
    if (age.inHours < 24) return 'Hace ${age.inHours}h';
    return 'Hace ${age.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final dotColor = _borderColor();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _bgColor(),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _borderColor()),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 14,
            height: 14,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        printer.name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: MangoColors.darkGray,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: dotColor,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _statusLabel(),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${printer.type.toUpperCase()} · Heartbeat: ${_formatLastSeen()}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: MangoColors.muted,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (printer.printingCount > 0)
                      _MiniChip(
                        label: 'Imprimiendo: ${printer.printingCount}',
                        color: MangoColors.primaryOrange,
                      ),
                    if (printer.pendingCount > 0)
                      _MiniChip(
                        label: 'En cola: ${printer.pendingCount}',
                        color: const Color(0xFFF59E0B),
                      ),
                    if (printer.failedCount > 0)
                      _MiniChip(
                        label: 'Fallidos: ${printer.failedCount}',
                        color: const Color(0xFFEF4444),
                      ),
                    if (printer.fallbackPrinterId != null)
                      const _MiniChip(
                        label: 'Tiene respaldo',
                        color: MangoColors.successGreen,
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

class _MiniChip extends StatelessWidget {
  final String label;
  final Color color;
  const _MiniChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }
}

class _PrintJobRow extends StatelessWidget {
  final PrintJobRow job;
  final Future<void> Function() onRetry;
  final Future<void> Function() onCancel;
  const _PrintJobRow({
    required this.job,
    required this.onRetry,
    required this.onCancel,
  });

  String _statusLabel() {
    if (job.isTerminalFailed) return 'No imprimió (5 intentos)';
    if (job.isPendingRetry) {
      final next = job.nextRetryAt;
      if (next != null) {
        final delta = next.difference(DateTime.now());
        if (delta.isNegative) return 'Listo para reintentar';
        return 'Reintenta en ${delta.inSeconds}s';
      }
      return 'Pendiente de reintento';
    }
    if (job.status == 'printing') return 'Imprimiendo';
    if (job.status == 'pending') return 'En cola';
    return job.status;
  }

  Color _statusColor() {
    if (job.isTerminalFailed) return const Color(0xFFEF4444);
    if (job.isPendingRetry) return const Color(0xFFF59E0B);
    if (job.status == 'printing') return MangoColors.primaryOrange;
    return MangoColors.muted;
  }

  String _kindLabel() {
    switch (job.kind) {
      case 'kitchen_order':
        return 'Comanda';
      case 'precheck':
        return 'Precuenta';
      case 'invoice':
        return 'Factura';
      case 'cash_close':
        return 'Cierre de caja';
      default:
        return job.kind?.toUpperCase() ?? 'OTRO';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: MangoColors.cardBorder),
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
                  color: _statusColor(),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${_kindLabel()} · ${job.printerName ?? job.areaCode ?? 'Sin destino'}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: MangoColors.darkGray,
                  ),
                ),
              ),
              Text(
                _statusLabel(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _statusColor(),
                ),
              ),
            ],
          ),
          if (job.lastError != null && job.lastError!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 18),
              child: Text(
                job.lastError!,
                style: const TextStyle(fontSize: 11, color: MangoColors.muted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 18),
            child: Row(
              children: [
                Text(
                  'Intentos: ${job.retryCount}/5'
                  '${job.failoverCount > 0 ? ' · Pasó a respaldo' : ''}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: MangoColors.muted,
                  ),
                ),
                const Spacer(),
                if (job.isTerminalFailed || job.isPendingRetry) ...[
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('Reintentar'),
                    style: TextButton.styleFrom(
                      foregroundColor: MangoColors.primaryOrange,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close, size: 14),
                    label: const Text('Cancelar'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFEF4444),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      visualDensity: VisualDensity.compact,
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

class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation(MangoColors.primaryOrange),
        ),
      ),
    );
  }
}

class _EmptyTile extends StatelessWidget {
  final String text;
  const _EmptyTile(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MangoColors.cardBorder),
      ),
      child: Text(
        text,
        style: const TextStyle(fontSize: 13, color: MangoColors.muted),
      ),
    );
  }
}
