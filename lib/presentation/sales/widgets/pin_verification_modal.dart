import 'package:flutter/material.dart';
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

  void _onNumberTap(String number) {
    if (_verifying) return;
    if (_controller.text.length < 4) {
      setState(() {
        _localError = null;
        _controller.text += number;
      });
      if (_controller.text.length == 4) {
        _verify();
      }
    }
  }

  void _onBackspaceTap() {
    if (_verifying) return;
    if (_controller.text.isNotEmpty) {
      setState(() {
        _localError = null;
        _controller.text =
            _controller.text.substring(0, _controller.text.length - 1);
      });
    }
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
          _controller.clear();
          _localError = widget.invalidMessage;
          _focusNode.requestFocus();
        });
        return;
      }
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _controller.clear();
        _localError = 'No se pudo validar el PIN.';
        _focusNode.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: Colors.transparent,
      child: GestureDetector(
        onTap: () {
          if (!_focusNode.hasFocus) _focusNode.requestFocus();
        },
        child: Container(
          width: 380,
          padding: const EdgeInsets.all(32),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 32,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Stack(
            children: [
              // TextField oculto para capturar teclado físico.
              // Va envuelto en SizedBox(100x40) porque el Positioned
              // sin left/right/width le pasa width=infinity al
              // TextField y crashea con 'InputDecorator cannot have
              // an unbounded width'. Aparecía cuando este modal se
              // abre encima de otro dialog (e.g. transferir mesa).
              Positioned(
                top: -1000,
                child: Opacity(
                  opacity: 0,
                  child: SizedBox(
                    width: 100,
                    height: 40,
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      keyboardType: TextInputType.none,
                      maxLength: 4,
                      autofocus: true,
                      onChanged: (val) {
                        setState(() {
                          _localError = null;
                        });
                        if (val.length == 4) {
                          _verify();
                        }
                      },
                    ),
                  ),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Botón de cerrar superior
                  Align(
                    alignment: Alignment.topRight,
                    child: IconButton(
                      icon: const Icon(Icons.close_rounded,
                          color: Color(0xFF6B7280)),
                      onPressed: () => Navigator.of(context).pop(false),
                    ),
                  ),

                  // Títulos
                  Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF111827),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.subtitle,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF6B7280),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Cajas de los 4 dígitos
                  _PinBoxes(value: _controller.text, isError: _localError != null),

                  if (_localError != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _localError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFE11D48),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],

                  const SizedBox(height: 32),

                  // Teclado numérico interactivo
                  if (_verifying)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: CircularProgressIndicator(color: Color(0xFFF97316)),
                      ),
                    )
                  else
                    _NumericKeypad(
                      onNumberTap: _onNumberTap,
                      onBackspaceTap: _onBackspaceTap,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PinBoxes extends StatelessWidget {
  const _PinBoxes({required this.value, required this.isError});

  final String value;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (index) {
        final filled = index < value.length;
        final hasBorder = index == value.length; // Cajita actual seleccionada

        Color borderColor = const Color(0xFFE5E7EB);
        if (isError) {
          borderColor = const Color(0xFFE11D48);
        } else if (hasBorder) {
          borderColor = const Color(0xFFF97316); 
        }

        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 56,
          height: 64,
          margin: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: borderColor,
              width: hasBorder || isError ? 2.5 : 1.5,
            ),
            boxShadow: hasBorder && !isError
                ? [
                    BoxShadow(
                      color: const Color(0xFFF97316).withValues(alpha: 0.15),
                      blurRadius: 12,
                      spreadRadius: 2,
                    )
                  ]
                : [],
          ),
          child: Center(
            child: AnimatedScale(
              scale: filled ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: isError ? const Color(0xFFE11D48) : const Color(0xFF111827),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _NumericKeypad extends StatelessWidget {
  const _NumericKeypad({
    required this.onNumberTap,
    required this.onBackspaceTap,
  });

  final void Function(String) onNumberTap;
  final VoidCallback onBackspaceTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildRow(['1', '2', '3']),
        const SizedBox(height: 16),
        _buildRow(['4', '5', '6']),
        const SizedBox(height: 16),
        _buildRow(['7', '8', '9']),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _buildKeypadButton(null, icon: Icons.fingerprint_rounded),
            _buildKeypadButton('0'),
            _buildKeypadButton(null, icon: Icons.backspace_outlined, onTap: onBackspaceTap),
          ],
        ),
      ],
    );
  }

  Widget _buildRow(List<String> numbers) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: numbers.map((n) => _buildKeypadButton(n)).toList(),
    );
  }

  Widget _buildKeypadButton(String? text, {IconData? icon, VoidCallback? onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap ?? (text != null ? () => onNumberTap(text) : null),
        borderRadius: BorderRadius.circular(40),
        splashColor: const Color(0xFFF97316).withValues(alpha: 0.2),
        highlightColor: const Color(0xFFF97316).withValues(alpha: 0.1),
        child: Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFF3F4F6).withValues(alpha: 0.5), // fondo súper sutil
          ),
          child: text != null
              ? Text(
                  text,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                  ),
                )
              : Icon(
                  icon,
                  size: 28,
                  color: const Color(0xFF6B7280),
                ),
        ),
      ),
    );
  }
}
