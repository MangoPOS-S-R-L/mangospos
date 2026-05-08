import 'dart:async';

import 'package:flutter/material.dart';

const Color _kTextPrimary = Color(0xFF2C2C2C);
const Color _kTextSecondary = Color(0xFF7A7A7A);
const Color _kSuccess = Color(0xFF22C55E);
const Color _kAccent = Color(0xFFF97316);

/// Popup que aparece después de finalizar una venta.
/// El cajero puede imprimir una copia adicional o cerrar manualmente.
/// Si no hace nada en [autoCloseSeconds] segundos, se cierra solo.
///
/// El callback [onReprint] se invoca cada vez que el cajero pide copia.
/// Cada reimpresión exitosa reinicia el contador.
Future<void> showPaymentSuccessDialog({
  required BuildContext context,
  required Future<void> Function() onReprint,
  int autoCloseSeconds = 10,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Pago procesado',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, _) => _PaymentSuccessDialog(
      onReprint: onReprint,
      autoCloseSeconds: autoCloseSeconds,
    ),
    transitionBuilder: (ctx, anim, _, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
          child: child,
        ),
      );
    },
  );
}

class _PaymentSuccessDialog extends StatefulWidget {
  const _PaymentSuccessDialog({
    required this.onReprint,
    required this.autoCloseSeconds,
  });

  final Future<void> Function() onReprint;
  final int autoCloseSeconds;

  @override
  State<_PaymentSuccessDialog> createState() => _PaymentSuccessDialogState();
}

class _PaymentSuccessDialogState extends State<_PaymentSuccessDialog> {
  Timer? _timer;
  late int _remaining;
  bool _printing = false;

  @override
  void initState() {
    super.initState();
    _remaining = widget.autoCloseSeconds;
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining <= 0) {
        _timer?.cancel();
        if (mounted) Navigator.of(context).pop();
      }
    });
  }

  void _resetTimer() {
    if (!mounted) return;
    setState(() => _remaining = widget.autoCloseSeconds);
    _startTimer();
  }

  Future<void> _handleReprint() async {
    if (_printing) return;
    _timer?.cancel();
    setState(() {
      _printing = true;
    });
    try {
      await widget.onReprint();
    } catch (_) {
      // Errores de impresión los maneja el caller con su propio diálogo
      // de reintento — aquí solo nos importa que el estado vuelva a "ok"
      // para que el cajero pueda intentar de nuevo o cerrar.
    } finally {
      if (mounted) {
        setState(() => _printing = false);
        _resetTimer();
      }
    }
  }

  void _close() {
    _timer?.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _remaining / widget.autoCloseSeconds;

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        width: 440,
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Icono de éxito con anillo de progreso del autoclose
            SizedBox(
              width: 96,
              height: 96,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: progress, end: progress),
                      duration: const Duration(milliseconds: 900),
                      builder: (_, value, _) => CircularProgressIndicator(
                        value: value.clamp(0.0, 1.0),
                        strokeWidth: 4,
                        backgroundColor: const Color(0xFFE5E7EB),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          _kSuccess,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(
                      color: Color(0xFFECFDF5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: _kSuccess,
                      size: 56,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            const Text(
              'Pago procesado',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: _kTextPrimary,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),

            Text(
              _printing
                  ? 'Imprimiendo copia...'
                  : 'Cerrando en $_remaining s',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: _kTextSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '¿Necesitas imprimir una copia adicional del recibo?',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: _kTextSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),

            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: _printing ? null : _close,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'Cerrar',
                      style: TextStyle(
                        color: _kTextSecondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _printing ? null : _handleReprint,
                    style: FilledButton.styleFrom(
                      backgroundColor: _kAccent,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    icon: _printing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.print_rounded,
                            color: Colors.white,
                            size: 20,
                          ),
                    label: const Text(
                      'Imprimir copia',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
