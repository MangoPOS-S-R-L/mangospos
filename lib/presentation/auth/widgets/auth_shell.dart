import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mangopos/app/theme/mango_tokens.dart';

class AuthShellStep {
  final String title;
  final bool complete;

  const AuthShellStep({required this.title, this.complete = false});
}

class AuthShell extends StatelessWidget {
  final String brandSubtitle;
  final List<AuthShellStep>? steps;
  final int currentStep;
  final Widget main;
  final Widget side;

  const AuthShell({
    super.key,
    required this.brandSubtitle,
    required this.main,
    required this.side,
    this.steps,
    this.currentStep = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MangoTokens.background,
      body: SafeArea(
        child: Center(
            child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: MangoTokens.card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: MangoTokens.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0D231D1A),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final isWide = constraints.maxWidth >= 1040;
                    return Column(
                      children: [
                        _Header(
                          brandSubtitle: brandSubtitle,
                          steps: steps,
                          currentStep: currentStep,
                        ),
                        Expanded(
                          child: isWide
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      flex: 12,
                                      child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        32,
                                        30,
                                        32,
                                        30,
                                      ),
                                        child: main,
                                      ),
                                    ),
                                    Container(
                                      width: 1,
                                      color: MangoTokens.border,
                                    ),
                                    Expanded(
                                      flex: 8,
                                      child: Container(
                                        color: const Color(0xFFFFFCFA),
                                        child: Padding(
                                          padding: const EdgeInsets.all(24),
                                          child: side,
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : SingleChildScrollView(
                                  padding: const EdgeInsets.all(24),
                                  child: Column(
                                    children: [
                                      main,
                                      const SizedBox(height: 24),
                                      side,
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuthInfoCard extends StatelessWidget {
  final String title;
  final String body;
  final IconData icon;
  final Color accent;

  const AuthInfoCard({
    super.key,
    required this.title,
    required this.body,
    required this.icon,
    this.accent = MangoTokens.primary,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MangoTokens.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: MangoTokens.foreground,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    style: GoogleFonts.plusJakartaSans(
                      fontSize: 13,
                      height: 1.5,
                      color: MangoTokens.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AuthSummaryCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const AuthSummaryCard({
    super.key,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: MangoTokens.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: MangoTokens.foreground,
              ),
            ),
            const SizedBox(height: 20),
            ...children,
          ],
        ),
      ),
    );
  }
}

class AuthSummaryRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const AuthSummaryRow({
    super.key,
    required this.label,
    required this.value,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final valueColor = highlight
        ? MangoTokens.primary
        : MangoTokens.foreground;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: MangoTokens.mutedForeground,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 14,
                fontWeight: highlight ? FontWeight.w700 : FontWeight.w600,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String brandSubtitle;
  final List<AuthShellStep>? steps;
  final int currentStep;

  const _Header({
    required this.brandSubtitle,
    required this.steps,
    required this.currentStep,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
        color: Colors.transparent,
        border: Border(
          bottom: BorderSide(color: MangoTokens.border, width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x1A000000),
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        'assets/images/Logo Completo.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
          const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: TextSpan(
                          style: GoogleFonts.plusJakartaSans(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                          children: [
                            TextSpan(
                              text: 'Crea tu cuenta en ',
                              style: TextStyle(color: MangoTokens.foreground),
                            ),
                            TextSpan(
                              text: 'Mango',
                              style: TextStyle(color: MangoTokens.primary),
                            ),
                            TextSpan(
                              text: 'POS',
                              style: TextStyle(color: const Color(0xFF2BA85A)),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        brandSubtitle,
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: MangoTokens.mutedForeground,
                        ),
                      ),
                    ],
                  ),
          const Spacer(),
          if (steps != null)
            _StepsRow(
              steps: steps!,
              currentStep: currentStep,
            ),
        ],
      ),
    );
  }
}

class _StepsRow extends StatelessWidget {
  final List<AuthShellStep> steps;
  final int currentStep;

  const _StepsRow({
    required this.steps,
    required this.currentStep,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(steps.length * 2 - 1, (index) {
          if (index.isOdd) {
            return Container(
              width: 40,
              height: 1,
              color: MangoTokens.border,
              margin: const EdgeInsets.symmetric(horizontal: 12),
            );
          }
          final stepIndex = index ~/ 2;
          final step = steps[stepIndex];
          final isCurrent = stepIndex == currentStep;
          final isComplete = step.complete || stepIndex < currentStep;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: isCurrent || isComplete
                      ? MangoTokens.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: isCurrent || isComplete
                        ? MangoTokens.primary
                        : MangoTokens.border,
                  ),
                ),
                child: Center(
                  child: isComplete
                      ? const Icon(Icons.check_rounded,
                          color: Colors.white, size: 18)
                      : Text(
                          '${stepIndex + 1}',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isCurrent
                              ? Colors.white
                              : MangoTokens.mutedForeground,
                        ),
                        ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                step.title,
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 13,
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                  color: isCurrent
                      ? MangoTokens.foreground
                      : MangoTokens.mutedForeground,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}
