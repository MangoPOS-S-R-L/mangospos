import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:mangopos/core/printing/classic_bluetooth.dart';

/// Diagnóstico de transporte Bluetooth (PRD BT — Fase 0).
///
/// Lista las impresoras BT **pareadas** e indica, por equipo, si exponen el
/// perfil **Classic/SPP** (→ imprimirá por RFCOMM, rápido y única vía para
/// Classic-only) o si parecen **BLE-only** (→ usará GATT). Es la auditoría de
/// hardware in-app que decide si vale construir/usar el transporte Classic.
class BluetoothDiagnosticsScreen extends StatefulWidget {
  const BluetoothDiagnosticsScreen({super.key});

  @override
  State<BluetoothDiagnosticsScreen> createState() =>
      _BluetoothDiagnosticsScreenState();
}

class _BluetoothDiagnosticsScreenState
    extends State<BluetoothDiagnosticsScreen> {
  bool _loading = true;
  bool _permissionDenied = false;
  List<ClassicBtDevice> _devices = const [];

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    if (!_isAndroid) {
      setState(() {
        _loading = false;
        _devices = const [];
      });
      return;
    }
    // Mismos permisos que el alta de impresora BT (Android 12+).
    final scan = await Permission.bluetoothScan.request();
    final connect = await Permission.bluetoothConnect.request();
    await Permission.location.request();
    final denied = scan.isDenied || connect.isDenied;

    final devices = await ClassicBluetooth.bondedDevices();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _permissionDenied = denied && devices.isEmpty;
      _devices = devices;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnóstico Bluetooth'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Volver a escanear',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (!_isAndroid) {
      return _infoCard(
        icon: Icons.info_outline,
        color: Colors.blueGrey,
        title: 'Solo disponible en Android',
        body:
            'El diagnóstico de Bluetooth Classic/SPP solo aplica en Android. '
            'En iPad la impresión Bluetooth usa BLE (Core Bluetooth); '
            'Classic/SPP no está disponible para apps de terceros en iOS.',
      );
    }

    if (_permissionDenied) {
      return _infoCard(
        icon: Icons.lock_outline,
        color: Colors.orange,
        title: 'Permiso de Bluetooth requerido',
        body:
            'Concede el permiso de Bluetooth para listar las impresoras '
            'pareadas. Puedes habilitarlo en Ajustes del sistema.',
        action: TextButton(
          onPressed: openAppSettings,
          child: const Text('Abrir ajustes'),
        ),
      );
    }

    if (_devices.isEmpty) {
      return _infoCard(
        icon: Icons.bluetooth_disabled,
        color: Colors.blueGrey,
        title: 'Sin dispositivos pareados',
        body:
            'No hay impresoras BT pareadas en este equipo. Empareja la '
            'impresora en Ajustes › Bluetooth de Android y vuelve a escanear. '
            'Las impresoras BLE-only no siempre requieren emparejarse y podrían '
            'no aparecer aquí: úsalas por BLE.',
      );
    }

    final sppCount = _devices.where((d) => d.hasSpp).length;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _summary(sppCount, _devices.length),
        const SizedBox(height: 12),
        for (final d in _devices) _deviceTile(d),
      ],
    );
  }

  Widget _summary(int spp, int total) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.summarize_outlined, color: Color(0xFF475569)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$spp de $total impresora(s) pareada(s) exponen Classic/SPP '
              '(imprimirán por RFCOMM). El resto usará BLE.',
              style: const TextStyle(fontSize: 13, color: Color(0xFF334155)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deviceTile(ClassicBtDevice d) {
    final bool spp = d.hasSpp;
    final Color color = spp ? const Color(0xFF065F46) : const Color(0xFFB45309);
    final Color bg = spp ? const Color(0xFFD1FAE5) : const Color(0xFFFEF3C7);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      child: ListTile(
        leading: Icon(
          spp ? Icons.bluetooth_connected : Icons.bluetooth,
          color: color,
        ),
        title: Text(
          d.name.isEmpty ? '(sin nombre)' : d.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(d.address, style: const TextStyle(fontSize: 12)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            spp ? 'Classic/SPP' : 'BLE-only',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoCard({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    Widget? action,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xFF64748B)),
            ),
            if (action != null) ...[const SizedBox(height: 16), action],
          ],
        ),
      ),
    );
  }
}
