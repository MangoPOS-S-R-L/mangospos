import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/print_manager.dart';

class PrintDashboard extends StatefulWidget {
  const PrintDashboard({super.key});

  @override
  State<PrintDashboard> createState() => _PrintDashboardState();
}

class _PrintDashboardState extends State<PrintDashboard> {
  final _manager = PrintManager();
  String _status = 'Iniciando...';
  List<dynamic> _printers = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _manager.init();
      await _refreshStatus();
      await _loadPrinters();
    } catch (e) {
      setState(() {
        _status = '🔴 ${e.toString()}';
        _loading = false;
      });
    }
  }

  Future<void> _refreshStatus() async {
    final st = await _manager.statusText();
    setState(() => _status = st);
  }

  Future<void> _loadPrinters() async {
    final list = await _manager.listPrinters();
    setState(() {
      _printers = list;
      _loading = false;
    });
  }

  Future<void> _scanUsb() async {
    setState(() => _loading = true);
    try {
      await _manager.usbScan();
    } catch (e) {
      setState(() {
        _status = '🔴 ${e.toString()}';
      });
    }
    await _loadPrinters();
    await _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusChip(text: _status),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: _loading ? null : _scanUsb,
                  icon: const Text('🔍'),
                  label: const Text('USB Scan'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _loading
                ? const LinearProgressIndicator()
                : Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _printers
                        .map(
                          (p) => Chip(
                            label: Text(p.toString()),
                            avatar: const Icon(Icons.print),
                          ),
                        )
                        .toList(),
                  ),
            const SizedBox(height: 16),
            if (_manager.agentUrl != null)
              QrImageView(
                data: _manager.agentUrl!,
                version: QrVersions.auto,
                size: 120,
              ),
          ],
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String text;
  const StatusChip({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final color = text.startsWith('🟢')
        ? const Color(0xFF22C55E)
        : text.startsWith('🔴')
            ? Colors.red
            : Colors.grey;
    return Chip(
      avatar: CircleAvatar(backgroundColor: color, radius: 6),
      label: Text(text),
    );
  }
}
