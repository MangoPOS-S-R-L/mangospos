import 'package:flutter/material.dart';
import 'package:mangopos/app/theme/mango_colors.dart';

class NumpadWidget extends StatelessWidget {
  final ValueChanged<String> onTap;
  final bool includeClear;

  const NumpadWidget({
    super.key,
    required this.onTap,
    this.includeClear = false,
  });

  @override
  Widget build(BuildContext context) {
    final keys = <String>[
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '.',
      '0',
      'backspace',
      if (includeClear) 'clear',
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: keys.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 2.4,
      ),
      itemBuilder: (context, index) {
        final value = keys[index];
        final label = switch (value) {
          'backspace' => '⌫',
          'clear' => 'C',
          _ => value,
        };
        final isAction = value == 'backspace' || value == 'clear';
        return FilledButton(
          onPressed: () => onTap(value),
          style: FilledButton.styleFrom(
            elevation: 0,
            backgroundColor: isAction
                ? Colors.red.withValues(alpha: 0.08)
                : Colors.white,
            foregroundColor: isAction ? Colors.red : MangoColors.darkGray,
            padding: EdgeInsets.zero,
            minimumSize: const Size(0, 32),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: isAction
                    ? Colors.red.withValues(alpha: 0.25)
                    : MangoColors.cardBorder,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: isAction ? Colors.red : MangoColors.darkGray,
            ),
          ),
        );
      },
    );
  }
}
