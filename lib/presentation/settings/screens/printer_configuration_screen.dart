// lib/presentation/settings/screens/printer_configuration_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../data/repositories/printing_repository.dart';
import '../../../data/models/printing_models.dart';
import '../../../widgets/error_handler_widget.dart';

/// 🖨️ Pantalla de Configuración de Impresoras y Áreas
class PrinterConfigurationScreen extends ConsumerStatefulWidget {
  final String businessId;

  const PrinterConfigurationScreen({super.key, required this.businessId});

  @override
  ConsumerState<PrinterConfigurationScreen> createState() =>
      _PrinterConfigurationScreenState();
}

class _PrinterConfigurationScreenState
    extends ConsumerState<PrinterConfigurationScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late PrintingRepository _printingRepo;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _printingRepo = PrintingRepository(Supabase.instance.client);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración de Impresión'),
        backgroundColor: const Color(0xFFF97316),
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(icon: Icon(Icons.print), text: 'Impresoras'),
            Tab(icon: Icon(Icons.category), text: 'Áreas'),
            Tab(icon: Icon(Icons.link), text: 'Asignaciones'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _PrintersTab(businessId: widget.businessId, repo: _printingRepo),
          _AreasTab(businessId: widget.businessId, repo: _printingRepo),
          _AssignmentsTab(businessId: widget.businessId, repo: _printingRepo),
        ],
      ),
    );
  }
}

/// 📋 Tab de Impresoras
class _PrintersTab extends StatefulWidget {
  final String businessId;
  final PrintingRepository repo;

  const _PrintersTab({required this.businessId, required this.repo});

  @override
  State<_PrintersTab> createState() => _PrintersTabState();
}

class _PrintersTabState extends State<_PrintersTab> {
  Future<List<PrinterConfig>>? _printersFuture;

  @override
  void initState() {
    super.initState();
    _loadPrinters();
  }

  void _loadPrinters() {
    setState(() {
      _printersFuture = widget.repo.getActivePrinters(widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Impresoras Configuradas',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => _showAddPrinterDialog(),
                icon: const Icon(Icons.add),
                label: const Text('Agregar'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF97316),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: AsyncOperationBuilder<List<PrinterConfig>>(
            future: _printersFuture!,
            builder: (context, printers) {
              if (printers.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.print_disabled,
                        size: 64,
                        color: Colors.grey,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'No hay impresoras configuradas',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () => _showAddPrinterDialog(),
                        icon: const Icon(Icons.add),
                        label: const Text('Agregar Primera Impresora'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF97316),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: printers.length,
                itemBuilder: (context, index) {
                  final printer = printers[index];
                  return _PrinterCard(
                    printer: printer,
                    onTest: () => _testPrinter(printer),
                    onEdit: () => _editPrinter(printer),
                    onDelete: () => _deletePrinter(printer),
                  );
                },
              );
            },
            onRetry: _loadPrinters,
          ),
        ),
      ],
    );
  }

  void _showAddPrinterDialog() {
    showDialog(
      context: context,
      builder: (context) => _AddPrinterDialog(
        businessId: widget.businessId,
        repo: widget.repo,
        onSaved: _loadPrinters,
      ),
    );
  }

  void _editPrinter(PrinterConfig printer) {
    showDialog(
      context: context,
      builder: (context) => _AddPrinterDialog(
        businessId: widget.businessId,
        repo: widget.repo,
        onSaved: _loadPrinters,
        editing: printer,
      ),
    );
  }

  Future<void> _testPrinter(PrinterConfig printer) async {
    try {
      await widget.repo.enqueueTestPrint(printer.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Trabajo de prueba enviado'),
            backgroundColor: Color(0xFF22C55E),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ErrorSnackBar.show(context, e);
      }
    }
  }

  Future<void> _deletePrinter(PrinterConfig printer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar Impresora'),
        content: Text('¿Eliminar "${printer.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await widget.repo.deletePrinter(printer.id);
        _loadPrinters();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Impresora eliminada')));
        }
      } catch (e) {
        if (mounted) {
          ErrorSnackBar.show(context, e);
        }
      }
    }
  }
}

