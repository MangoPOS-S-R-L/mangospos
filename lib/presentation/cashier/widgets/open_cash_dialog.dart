import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mangopos/presentation/cashier/viewmodel/cashier_viewmodel.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/utils/responsive_utils.dart';

class OpenCashDialog extends ConsumerStatefulWidget {
  const OpenCashDialog({super.key});

  @override
  ConsumerState<OpenCashDialog> createState() => _OpenCashDialogState();
}

class _OpenCashDialogState extends ConsumerState<OpenCashDialog> {
  String _amount = '0';
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    initializeDateFormatting('es');
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
      } else if (value == 'clear') {
        _amount = '0';
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

    final double val = double.tryParse(_amount) ?? 0;

    setState(() {
      _isSubmitting = true;
    });

    try {
      await ref.read(cashierViewModelProvider).openBox(val);
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
                    'Caja abierta exitosamente',
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

  Future<void> _submitWithZero() async {
    setState(() {
      _amount = '0';
    });
    await _submit();
  }

  @override
  Widget build(BuildContext context) {
    final double val = double.tryParse(_amount) ?? 0;
    final formatted = NumberFormat.currency(
      symbol: 'RD\$',
      decimalDigits: 2,
    ).format(val);

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Container(
        width: context.wp(45),
        constraints: BoxConstraints(maxWidth: 550, maxHeight: context.hp(85)),
        padding: EdgeInsets.all(context.wp(3)),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(context.wp(1.5)),
                  decoration: BoxDecoration(
                    color: MangoColors.successGreen.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.lock_open_rounded,
                    color: MangoColors.successGreen,
                    size: context.iconSizeOf(32),
                  ),
                ),
                SizedBox(width: context.wp(2)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Apertura de caja',
                        style: TextStyle(
                          fontSize: context.sp(22),
                          fontWeight: FontWeight.w800,
                          color: MangoColors.darkGray,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Text(
                        'Ingresa un monto para iniciar tu caja',
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
                  icon: Icon(Icons.close_rounded, color: Colors.grey[400]),
                  iconSize: context.iconSizeOf(24),
                ),
              ],
            ),
            SizedBox(height: context.hp(2.5)),

            // Date chip
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.wp(2.5),
                vertical: context.hp(1),
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    MangoColors.primaryOrange.withOpacity(0.1),
                    MangoColors.primaryOrange.withOpacity(0.05),
                  ],
                ),
                borderRadius: BorderRadius.circular(25),
                border: Border.all(
                  color: MangoColors.primaryOrange.withOpacity(0.2),
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.calendar_today_rounded,
                    size: context.iconSizeOf(16),
                    color: MangoColors.primaryOrange,
                  ),
                  SizedBox(width: context.wp(1)),
                  Text(
                    DateFormat('d MMMM, yyyy', 'es').format(DateTime.now()),
                    style: TextStyle(
                      color: MangoColors.primaryOrange,
                      fontSize: context.sp(13),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: context.hp(3)),

            // Amount display
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: context.wp(3),
                vertical: context.hp(2),
              ),
              decoration: BoxDecoration(
                color: MangoColors.successGreen.withOpacity(0.05),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: MangoColors.successGreen.withOpacity(0.2),
                  width: 2,
                ),
              ),
              child: Text(
                formatted,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.sp(42),
                  fontWeight: FontWeight.w900,
                  color: MangoColors.successGreen,
                  letterSpacing: -1,
                ),
              ),
            ),
            SizedBox(height: context.hp(3)),

            // Numpad + OK Button
            Flexible(
              child: SizedBox(
                height: context.hp(42),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        children: [
                          _numpadRow(['1', '2', '3']),
                          _numpadRow(['4', '5', '6']),
                          _numpadRow(['7', '8', '9']),
                          _numpadRow(['00', '0', 'backspace']),
                        ],
                      ),
                    ),
                    SizedBox(width: context.wp(2)),
                    Expanded(
                      flex: 1,
                      child: SizedBox(
                        height: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isSubmitting ? null : _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: MangoColors.successGreen,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: Colors.grey[300],
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            shadowColor: MangoColors.successGreen.withOpacity(
                              0.3,
                            ),
                          ),
                          child: _isSubmitting
                              ? const CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 3,
                                )
                              : Text(
                                  'OK',
                                  style: TextStyle(
                                    fontSize: context.sp(24),
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: context.hp(2.5)),

            // Footer Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isSubmitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: context.hp(1.8)),
                      side: BorderSide(color: Colors.grey.shade300, width: 1.5),
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
                  child: OutlinedButton.icon(
                    onPressed: _isSubmitting ? null : _submitWithZero,
                    icon: Icon(
                      Icons.check_circle_outline_rounded,
                      size: context.iconSizeOf(18),
                    ),
                    label: Text(
                      'Abrir con RD\$0',
                      style: TextStyle(
                        fontSize: context.sp(13),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.symmetric(vertical: context.hp(1.8)),
                      side: BorderSide(
                        color: MangoColors.primaryOrange,
                        width: 1.5,
                      ),
                      foregroundColor: MangoColors.primaryOrange,
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
                            size: context.iconSizeOf(22),
                          )
                        : Text(
                            key,
                            style: TextStyle(
                              fontSize: context.sp(22),
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
