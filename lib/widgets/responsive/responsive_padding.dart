import 'package:flutter/material.dart';

import '../../utils/responsive_utils.dart';

class ResponsivePadding extends StatelessWidget {
  final Widget child;
  final double? horizontalPercent;
  final double? verticalPercent;
  final EdgeInsetsGeometry? padding;

  const ResponsivePadding({
    super.key,
    required this.child,
    this.horizontalPercent,
    this.verticalPercent,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    EdgeInsetsGeometry resolved = padding ?? EdgeInsets.zero;

    if (padding == null) {
      final horizontal = horizontalPercent != null
          ? context.wp(horizontalPercent!)
          : 0.0;
      final vertical = verticalPercent != null
          ? context.hp(verticalPercent!)
          : 0.0;
      resolved = EdgeInsets.symmetric(
        horizontal: horizontal,
        vertical: vertical,
      );
    }

    return Padding(padding: resolved, child: child);
  }
}