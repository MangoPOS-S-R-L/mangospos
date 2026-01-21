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
        backgroundColor: const Color(0xFFF7941A),
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
                  backgroundColor: const Color(0xFFF7941A),
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
                          backgroundColor: const Color(0xFFF7941A),
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
    // TODO: Implementar edición
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Función de edición próximamente')),
    );
  }

  Future<void> _testPrinter(PrinterConfig printer) async {
    try {
      await widget.repo.enqueueTestPrint(printer.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Trabajo de prueba enviado'),
            backgroundColor: Colors.green,
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
                  color: printer.isActive ? Colors.green : Colors.grey,
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
                        ? Colors.green.withOpacity(0.1)
                        : Colors.grey.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    printer.isActive ? 'Activa' : 'Inactiva',
                    style: TextStyle(
                      color: printer.isActive ? Colors.green : Colors.grey,
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

/// ➕ Diálogo para agregar impresora
class _AddPrinterDialog extends StatefulWidget {
  final String businessId;
  final PrintingRepository repo;
  final VoidCallback onSaved;

  const _AddPrinterDialog({
    required this.businessId,
    required this.repo,
    required this.onSaved,
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

  @override
  void dispose() {
    _nameController.dispose();
    _ipController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Agregar Impresora'),
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
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Ingresa la IP';
                    }
                    return null;
                  },
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
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Ingresa el puerto';
                    }
                    return null;
                  },
                ),
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
            backgroundColor: const Color(0xFFF7941A),
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
      await widget.repo.createPrinter(
        businessId: widget.businessId,
        name: _nameController.text,
        type: _type,
        ipAddress: _type == 'network' ? _ipController.text : null,
        port: _type == 'network' ? int.parse(_portController.text) : null,
        paperWidth: _paperWidth,
      );

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Impresora agregada exitosamente'),
            backgroundColor: Colors.green,
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

/// 📍 Tab de Áreas (simplificado - implementación similar a PrintersTab)
class _AreasTab extends StatelessWidget {
  final String businessId;
  final PrintingRepository repo;

  const _AreasTab({required this.businessId, required this.repo});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('Tab de Áreas - Implementación similar a Impresoras'),
    );
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