/// 🖨️ Card de Impresora
class _PrinterCard extends StatelessWidget {
  final PrinterConfig printer;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _PrinterCard({
    required this.printer,
    required this.onTest,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _getPrinterIcon(),
                  size: 32,
                  color: printer.isActive ? const Color(0xFF22C55E) : Colors.grey,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        printer.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _getPrinterTypeLabel(),
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: printer.isActive
                        ? const Color(0xFF22C55E).withOpacity(0.1)
                        : Colors.grey.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    printer.isActive ? 'Activa' : 'Inactiva',
                    style: TextStyle(
                      color: printer.isActive ? const Color(0xFF22C55E) : Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (printer.isNetwork) ...[
              _InfoRow(
                icon: Icons.wifi,
                label: 'IP',
                value: '${printer.ipAddress}:${printer.port}',
              ),
            ],
            _InfoRow(
              icon: Icons.straighten,
              label: 'Ancho de papel',
              value: '${printer.paperWidth}mm',
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onTest,
                  icon: const Icon(Icons.print),
                  label: const Text('Probar'),
                ),
                TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit),
                  label: const Text('Editar'),
                ),
                TextButton.icon(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete),
                  label: const Text('Eliminar'),
                  style: TextButton.styleFrom(foregroundColor: Colors.red),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getPrinterIcon() {
    if (printer.isNetwork) return Icons.wifi;
    if (printer.isUSB) return Icons.usb;
    if (printer.isBluetooth) return Icons.bluetooth;
    return Icons.print;
  }

  String _getPrinterTypeLabel() {
    if (printer.isNetwork) return 'Impresora de Red';
    if (printer.isUSB) return 'Impresora USB';
    if (printer.isBluetooth) return 'Impresora Bluetooth';
    return 'Impresora';
  }
}

/// ℹ️ Fila de información
class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Text(
            '$label: ',
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

/// ➕ Diálogo para agregar/editar impresora.
///
/// Si [editing] es null → modo crear; si trae un PrinterConfig → modo editar
/// (pre-llena campos y al guardar llama updatePrinter en vez de createPrinter).
class _AddPrinterDialog extends StatefulWidget {
  final String businessId;
  final PrintingRepository repo;
  final VoidCallback onSaved;
  final PrinterConfig? editing;

  const _AddPrinterDialog({
    required this.businessId,
    required this.repo,
    required this.onSaved,
    this.editing,
  });

  @override
  State<_AddPrinterDialog> createState() => _AddPrinterDialogState();
}

class _AddPrinterDialogState extends State<_AddPrinterDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '9100');

  String _type = 'network';
  int _paperWidth = 80;
  bool _isLoading = false;
  bool _isTesting = false;
  // null = sin probar todavía; true/false = resultado del último ping.
  bool? _lastTestResult;
  String? _lastTestMessage;

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      _nameController.text = e.name;
      _type = e.printerType.name; // network | usb | bluetooth
      _paperWidth = e.paperWidth;
      if (e.ipAddress != null) _ipController.text = e.ipAddress!;
      if (e.port != null) _portController.text = e.port!.toString();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  // IPv4 dotted: 4 octetos 0-255. Regex en vez de InternetAddress.tryParse
  // para evitar import de dart:io (que no compila en Flutter Web).
  static final _ipv4Re = RegExp(
    r'^(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)$',
  );

  String? _validateIp(String? value) {
    if (value == null || value.trim().isEmpty) return 'Ingresa la IP';
    if (!_ipv4Re.hasMatch(value.trim())) {
      return 'IP inválida (formato esperado: 192.168.1.100)';
    }
    return null;
  }

  String? _validatePort(String? value) {
    if (value == null || value.trim().isEmpty) return 'Ingresa el puerto';
    final port = int.tryParse(value.trim());
    if (port == null || port < 1 || port > 65535) {
      return 'Puerto fuera de rango (1-65535)';
    }
    return null;
  }

