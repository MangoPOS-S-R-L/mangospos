import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';

Future<bool?> showPrinterConfigurationDialog(
  BuildContext context, {
  required PrinterDevice printer,
  required PrintingPrintersViewModel vmCtrl,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) =>
        _PrinterConfigurationDialog(printer: printer, vmCtrl: vmCtrl),
  );
}

class _PrinterConfigurationDialog extends ConsumerStatefulWidget {
  const _PrinterConfigurationDialog({
    required this.printer,
    required this.vmCtrl,
  });

  final PrinterDevice printer;
  final PrintingPrintersViewModel vmCtrl;

  @override
  ConsumerState<_PrinterConfigurationDialog> createState() =>
      _PrinterConfigurationDialogState();
}

class _PrinterConfigurationDialogState
    extends ConsumerState<_PrinterConfigurationDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _ipCtrl;
  late final TextEditingController _macCtrl;
  late final TextEditingController _deviceCtrl;
  late String _type;
  late String _encoding;
  late int _paperWidth;
  late bool _isActive;
  /// Sprint 3 — id de la impresora de respaldo elegida en el dropdown.
  /// null = "Sin respaldo" → al guardar mandamos `clearFallback: true`.
  String? _fallbackPrinterId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final printer = widget.printer;
    _nameCtrl = TextEditingController(text: printer.name);
    _ipCtrl = TextEditingController(text: printer.ip ?? '');
    _macCtrl = TextEditingController(text: printer.mac ?? '');
    _deviceCtrl = TextEditingController(text: printer.devicePath ?? '');
    _type = printer.type.name;
    _encoding = printer.encoding;
    _paperWidth = printer.paperWidth == 58 ? 58 : 80;
    _isActive = printer.online;
    _fallbackPrinterId = printer.fallbackPrinterId;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ipCtrl.dispose();
    _macCtrl.dispose();
    _deviceCtrl.dispose();
    super.dispose();
  }

  /// Printing v2 (Slice A — Auto-discovery): abre un dialog que escanea
  /// la LAN en vivo y permite elegir una impresora encontrada para
  /// autocompletar IP/MAC del config.
  Future<void> _openDiscoverDialog() async {
    final selected = await showDialog<DiscoveredPrinter>(
      context: context,
      builder: (ctx) => _DiscoverPrinterDialog(vmCtrl: widget.vmCtrl),
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (selected.ip != null && selected.ip!.isNotEmpty) {
        _ipCtrl.text = selected.ip!;
      }
      if (selected.mac != null && selected.mac!.isNotEmpty) {
        _macCtrl.text = selected.mac!;
      }
      if (selected.idHint != null && selected.idHint!.isNotEmpty) {
        _deviceCtrl.text = selected.idHint!;
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    // Sprint 3 — distinguir "sin respaldo" (clearFallback) vs "asignar
    // X como respaldo" (fallbackPrinterId). El viewmodel maneja ambas
    // ramas; pasar las dos cosas en simultáneo no rompe (clearFallback
    // gana en el repo).
    final ok = await widget.vmCtrl.updatePrinter(
      printerId: widget.printer.id,
      name: _nameCtrl.text,
      ipAddress: _ipCtrl.text,
      mac: _macCtrl.text,
      devicePath: _deviceCtrl.text,
      type: _type,
      isActive: _isActive,
      paperWidth: _paperWidth,
      encoding: _encoding,
      fallbackPrinterId: _fallbackPrinterId,
      clearFallback: _fallbackPrinterId == null,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) {
      Navigator.of(context).pop(true);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No se pudo guardar la configuración.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: SizedBox(
        width: 1200,
        height: 780,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.settings_outlined,
                    size: 30,
                    color: MangoColors.darkGray,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Configurar impresora',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: MangoColors.darkGray,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: Color(0xFFD4D4D4)),
              const SizedBox(height: 18),
              Expanded(
                child: SingleChildScrollView(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 980;
                      if (compact) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildPrinterDataColumn(),
                            const SizedBox(height: 22),
                            _buildPrinterSettingsColumn(),
                          ],
                        );
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _buildPrinterDataColumn()),
                          const SizedBox(width: 22),
                          Container(
                            width: 1,
                            height: 720,
                            color: const Color(0xFFD4D4D4),
                          ),
                          const SizedBox(width: 22),
                          Expanded(child: _buildPrinterSettingsColumn()),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Spacer(),
                  SizedBox(
                    width: 280,
                    child: FilledButton(
                      onPressed: _saving ? null : _save,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFF97316),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Guardar',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
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

  Widget _buildPrinterDataColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _DialogSectionTitle(
          icon: Icons.description_outlined,
          title: 'Datos de la impresora',
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: MangoColors.muted),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Esta información será útil para soporte y para identificar la impresora correcta.',
                  style: TextStyle(fontSize: 13, color: MangoColors.muted),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _DialogField(
                label: 'Nombre de la impresora',
                child: TextField(controller: _nameCtrl),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: _DialogField(
                label: 'Tipo de conexión',
                child: DropdownButtonFormField<String>(
                  initialValue: _type,
                  items: const [
                    DropdownMenuItem(
                      value: 'network',
                      child: Text('Red / LAN'),
                    ),
                    DropdownMenuItem(
                      value: 'bluetooth',
                      child: Text('Bluetooth'),
                    ),
                    DropdownMenuItem(value: 'usb', child: Text('USB')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _type = value);
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _DialogField(
                label: 'Modo de impresión',
                child: DropdownButtonFormField<String>(
                  initialValue: _encoding,
                  items: const [
                    DropdownMenuItem(value: 'CP437', child: Text('CP437')),
                    DropdownMenuItem(value: 'CP850', child: Text('CP850')),
                    DropdownMenuItem(value: 'UTF-8', child: Text('UTF-8')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _encoding = value);
                  },
                ),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: _DialogField(
                label: 'MAC / puerto USB',
                child: TextField(
                  controller: _macCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Ej. USB001, VID/PID o MAC si aplica',
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _DialogField(
          label: 'ID / Ruta del dispositivo',
          child: TextField(
            controller: _deviceCtrl,
            decoration: const InputDecoration(
              hintText:
                  'Solo aplica cuando la impresora reporta una ruta local',
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPrinterSettingsColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _DialogSectionTitle(
          icon: Icons.print_outlined,
          title: 'Configuración de la impresora',
        ),
        const SizedBox(height: 12),
        _DialogField(
          label: 'Dirección IP configurada',
          child: Row(
            children: [
              Expanded(child: TextField(controller: _ipCtrl)),
              const SizedBox(width: 8),
              // Printing v2 (Slice A — Auto-discovery): botón visible solo
              // cuando el tipo es network. Lanza escaneo de la LAN y muestra
              // las impresoras encontradas para que el admin elija una y
              // autocompletar IP/MAC sin tener que escribirlas a mano.
              if (_type == 'network')
                OutlinedButton.icon(
                  onPressed: _saving ? null : _openDiscoverDialog,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: MangoColors.primaryOrange,
                    side: const BorderSide(
                        color: MangoColors.primaryOrange),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.wifi_find, size: 18),
                  label: const Text('Detectar IP'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Seleccione el tamaño de tu impresora y papel',
          style: TextStyle(fontSize: 14, color: MangoColors.darkGray),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _PaperWidthCard(
                width: 80,
                selected: _paperWidth == 80,
                onTap: () => setState(() => _paperWidth = 80),
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: _PaperWidthCard(
                width: 58,
                selected: _paperWidth == 58,
                onTap: () => setState(() => _paperWidth = 58),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        _buildFallbackSection(),
        const SizedBox(height: 22),
        const Text(
          'Estado de la impresora',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Text(
              'Activo',
              style: TextStyle(fontSize: 14, color: MangoColors.darkGray),
            ),
            const SizedBox(width: 10),
            Switch.adaptive(
              value: _isActive,
              activeTrackColor: const Color(0xFFF97316),
              onChanged: (value) => setState(() => _isActive = value),
            ),
          ],
        ),
        const Text(
          'La impresora queda activa para asignaciones y pruebas dentro del sistema.',
          style: TextStyle(
            fontSize: 13,
            color: MangoColors.muted,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  /// Sprint 3 — UI para elegir impresora de respaldo. La lista viene del
  /// viewmodel (todas las impresoras del negocio), excluyendo self para
  /// no permitir auto-fallback (la BD también lo bloquea via CHECK).
  Widget _buildFallbackSection() {
    final all = ref.watch(printingPrintersViewModelProvider).items;
    final candidates =
        all.where((p) => p.id != widget.printer.id).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Impresora de respaldo (failover)',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: MangoColors.darkGray,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Si esta impresora falla al imprimir un ticket, el sistema lo '
          'redirige inmediatamente a la impresora de respaldo. Sólo 1 nivel: '
          'si el respaldo también falla, entra al flujo normal de reintentos.',
          style: TextStyle(
            fontSize: 12,
            color: MangoColors.muted,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          initialValue: _fallbackPrinterId,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding:
                EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Sin respaldo'),
            ),
            ...candidates.map(
              (p) => DropdownMenuItem<String?>(
                value: p.id,
                child: Text(
                  '${p.name} · ${p.type.name.toUpperCase()}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          onChanged: (value) => setState(() => _fallbackPrinterId = value),
        ),
        if (candidates.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'No hay otras impresoras configuradas para usar como respaldo.',
              style: TextStyle(fontSize: 11, color: MangoColors.muted),
            ),
          ),
      ],
    );
  }
}

class _DialogSectionTitle extends StatelessWidget {
  const _DialogSectionTitle({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: MangoColors.darkGray),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: MangoColors.darkGray,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Divider(height: 1, color: Color(0xFFD4D4D4)),
      ],
    );
  }
}

class _DialogField extends StatelessWidget {
  const _DialogField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, color: MangoColors.darkGray),
        ),
        const SizedBox(height: 8),
        Theme(
          data: Theme.of(context).copyWith(
            inputDecorationTheme: InputDecorationTheme(
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFCFCFCF)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFCFCFCF)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(
                  color: Color(0xFFF97316),
                  width: 1.5,
                ),
              ),
            ),
          ),
          child: child,
        ),
      ],
    );
  }
}

class _PaperWidthCard extends StatelessWidget {
  const _PaperWidthCard({
    required this.width,
    required this.selected,
    required this.onTap,
  });

  final int width;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEFF4FF) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFFF97316) : const Color(0xFFCFCFCF),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.print_rounded, size: 44, color: Color(0xFF84A8F7)),
            const SizedBox(width: 18),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$width mm',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: MangoColors.darkGray,
                  ),
                ),
                const Text(
                  'Tamaño de papel',
                  style: TextStyle(fontSize: 14, color: MangoColors.darkGray),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog que escanea la LAN en vivo y muestra impresoras descubiertas
/// (Printing v2 — Slice A). Al elegir una, retorna el `DiscoveredPrinter`
/// para que el padre autocomplete los campos IP/MAC.
class _DiscoverPrinterDialog extends StatefulWidget {
  const _DiscoverPrinterDialog({required this.vmCtrl});

  final PrintingPrintersViewModel vmCtrl;

  @override
  State<_DiscoverPrinterDialog> createState() =>
      _DiscoverPrinterDialogState();
}

class _DiscoverPrinterDialogState extends State<_DiscoverPrinterDialog> {
  StreamSubscription<DiscoveredPrinter>? _sub;
  final List<DiscoveredPrinter> _found = [];
  bool _scanning = true;
  int _secondsLeft = 120;
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  void _startScan() {
    _countdown = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _secondsLeft = _secondsLeft > 0 ? _secondsLeft - 1 : 0;
      });
      if (_secondsLeft <= 0) {
        t.cancel();
      }
    });

    _sub = widget.vmCtrl
        .scanIntensiveStream(duration: const Duration(seconds: 120))
        .listen(
      (d) {
        if (!mounted) return;
        final ip = d.ip;
        final mac = d.mac;
        final isDup = _found.any((p) {
          if (ip != null && p.ip == ip) return true;
          if (mac != null && p.mac == mac) return true;
          return false;
        });
        if (isDup) return;
        setState(() => _found.add(d));
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
      onError: (_) {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  void _stopScan() {
    _sub?.cancel();
    _sub = null;
    _countdown?.cancel();
    _countdown = null;
    if (mounted) setState(() => _scanning = false);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _countdown?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mm = (_secondsLeft ~/ 60).toString().padLeft(1, '0');
    final ss = (_secondsLeft % 60).toString().padLeft(2, '0');

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 480,
        height: 560,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.wifi_find,
                      color: MangoColors.primaryOrange),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Detectar impresoras en la red',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: MangoColors.darkGray,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_scanning)
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Buscando... quedan $mm:$ss',
                      style: const TextStyle(
                        fontSize: 13,
                        color: MangoColors.muted,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _stopScan,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: const Text('Detener'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFEF4444),
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Icon(
                      _found.isEmpty
                          ? Icons.info_outline
                          : Icons.check_circle_outline,
                      size: 16,
                      color: _found.isEmpty
                          ? MangoColors.muted
                          : const Color(0xFF10B981),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _found.isEmpty
                          ? 'No se encontraron impresoras.'
                          : '${_found.length} impresora(s) encontradas.',
                      style: const TextStyle(
                        fontSize: 13,
                        color: MangoColors.muted,
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: 12),
              const Divider(height: 1, color: Color(0xFFE5E5E5)),
              const SizedBox(height: 8),
              Expanded(
                child: _found.isEmpty && !_scanning
                    ? _emptyState()
                    : ListView.separated(
                        itemCount: _found.length,
                        separatorBuilder: (_, _) => const Divider(
                          height: 1,
                          color: Color(0xFFF1F1F1),
                        ),
                        itemBuilder: (_, i) {
                          final p = _found[i];
                          return _PrinterFoundTile(
                            discovered: p,
                            onTap: () => Navigator.of(context).pop(p),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancelar'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.search_off, size: 48, color: Color(0xFFAAAAAA)),
          const SizedBox(height: 12),
          const Text(
            'No se detectó ninguna impresora.',
            style: TextStyle(
              fontSize: 14,
              color: MangoColors.darkGray,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              'Verificá que la impresora esté encendida, conectada a la '
              'misma red y que el firewall permita el puerto 9100.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: MangoColors.muted),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _found.clear();
                _secondsLeft = 120;
                _scanning = true;
              });
              _startScan();
            },
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Reintentar búsqueda'),
          ),
        ],
      ),
    );
  }
}

class _PrinterFoundTile extends StatelessWidget {
  const _PrinterFoundTile({required this.discovered, required this.onTap});

  final DiscoveredPrinter discovered;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.print_outlined,
                color: MangoColors.darkGray),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    discovered.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _buildSubtitle(),
                    style: const TextStyle(
                      fontSize: 12,
                      color: MangoColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFFAAAAAA)),
          ],
        ),
      ),
    );
  }

  String _buildSubtitle() {
    final parts = <String>[];
    if (discovered.ip != null && discovered.ip!.isNotEmpty) {
      parts.add('IP: ${discovered.ip}');
    }
    if (discovered.mac != null && discovered.mac!.isNotEmpty) {
      parts.add('MAC: ${discovered.mac}');
    }
    parts.add(discovered.type.name.toUpperCase());
    return parts.join(' · ');
  }
}
