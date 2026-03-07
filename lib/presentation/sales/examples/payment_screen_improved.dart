// lib/presentation/sales/examples/payment_screen_improved.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/repositories/sales_repository_improved.dart';
import '../../../widgets/error_handler_widget.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 📱 Ejemplo de cómo usar el manejo de errores mejorado en una pantalla
/// Este es un EJEMPLO - adapta según tu implementación actual

class PaymentScreenImprovedExample extends ConsumerStatefulWidget {
  final String orderId;
  final double totalAmount;

  const PaymentScreenImprovedExample({
    super.key,
    required this.orderId,
    required this.totalAmount,
  });

  @override
  ConsumerState<PaymentScreenImprovedExample> createState() =>
      _PaymentScreenImprovedExampleState();
}

class _PaymentScreenImprovedExampleState
    extends ConsumerState<PaymentScreenImprovedExample> {
  bool _isProcessing = false;
  dynamic _error;

  Future<void> _processPayment() async {
    setState(() {
      _isProcessing = true;
      _error = null;
    });

    try {
      final repository = SalesRepositoryImproved(Supabase.instance.client);

      // El wrapper maneja automáticamente los reintentos
      await repository.processPayment(
        orderId: widget.orderId,
        paymentMethodId: 'cash', // Ejemplo
        amount: widget.totalAmount,
        changeAmount: 0,
      );

      if (mounted) {
        // Mostrar éxito
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('Pago procesado exitosamente'),
              ],
            ),
            backgroundColor: const Color(0xFF22C55E),
          ),
        );

        // Navegar de vuelta
        Navigator.of(context).pop();
      }
    } catch (error) {
      // El error ya viene con mensaje amigable gracias al wrapper
      setState(() {
        _error = error;
        _isProcessing = false;
      });

      // Mostrar error en snackbar
      if (mounted) {
        ErrorSnackBar.show(context, error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Procesar Pago')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Información del pago
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Total a Pagar',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'RD\$ ${widget.totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF97316),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            // Mostrar error si existe
            if (_error != null) ...[
              ErrorHandlerWidget(error: _error, onRetry: _processPayment),
              const SizedBox(height: 16),
            ],

            const Spacer(),

            // Botón de pago
            ElevatedButton(
              onPressed: _isProcessing ? null : _processPayment,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF97316),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isProcessing
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text(
                      'COBRAR',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 📋 Ejemplo de lista con AsyncOperationBuilder
class OrdersListExample extends ConsumerWidget {
  final String businessId;

  const OrdersListExample({super.key, required this.businessId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = SalesRepositoryImproved(Supabase.instance.client);

    return Scaffold(
      appBar: AppBar(title: const Text('Sesiones Activas')),
      body: AsyncOperationBuilder(
        future: repository.getActiveSessions(businessId),
        loadingBuilder: (context) => const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Cargando sesiones...'),
            ],
          ),
        ),
        errorBuilder: (context, error) => Center(
          child: ErrorHandlerWidget(
            error: error,
            onRetry: () {
              // Forzar reconstrucción del widget
              (context as Element).markNeedsBuild();
            },
          ),
        ),
        builder: (context, sessions) {
          if (sessions.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inbox_outlined, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No hay sesiones activas',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            itemCount: sessions.length,
            padding: const EdgeInsets.all(16),
            itemBuilder: (context, index) {
              final session = sessions[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFF97316),
                    child: Icon(Icons.table_restaurant, color: Colors.white),
                  ),
                  title: Text('Mesa ${session.tableId}'),
                  subtitle: Text('${session.peopleCount} personas'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    // Navegar a detalles
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
