import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../services/session/session_controller.dart';

Future<bool> showPinVerificationModal(
  BuildContext context,
  WidgetRef ref, {
  required PinAccessLevel level,
  String title = 'Verificación de PIN',
  String subtitle = 'Ingrese un PIN autorizado para continuar',
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PinVerificationDialog(
      title: title,
      subtitle: subtitle,
      onVerify: (pin) =>
          ref.read(sessionProvider.notifier).verifyPin(pin: pin, level: level),
      invalidMessage: 'PIN inválido o sin jerarquía requerida.',
    ),
  );

  return result == true;
}

Future<bool> showCurrentUserPinVerificationModal(
  BuildContext context,
  WidgetRef ref, {
  String title = 'Verificación de PIN',
  String subtitle = 'Ingrese su PIN para continuar',
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _PinVerificationDialog(
      title: title,
      subtitle: subtitle,
      onVerify: (pin) =>
          ref.read(sessionProvider.notifier).verifyCurrentUserPin(pin: pin),
      invalidMessage: 'PIN inválido para el usuario actual.',
    ),
  );

  return result == true;
}

class _PinVerificationDialog extends StatefulWidget {
  const _PinVerificationDialog({
    required this.title,
    required this.subtitle,
    required this.onVerify,
    required this.invalidMessage,
  });

  final String title;
  final String subtitle;
  final Future<bool> Function(String pin) onVerify;
  final String invalidMessage;

  @override
  State<_PinVerificationDialog> createState() => _PinVerificationDialogState();
}

class _PinVerificationDialogState extends State<_PinVerificationDialog> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  String? _localError;
  bool _verifying = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final pin = _controller.text.trim();
    if (pin.length != 4) {
      setState(() => _localError = 'El PIN debe tener 4 dígitos.');
      return;
    }

    setState(() {
      _verifying = true;
      _localError = null;
    });

    try {
      final ok = await widget.onVerify(pin);
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _verifying = false;
          _localError = widget.invalidMessage;
        });
        return;
      }
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _localError = 'No se pudo validar el PIN.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: Colors.transparent,
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 24,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF97316).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(
                    Icons.lock_outline_rounded,
                    color: Color(0xFFF97316),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: const Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.subtitle,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF6B7280),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: () => _focusNode.requestFocus(),
              child: _PinDots(value: _controller.text),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              obscureText: true,
              autofocus: true,
              maxLength: 4,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(4),
              ],
              decoration: const InputDecoration(
                labelText: 'PIN de 4 dígitos',
                counterText: '',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_localError != null) {
                  setState(() => _localError = null);
                } else {
                  setState(() {});
                }
              },
              onSubmitted: (_) => _verify(),
            ),
            if (_localError != null) ...[
              const SizedBox(height: 10),
              Text(
                _localError!,
                style: const TextStyle(
                  color: Color(0xFFE11D48),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _verifying
                        ? null
                        : () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _verifying ? null : _verify,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFF97316),
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _verifying
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Confirmar'),
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

class _PinDots extends StatelessWidget {
  const _PinDots({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final filled = index < value.length;
        return Container(
          width: 18,
          height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: filled ? const Color(0xFFF97316) : const Color(0xFFE5E7EB),
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}
