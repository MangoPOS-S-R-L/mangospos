import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/performance/performance_diagnostics.dart';

class PerformanceDiagnosticsDialog extends StatefulWidget {
  const PerformanceDiagnosticsDialog({super.key});

  @override
  State<PerformanceDiagnosticsDialog> createState() =>
      _PerformanceDiagnosticsDialogState();
}

class _PerformanceDiagnosticsDialogState
    extends State<PerformanceDiagnosticsDialog> {
  String _role = 'caja';

  @override
  Widget build(BuildContext context) {
    final diagnostics = PerformanceDiagnostics.instance;
    return AnimatedBuilder(
      animation: diagnostics,
      builder: (context, _) => AlertDialog(
        title: const Text('Diagnóstico de rendimiento'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Inicia la medición, abre mesas y completa algunas ventas. '
                  'Deténla para comparar este equipo con otro. '
                  'No se guardan clientes, pedidos ni importes.',
                ),
                const SizedBox(height: 12),
                DropdownButton<String>(
                  value: _role,
                  onChanged: diagnostics.isRunning
                      ? null
                      : (value) {
                          if (value != null) setState(() => _role = value);
                        },
                  items: const [
                    DropdownMenuItem(
                      value: 'caja',
                      child: Text('Equipo: caja'),
                    ),
                    DropdownMenuItem(
                      value: 'mesero',
                      child: Text('Equipo: mesero'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'CPU en Windows: usa tools/perf/measure-windows.ps1 durante '
                  'la misma sesión. Este panel mide memoria, fluidez y tiempos.',
                ),
                const SizedBox(height: 16),
                if (diagnostics.hasReport)
                  SelectableText(
                    diagnostics.reportText,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  )
                else
                  const Text('Sin medición activa.'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
          if (diagnostics.hasReport)
            TextButton.icon(
              onPressed: () => Clipboard.setData(
                ClipboardData(text: diagnostics.reportText),
              ),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('Copiar reporte'),
            ),
          FilledButton.icon(
            onPressed: diagnostics.isRunning
                ? diagnostics.stop
                : () => diagnostics.start(role: _role),
            icon: Icon(diagnostics.isRunning ? Icons.stop : Icons.play_arrow),
            label: Text(diagnostics.isRunning ? 'Detener' : 'Iniciar'),
          ),
        ],
      ),
    );
  }
}
