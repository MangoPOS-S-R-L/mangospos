import 'package:flutter/material.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_radius.dart';
import 'package:mangopos/core/theme/app_shadows.dart';

/// Hoverable Card with spec-defined shadows and animations
/// Per UI Spec 1.4.1 (Shadow Specifications) and 3.2.1 (Small Action Card)
class HoverableCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color? borderColor;

  const HoverableCard({
    super.key,
    required this.child,
    this.onTap,
    this.borderColor,
  });

  @override
  State<HoverableCard> createState() => _HoverableCardState();
}

class _HoverableCardState extends State<HoverableCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          // Spec: hover:-translate-y-1 (4px lift on hover)
          transform: _isHovered
              ? (Matrix4.identity()..translate(0.0, -4.0))
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: Colors.white,
            // Spec 1.5.1: Cards use rounded-xl (12px)
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              // Spec: hover:border-primary/40
              color: _isHovered
                  ? (widget.borderColor ?? AppColors.primary.withOpacity(0.4))
                  : AppColors.border,
              width: 1.0,
            ),
            // Spec 1.4.1: Default soft shadow → elevated shadow on hover
            boxShadow: _isHovered
                ? AppShadows.cardInteractive
                : AppShadows.soft,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
