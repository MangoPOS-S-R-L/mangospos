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
            constraints: const BoxConstraints(maxWidth: 1280),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: MangoTokens.card,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: MangoTokens.border),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x0D231D1A),
                      blurRadius: 24,
                      offset: Offset(0, 10),
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
                                          44,
                                          40,
                                          44,
                                          40,
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
                                          padding: const EdgeInsets.all(32),
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
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MangoTokens.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inlineSteps = steps != null && constraints.maxWidth >= 920;
          return Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          MangoTokens.primary,
                          Color(0xFFF59F0A),
                        ],
                      ),
                    ),
                    child: const Icon(
                      Icons.storefront_rounded,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MangoPOS',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: MangoTokens.foreground,
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
                  if (inlineSteps)
                    Flexible(
                      child: _Steps(steps: steps!, currentStep: currentStep),
                    ),
                ],
              ),
              if (!inlineSteps && steps != null) ...[
                const SizedBox(height: 18),
                _Steps(steps: steps!, currentStep: currentStep),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  final List<AuthShellStep> steps;
  final int currentStep;

  const _Steps({required this.steps, required this.currentStep});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 14,
      runSpacing: 8,
      children: List.generate(steps.length, (index) {
        final step = steps[index];
        final isCurrent = index == currentStep;
        final isComplete = step.complete || index < currentStep;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
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
                    ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
                    : Text(
                        '${index + 1}',
                        style: GoogleFonts.plusJakartaSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: isCurrent ? Colors.white : MangoTokens.mutedForeground,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              step.title,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 14,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                color: isCurrent
                    ? MangoTokens.foreground
                    : MangoTokens.mutedForeground,
              ),
            ),
          ],
        );
      }),
    );
  }
}
