import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Vista placeholder para gestión de cierres de caja
/// TODO: Implementar la funcionalidad completa
class CashClosuresView extends ConsumerStatefulWidget {
  const CashClosuresView({super.key});

  @override
  ConsumerState<CashClosuresView> createState() => _CashClosuresViewState();
}

class _CashClosuresViewState extends ConsumerState<CashClosuresView> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gestión de Cierres'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.settings, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              'Gestión de Cierres',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.grey[700],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Próximamente',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }
}
