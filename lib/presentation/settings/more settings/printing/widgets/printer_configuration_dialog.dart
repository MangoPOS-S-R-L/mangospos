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
          child: TextField(controller: _ipCtrl),
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
