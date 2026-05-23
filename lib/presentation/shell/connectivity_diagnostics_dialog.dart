import 'package:flutter/material.dart';

import 'package:mangopos/core/network/connectivity_service.dart';

/// Dialog de troubleshooting para cuando el banner "Sin conexion" aparece
/// pero el cajero esta seguro de que tiene internet. Muestra el estado
/// crudo del [ConnectivityService] y permite forzar un probe ad-hoc para
/// ver exactamente que URL fallo, con que status y que mensaje.
class ConnectivityDiagnosticsDialog extends StatefulWidget {
  const ConnectivityDiagnosticsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => const ConnectivityDiagnosticsDialog(),
    );
  }

  @override
  State<ConnectivityDiagnosticsDialog> createState() =>
      _ConnectivityDiagnosticsDialogState();
}

class _ConnectivityDiagnosticsDialogState
    extends State<ConnectivityDiagnosticsDialog> {
  final ConnectivityService _svc = ConnectivityService();
  bool _probing = false;

  Future<void> _forceProbe() async {
    setState(() => _probing = true);
    try {
      await _svc.forceReachabilityCheck();
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  String _formatDuration(Duration? d) {
    if (d == null) return '—';
    final ms = d.inMilliseconds;
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(2)}s';
  }

  String _formatDateTime(DateTime? d) {
    if (d == null) return 'nunca';
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    final s = d.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  Widget _kv(String key, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              key,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                color: valueColor ?? const Color(0xFF111827),
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _svc.diagnostics;
    final connectedColor = d.isConnected
        ? const Color(0xFF22C55E)
        : const Color(0xFFEF4444);

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.wifi_find_outlined, color: Color(0xFF3B82F6)),
          SizedBox(width: 8),
          Expanded(child: Text('Diagnostico de conectividad')),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: connectedColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: connectedColor.withValues(alpha: 0.35),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    d.isConnected
                        ? Icons.cloud_done_rounded
                        : Icons.cloud_off_rounded,
                    color: connectedColor,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      d.isConnected
                          ? 'Connectivity service dice ONLINE'
                          : 'Connectivity service dice OFFLINE',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: connectedColor,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Estado actual',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 4),
            _kv('Adapter (wifi/eth)', d.adapterUp ? 'UP' : 'DOWN',
                valueColor:
                    d.adapterUp ? const Color(0xFF22C55E) : const Color(0xFFEF4444)),
            _kv('Supabase reachable', d.reachable ? 'YES' : 'NO',
                valueColor:
                    d.reachable ? const Color(0xFF22C55E) : const Color(0xFFEF4444)),
            _kv('Fallos consecutivos', '${d.failedProbes}'),
            _kv('Supabase URL', d.supabaseUrl),
            const SizedBox(height: 12),
            const Text(
              'Ultimo probe',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 4),
            _kv('Cuando', _formatDateTime(d.lastProbeAt)),
            _kv('URL probada', d.lastProbeUrl ?? '—'),
            _kv(
              'HTTP status',
              d.lastProbeStatus?.toString() ?? '— (sin respuesta)',
              valueColor: d.lastProbeStatus == null
                  ? const Color(0xFFEF4444)
                  : d.lastProbeStatus! < 500
                      ? const Color(0xFF22C55E)
                      : const Color(0xFFEF4444),
            ),
            _kv('Duracion', _formatDuration(d.lastProbeDuration)),
            if (d.lastProbeError != null)
              _kv(
                'Error',
                d.lastProbeError!,
                valueColor: const Color(0xFFEF4444),
              ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'Tip: el probe acepta cualquier status < 500 (incluso 401/404) '
                'como "alcanzable". Solo timeouts y 5xx cuentan como falla. '
                'Si las URLs de arriba responden en el browser pero aqui dicen '
                'falla → revisa firewall/antivirus que pueda bloquear el '
                'cliente HTTP nativo del app.',
                style: TextStyle(fontSize: 11, color: Color(0xFF92400E)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _probing ? null : _forceProbe,
          icon: _probing
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          label: Text(_probing ? 'Probando...' : 'Forzar probe ahora'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}
