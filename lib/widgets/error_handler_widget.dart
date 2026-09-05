// lib/widgets/error_handler_widget.dart
import 'package:flutter/material.dart';
import '../core/network/database_operation_wrapper.dart';
import '../core/network/supabase_config.dart';
import 'package:mangopos/core/utils/app_snackbar.dart';

/// 🎨 Widget para mostrar errores de base de datos de manera amigable
class ErrorHandlerWidget extends StatelessWidget {
  final dynamic error;
  final VoidCallback? onRetry;
  final String? customMessage;

  const ErrorHandlerWidget({
    super.key,
    required this.error,
    this.onRetry,
    this.customMessage,
  });

  @override
  Widget build(BuildContext context) {
    final errorMessage = customMessage ?? _getErrorMessage();
    final errorIcon = _getErrorIcon();
    final errorColor = _getErrorColor();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: errorColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: errorColor.withOpacity(0.3)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(errorIcon, size: 48, color: errorColor),
          const SizedBox(height: 12),
          Text(
            errorMessage,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: errorColor,
            ),
            textAlign: TextAlign.center,
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: errorColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _getErrorMessage() {
    if (error is DatabaseOperationException) {
      return (error as DatabaseOperationException).message;
    }
    return SupabaseConfig.getFriendlyErrorMessage(error);
  }

  IconData _getErrorIcon() {
    final message = _getErrorMessage().toLowerCase();

    if (message.contains('conexión') || message.contains('internet')) {
      return Icons.wifi_off;
    } else if (message.contains('tiempo') || message.contains('tardó')) {
      return Icons.access_time;
    } else if (message.contains('permisos')) {
      return Icons.lock;
    } else if (message.contains('existe')) {
      return Icons.info_outline;
    } else {
      return Icons.error_outline;
    }
  }

  Color _getErrorColor() {
    final message = _getErrorMessage().toLowerCase();

    if (message.contains('conexión') || message.contains('internet')) {
      return const Color(0xFFF97316);
    } else if (message.contains('tiempo') || message.contains('tardó')) {
      return Colors.amber;
    } else if (message.contains('permisos')) {
      return Colors.red;
    } else {
      return Colors.red.shade400;
    }
  }
}

/// 🎯 Snackbar para mostrar errores rápidamente
class ErrorSnackBar {
  static void show(BuildContext context, dynamic error) {
    final message = error is DatabaseOperationException
        ? (error).message
        : SupabaseConfig.getFriendlyErrorMessage(error);

    ScaffoldMessenger.of(context).showAppSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 14)),
            ),
          ],
        ),
        backgroundColor: Colors.red.shade600,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
          },
        ),
      ),
    );
  }
}

/// 🔄 Widget con estado de carga y manejo de errores
class AsyncOperationBuilder<T> extends StatelessWidget {
  final Future<T> future;
  final Widget Function(BuildContext context, T data) builder;
  final Widget Function(BuildContext context)? loadingBuilder;
  final Widget Function(BuildContext context, dynamic error)? errorBuilder;
  final VoidCallback? onRetry;

  const AsyncOperationBuilder({
    super.key,
    required this.future,
    required this.builder,
    this.loadingBuilder,
    this.errorBuilder,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return loadingBuilder?.call(context) ??
              const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return errorBuilder?.call(context, snapshot.error) ??
              Center(
                child: ErrorHandlerWidget(
                  error: snapshot.error,
                  onRetry: onRetry,
                ),
              );
        }

        if (!snapshot.hasData) {
          return const Center(child: Text('No hay datos disponibles'));
        }

        return builder(context, snapshot.data as T);
      },
    );
  }
}