  Future<void> _testConnection() async {
    // Solo valida los campos de network, no exige nombre lleno aún.
    if (_validateIp(_ipController.text) != null ||
        _validatePort(_portController.text) != null) {
      _formKey.currentState?.validate();
      return;
    }
    setState(() {
      _isTesting = true;
      _lastTestResult = null;
      _lastTestMessage = null;
    });
    final ip = _ipController.text.trim();
    final port = int.parse(_portController.text.trim());
    final ok = await widget.repo.pingNetworkPrinter(ip: ip, port: port);
    if (!mounted) return;
    setState(() {
      _isTesting = false;
      _lastTestResult = ok;
      _lastTestMessage = ok
          ? 'Conexión exitosa con $ip:$port'
          : 'No se pudo conectar a $ip:$port. Verifica IP, puerto y red.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Editar Impresora' : 'Agregar Impresora'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  hintText: 'Ej: Impresora Cocina 1',
                  prefixIcon: Icon(Icons.label),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Ingresa un nombre';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(
                  labelText: 'Tipo',
                  prefixIcon: Icon(Icons.category),
                ),
                items: const [
                  DropdownMenuItem(value: 'network', child: Text('Red (IP)')),
                  DropdownMenuItem(value: 'usb', child: Text('USB')),
                  DropdownMenuItem(
                    value: 'bluetooth',
                    child: Text('Bluetooth'),
                  ),
                ],
                onChanged: (value) {
                  setState(() {
                    _type = value!;
                  });
                },
              ),
              if (_type == 'network') ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _ipController,
                  decoration: const InputDecoration(
                    labelText: 'Dirección IP',
                    hintText: '192.168.1.100',
                    prefixIcon: Icon(Icons.wifi),
                  ),
                  keyboardType: TextInputType.number,
                  // Cualquier cambio invalida el último resultado de prueba.
                  onChanged: (_) {
                    if (_lastTestResult != null) {
                      setState(() {
                        _lastTestResult = null;
                        _lastTestMessage = null;
                      });
                    }
                  },
                  validator: _validateIp,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _portController,
                  decoration: const InputDecoration(
                    labelText: 'Puerto',
                    hintText: '9100',
                    prefixIcon: Icon(Icons.settings_ethernet),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (_) {
                    if (_lastTestResult != null) {
                      setState(() {
                        _lastTestResult = null;
                        _lastTestMessage = null;
                      });
                    }
                  },
                  validator: _validatePort,
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: (_isTesting || _isLoading) ? null : _testConnection,
                    icon: _isTesting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check),
                    label: Text(_isTesting ? 'Probando…' : 'Probar conexión'),
                  ),
                ),
                if (_lastTestMessage != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        _lastTestResult == true
                            ? Icons.check_circle
                            : Icons.error_outline,
                        size: 18,
                        color: _lastTestResult == true
                            ? const Color(0xFF22C55E)
                            : Colors.red,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _lastTestMessage!,
                          style: TextStyle(
                            fontSize: 13,
                            color: _lastTestResult == true
                                ? const Color(0xFF15803D)
                                : Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _paperWidth,
                decoration: const InputDecoration(
                  labelText: 'Ancho de Papel',
                  prefixIcon: Icon(Icons.straighten),
                ),
                items: const [
                  DropdownMenuItem(value: 58, child: Text('58mm')),
                  DropdownMenuItem(value: 80, child: Text('80mm')),
                ],
                onChanged: (value) {
                  setState(() {
                    _paperWidth = value!;
                  });
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _savePrinter,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF97316),
            foregroundColor: Colors.white,
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Guardar'),
        ),
      ],
    );
  }

  Future<void> _savePrinter() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final ip = _type == 'network' ? _ipController.text.trim() : null;
      final port = _type == 'network' ? int.parse(_portController.text.trim()) : null;

      if (_isEdit) {
        await widget.repo.updatePrinter(
          printerId: widget.editing!.id,
          name: _nameController.text.trim(),
          type: _type,
          ipAddress: ip,
          port: port,
          paperWidth: _paperWidth,
        );
      } else {
        await widget.repo.createPrinter(
          businessId: widget.businessId,
          name: _nameController.text.trim(),
          type: _type,
          ipAddress: ip,
          port: port,
          paperWidth: _paperWidth,
        );
      }

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isEdit
                  ? 'Impresora actualizada'
                  : 'Impresora agregada exitosamente',
            ),
            backgroundColor: const Color(0xFF22C55E),
          ),
        );
        widget.onSaved();
      }
    } catch (e) {
      if (mounted) {
        ErrorSnackBar.show(context, e);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
}

/// 📍 Tab de Áreas
class _AreasTab extends StatefulWidget {
  final String businessId;
  final PrintingRepository repo;

  const _AreasTab({required this.businessId, required this.repo});

  @override
  State<_AreasTab> createState() => _AreasTabState();
}

class _AreasTabState extends State<_AreasTab> {
  Future<List<PrintArea>>? _areasFuture;

  @override
  void initState() {
    super.initState();
    _loadAreas();
  }

  void _loadAreas() {
    setState(() {
      _areasFuture = widget.repo.getPrintAreas(widget.businessId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Áreas de Impresión',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              ElevatedButton.icon(
                onPressed: () => _showAreaDialog(),
                icon: const Icon(Icons.add),
                label: const Text('Agregar'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF97316),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: AsyncOperationBuilder<List<PrintArea>>(
            future: _areasFuture!,
            builder: (context, areas) {
              if (areas.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.category, size: 64, color: Colors.grey),
                      const SizedBox(height: 16),
                      const Text(
                        'No hay áreas configuradas',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                      const SizedBox(height: 8),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          'Las áreas agrupan impresoras por destino: cocina caliente, '
                          'cocina fría, bar, cajero o fiscal.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: Colors.grey),
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () => _showAreaDialog(),
                        icon: const Icon(Icons.add),
                        label: const Text('Agregar Primera Área'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFF97316),
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: areas.length,
                itemBuilder: (context, i) {
                  final area = areas[i];
                  return _AreaCard(
                    area: area,
                    onEdit: () => _showAreaDialog(editing: area),
                    onDelete: () => _deleteArea(area),
                  );
                },
              );
            },
            onRetry: _loadAreas,
          ),
        ),
      ],
    );
  }

  void _showAreaDialog({PrintArea? editing}) {
    showDialog(
      context: context,
      builder: (context) => _AreaFormDialog(
        businessId: widget.businessId,
        repo: widget.repo,
        editing: editing,
        onSaved: _loadAreas,
      ),
    );
  }

  Future<void> _deleteArea(PrintArea area) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Eliminar Área'),
        content: Text(
          '¿Eliminar "${area.name}"? Las asignaciones de impresoras a esta '
          'área también se eliminarán.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    try {
      await widget.repo.deleteArea(area.id);
      _loadAreas();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Área eliminada')));
      }
    } catch (e) {
      if (mounted) ErrorSnackBar.show(context, e);
    }
  }
}

