import 'package:flutter/material.dart';

import '../../utils/responsive_utils.dart';

class ResponsiveIcon extends StatelessWidget {
  final IconData icon;
  final double? size;
  final double scale;
  final Color? color;
  final String? semanticLabel;
  final TextDirection? textDirection;
  final List<Shadow>? shadows;

  const ResponsiveIcon({
    super.key,
    required this.icon,
    this.size,
    this.scale = 1.0,
    this.color,
    this.semanticLabel,
    this.textDirection,
    this.shadows,
  });

  @override
  Widget build(BuildContext context) {
    final resolved = context.iconSizeOf(size ?? context.iconSize) * scale;
    return Icon(
      icon,
      size: resolved,
      color: color,
      semanticLabel: semanticLabel,
      textDirection: textDirection,
      shadows: shadows,
    );
  }
}
