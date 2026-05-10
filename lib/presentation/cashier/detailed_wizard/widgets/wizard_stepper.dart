import 'package:flutter/material.dart';

import 'package:mangopos/app/theme/mango_colors.dart';

/// Stepper de progreso. Cada columna muestra una barra horizontal de 3 px
/// (verde para reached, gris para pending) y un label `N · Texto` debajo.
///
/// Estilo inspirado en el mock del PRD: minimalista, sin círculos.
class WizardStepper extends StatelessWidget {
  const WizardStepper({
    super.key,
    required this.labels,
    required this.currentStep,
  });

  final List<String> labels;
  final int currentStep;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: MangoColors.white,
        border: Border(bottom: BorderSide(color: MangoColors.cardBorder)),
      ),
      child: Row(
        children: List.generate(labels.length, (i) {
          final reached = i <= currentStep;
          final active = i == currentStep;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: i == labels.length - 1 ? 0 : 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: reached
                          ? MangoColors.successGreen
                          : MangoColors.cardBorder,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${i + 1} · ${labels[i]}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: reached
                          ? MangoColors.darkGray
                          : MangoColors.muted,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