class _AreaCard extends StatelessWidget {
  final PrintArea area;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _AreaCard({
    required this.area,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(
          _iconForCode(area.code),
          color: area.isActive ? const Color(0xFFF97316) : Colors.grey,
          size: 32,
        ),
        title: Text(
          area.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          'Código: ${area.code}',
          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: area.isActive
                    ? const Color(0xFF22C55E).withOpacity(0.12)
                    : Colors.grey.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                area.isActive ? 'Activa' : 'Inactiva',
                style: TextStyle(
                  color: area.isActive ? const Color(0xFF15803D) : Colors.grey,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit, size: 20),
              onPressed: onEdit,
              tooltip: 'Editar',
            ),
            IconButton(
              icon: const Icon(Icons.delete, size: 20, color: Colors.red),
              onPressed: onDelete,
              tooltip: 'Eliminar',
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForCode(String code) {
    switch (code) {
      case 'kitchen_hot':
        return Icons.local_fire_department;
      case 'kitchen_cold':
        return Icons.ac_unit;
      case 'bar':
        return Icons.local_bar;
      case 'cashier':
        return Icons.point_of_sale;
      case 'fiscal':
        return Icons.receipt_long;
      default:
        return Icons.category;
    }
  }
}

class _AreaFormDialog extends StatefulWidget {
  final String businessId;
  final PrintingRepository repo;
  final PrintArea? editing;
  final VoidCallback onSaved;

  const _AreaFormDialog({
    required this.businessId,
    required this.repo,
    required this.onSaved,
    this.editing,
  });

  @override
  State<_AreaFormDialog> createState() => _AreaFormDialogState();
}

class _AreaFormDialogState extends State<_AreaFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  bool _isActive = true;
  bool _isLoading = false;

  // Códigos sugeridos. El usuario puede tipear uno custom si su negocio usa
  // áreas distintas (ej. "pizza", "pasta"). El validator solo exige formato
  // snake_case, no que sea uno de la lista.
  static const _suggestedCodes = [
    'kitchen_hot',
    'kitchen_cold',
    'bar',
    'cashier',
    'fiscal',
  ];

  static final _codeRe = RegExp(r'^[a-z][a-z0-9_]{1,30}$');

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e != null) {
      _nameController.text = e.name;
      _codeController.text = e.code;
      _isActive = e.isActive;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? 'Editar Área' : 'Agregar Área'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  hintText: 'Ej: Cocina caliente',
                  prefixIcon: Icon(Icons.label),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Ingresa un nombre';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _codeController,
                // El código es identificador estable usado en menu_items
                // (print_area_code) y en lookups del backend; cambiarlo en
                // edit es válido pero rompe asociaciones por código previas.
                enabled: !_isEdit,
                decoration: const InputDecoration(
                  labelText: 'Código (snake_case)',
                  hintText: 'kitchen_hot',
                  prefixIcon: Icon(Icons.tag),
                  helperText:
                      'Identificador interno. Solo minúsculas, números y guion bajo.',
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Ingresa un código';
                  if (!_codeRe.hasMatch(v.trim())) {
                    return 'Formato inválido (ej: kitchen_hot)';
                  }
                  return null;
                },
              ),
              if (!_isEdit) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: _suggestedCodes
                      .map(
                        (c) => ActionChip(
                          label: Text(c, style: const TextStyle(fontSize: 12)),
                          onPressed: () {
                            _codeController.text = c;
                          },
                        ),
                      )
                      .toList(),
                ),
              ],
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Activa'),
                subtitle: const Text(
                  'Si está inactiva, no recibirá trabajos de impresión.',
                  style: TextStyle(fontSize: 12),
                ),
                value: _isActive,
                onChanged: (v) => setState(() => _isActive = v),
                activeThumbColor: const Color(0xFF22C55E),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFF97316),
            foregroundColor: Colors.white,
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEdit ? 'Guardar' : 'Agregar'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);
    try {
      if (_isEdit) {
        await widget.repo.updateArea(
          areaId: widget.editing!.id,
          name: _nameController.text.trim(),
          isActive: _isActive,
        );
      } else {
        await widget.repo.createArea(
          businessId: widget.businessId,
          name: _nameController.text.trim(),
          code: _codeController.text.trim().toLowerCase(),
        );
      }
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isEdit ? 'Área actualizada' : 'Área agregada'),
            backgroundColor: const Color(0xFF22C55E),
          ),
        );
        widget.onSaved();
      }
    } catch (e) {
      if (mounted) ErrorSnackBar.show(context, e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}

/// 🔗 Tab de Asignaciones (simplificado)
class _AssignmentsTab extends StatelessWidget {
  final String businessId;
  final PrintingRepository repo;

  const _AssignmentsTab({required this.businessId, required this.repo});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Tab de Asignaciones - Drag & Drop de impresoras a áreas'),
    );
  }
}
