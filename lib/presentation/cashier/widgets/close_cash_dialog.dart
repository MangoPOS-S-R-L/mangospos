import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/utils/responsive_utils.dart';

class CloseCashDialog extends ConsumerStatefulWidget {
  final String sessionId;

  const CloseCashDialog({super.key, required this.sessionId});

  @override
  ConsumerState<CloseCashDialog> createState() => _CloseCashDialogState();
}

class _CloseCashDialogState extends ConsumerState<CloseCashDialog> {
  String _amount = '0';
  bool _isSubmitting = false;
  bool _isLoadingSummary = true;
  Map<String, dynamic>? _sessionSummary;
  final TextEditingController _notesController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSessionSummary();
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _loadSessionSummary() async {
    try {
      final repository = ref.read(cashierRepositoryProvider);
      final summary = await repository.getSessionSummary(widget.sessionId);

      setState(() {
        _sessionSummary = summary;
        _isLoadingSummary = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingSummary = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error cargando resumen: ${e.toString()}'),
            backgroundColor: Colors.red[600],
          ),
        );
      }
    }
  }

  void _onKeyTap(String value) {
    if (_isSubmitting) return;

    setState(() {
      if (value == 'backspace') {
        if (_amount.length > 1) {
          _amount = _amount.substring(0, _amount.length - 1);
        } else {
          _amount = '0';
        }
      } else if (value == '00') {
        if (_amount != '0') _amount += '00';
      } else {
        if (_amount == '0') {
          _amount = value;
        } else {
          _amount += value;
        }
      }
    });
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;

    final double endAmount = double.tryParse(_amount) ?? 0;

    setState(() {
      _isSubmitting = true;
    });

    try {
      final repository = ref.read(cashierRepositoryProvider);
      await repository.closeSession(
        sessionId: widget.sessionId,
        endAmount: endAmount,
        notes: _notesController.text.trim().isEmpty
            ? null
            : _notesController.text.trim(),
      );

      // Refresh the cashier viewmodel
      await ref.read(cashierViewModelProvider).init();

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: context.wp(2)),
                const Expanded(
                  child: Text(
                    'Caja cerrada exitosamente',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: MangoColors.successGreen,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isSubmitting = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.white),
                SizedBox(width: context.wp(2)),
                Expanded(
                  child: Text(
                    'Error: ${e.toString()}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: Colors.red[600],
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final double endAmount = double.tryParse(_amount) ?? 0;
    final formatted = NumberFormat.currency(
      symbol: 'RD\$',
      decimalDigits: 2,
    ).format(endAmount);

    final startAmount = _sessionSummary?['start_amount'] ?? 0.0;
    final totalIncome = _sessionSummary?['total_income'] ?? 0.0;
    final totalExpenses = _sessionSummary?['total_expenses'] ?? 0.0;
    final expectedAmount =
        (startAmount as num) + (totalIncome as num) - (totalExpenses as num);
    final difference = endAmount - expectedAmount;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        width: context.wp(50),
        constraints: BoxConstraints(maxWidth: 650, maxHeight: context.hp(90)),
        padding: EdgeInsets.all(context.wp(3)),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: _isLoadingSummary
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                      color: MangoColors.primaryOrange,
                      strokeWidth: 3,
                    ),
                    SizedBox(height: context.hp(2)),
                    Text(
                      'Cargando resumen de caja...',
                      style: TextStyle(
                        fontSize: context.sp(14),
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Header
                    Row(
                      children: [
                        Container(
                          padding: EdgeInsets.all(context.wp(1.5)),
                          decoration: BoxDecoration(
                            color: Colors.red.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(
                            Icons.lock_rounded,
                            color: Colors.red[600],
                            size: context.iconSizeOf(32),
                          ),
                        ),
                        SizedBox(width: context.wp(2)),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Cierre de caja',
                                style: TextStyle(
                                  fontSize: context.sp(22),
                                  fontWeight: FontWeight.w800,
                                  color: MangoColors.darkGray,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              Text(
                                'Finalizar turno y cuadrar',
                                style: TextStyle(
                                  fontSize: context.sp(12),
                                  color: Colors.grey[600],
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: _isSubmitting
                              ? null
                              : () => Navigator.of(context).pop(),
                          icon: Icon(
                            Icons.close_rounded,
                            color: Colors.grey[400],
                          ),
                          iconSize: context.iconSizeOf(24),
                        ),
                      ],
                    ),
                    SizedBox(height: context.hp(2.5)),

                    // Session Summary Cards
                    Container(
                      padding: EdgeInsets.all(context.wp(2)),
                      decoration: BoxDecoration(
                        color: Colors.grey[50],
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.grey[200]!,
                          width: 1.5,
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _SummaryItem(
                                  label: 'Monto Inicial',
                                  value: NumberFormat.currency(
                                    symbol: 'RD\$',
                                    decimalDigits: 0,
                                  ).format(startAmount),
                                  icon: Icons.play_circle_outline_rounded,
                                  color: Colors.blue[600]!,
                                ),
                              ),
                              SizedBox(width: context.wp(2)),
                              Expanded(
                                child: _SummaryItem(
                                  label: 'Ingresos',
                                  value: NumberFormat.currency(
                                    symbol: 'RD\$',
                                    decimalDigits: 0,
                                  ).format(totalIncome),
                                  icon: Icons.arrow_downward_rounded,
                                  color: MangoColors.successGreen,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: context.hp(1.5)),
                          Row(
                            children: [
                              Expanded(
                                child: _SummaryItem(
                                  label: 'Egresos',
                                  value: NumberFormat.currency(
                                    symbol: 'RD\$',
                                    decimalDigits: 0,
                                  ).format(totalExpenses),
                                  icon: Icons.arrow_upward_rounded,
                                  color: Colors.red[600]!,
                                ),
                              ),
                              SizedBox(width: context.wp(2)),
                              Expanded(
                                child: _SummaryItem(
                                  label: 'Esperado',
                                  value: NumberFormat.currency(
                                    symbol: 'RD\$',
                                    decimalDigits: 0,
                                  ).format(expectedAmount),
                                  icon: Icons.calculate_rounded,
                                  color: MangoColors.primaryOrange,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: context.hp(2.5)),

                    // Amount input section
                    Text(
                      'Monto Final en Caja',
                      style: TextStyle(
                        fontSize: context.sp(14),
                        fontWeight: FontWeight.w700,
                        color: Colors.grey[700],
                      ),
                    ),
                    SizedBox(height: context.hp(1)),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: context.wp(2.5),
                        vertical: context.hp(1.8),
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.red.withOpacity(0.2),
                          width: 2,
                        ),
                      ),
                      child: Text(
                        formatted,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: context.sp(38),
                          fontWeight: FontWeight.w900,
                          color: Colors.red[700],
                          letterSpacing: -1,
                        ),
                      ),
                    ),
                    SizedBox(height: context.hp(1.5)),

                    // Difference indicator
                    if (_amount != '0')
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: context.wp(2),
                          vertical: context.hp(1),
                        ),
                        decoration: BoxDecoration(
                          color: difference == 0
                              ? MangoColors.successGreen.withOpacity(0.1)
                              : (difference > 0
                                    ? Colors.blue.withOpacity(0.1)
                                    : Colors.orange.withOpacity(0.1)),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: difference == 0
                                ? MangoColors.successGreen.withOpacity(0.3)
                                : (difference > 0
                                      ? Colors.blue.withOpacity(0.3)
                                      : Colors.orange.withOpacity(0.3)),
                            width: 1.5,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              difference == 0
                                  ? Icons.check_circle_outline_rounded
                                  : (difference > 0
                                        ? Icons.arrow_upward_rounded
                                        : Icons.arrow_downward_rounded),
                              size: context.iconSizeOf(18),
                              color: difference == 0
                                  ? MangoColors.successGreen
                                  : (difference > 0
                                        ? Colors.blue[700]
                                        : Colors.orange[700]),
                            ),
                            SizedBox(width: context.wp(1)),
                            Text(
                              difference == 0
                                  ? 'Cuadrado perfectamente'
                                  : (difference > 0
                                        ? 'Sobrante: ${NumberFormat.currency(symbol: 'RD\$', decimalDigits: 0).format(difference.abs())}'
                                        : 'Faltante: ${NumberFormat.currency(symbol: 'RD\$', decimalDigits: 0).format(difference.abs())}'),
                              style: TextStyle(
                                fontSize: context.sp(13),
                                fontWeight: FontWeight.w700,
                                color: difference == 0
                                    ? MangoColors.successGreen
                                    : (difference > 0
                                          ? Colors.blue[700]
                                          : Colors.orange[700]),
                              ),
                            ),
                          ],
                        ),
                      ),
                    SizedBox(height: context.hp(2)),

                    // Numpad
                    SizedBox(
                      height: context.hp(32),
                      child: Column(
                        children: [
                          _numpadRow(['1', '2', '3']),
                          _numpadRow(['4', '5', '6']),
                          _numpadRow(['7', '8', '9']),
                          _numpadRow(['00', '0', 'backspace']),
                        ],
                      ),
                    ),
                    SizedBox(height: context.hp(2)),

                    // Notes field
                    TextField(
                      controller: _notesController,
                      enabled: !_isSubmitting,
                      maxLines: 2,
                      decoration: InputDecoration(
                        labelText: 'Notas (opcional)',
                        hintText: 'Ej: Todo en orden, sin novedades',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Colors.grey[300]!,
                            width: 1.5,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Colors.grey[300]!,
                            width: 1.5,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                            color: MangoColors.primaryOrange,
                            width: 2,
                          ),
                        ),
                        filled: true,
                        fillColor: Colors.grey[50],
                      ),
                    ),
                    SizedBox(height: context.hp(2.5)),

                    // Action buttons
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _isSubmitting
                                ? null
                                : () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.symmetric(
                                vertical: context.hp(1.8),
                              ),
                              side: BorderSide(
                                color: Colors.grey.shade300,
                                width: 1.5,
                              ),
                              foregroundColor: Colors.black87,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'Cancelar',
                              style: TextStyle(
                                fontSize: context.sp(14),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: context.wp(2)),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton.icon(
                            onPressed: _isSubmitting ? null : _submit,
                            icon: _isSubmitting
                                ? SizedBox(
                                    width: context.iconSizeOf(16),
                                    height: context.iconSizeOf(16),
                                    child: const CircularProgressIndicator(
                                      color: Colors.white,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    Icons.check_circle_rounded,
                                    size: context.iconSizeOf(20),
                                  ),
                            label: Text(
                              _isSubmitting ? 'Cerrando...' : 'Cerrar Caja',
                              style: TextStyle(
                                fontSize: context.sp(14),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              padding: EdgeInsets.symmetric(
                                vertical: context.hp(1.8),
                              ),
                              backgroundColor: Colors.red[600],
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.grey[300],
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _numpadRow(List<String> keys) {
    return Expanded(
      child: Row(
        children: keys.map((key) {
          return Expanded(
            child: Padding(
              padding: EdgeInsets.all(context.wp(0.5)),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _isSubmitting ? null : () => _onKeyTap(key),
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    decoration: BoxDecoration(
                      color: _isSubmitting ? Colors.grey[100] : Colors.grey[50],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.grey.shade300,
                        width: 1.5,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: key == 'backspace'
                        ? Icon(
                            Icons.backspace_outlined,
                            color: _isSubmitting
                                ? Colors.grey[400]
                                : Colors.black87,
                            size: context.iconSizeOf(20),
                          )
                        : Text(
                            key,
                            style: TextStyle(
                              fontSize: context.sp(20),
                              fontWeight: FontWeight.w800,
                              color: _isSubmitting
                                  ? Colors.grey[400]
                                  : Colors.black87,
                              letterSpacing: -0.5,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _SummaryItem({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(context.wp(1.5)),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2), width: 1.5),
      ),
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: context.iconSizeOf(14), color: color),
              SizedBox(width: context.wp(0.8)),
              Text(
                label,
                style: TextStyle(
                  fontSize: context.sp(10),
                  color: Colors.grey[700],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          SizedBox(height: context.hp(0.5)),
          Text(
            value,
            style: TextStyle(
              fontSize: context.sp(14),
              fontWeight: FontWeight.w800,
              color: color,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }
}
