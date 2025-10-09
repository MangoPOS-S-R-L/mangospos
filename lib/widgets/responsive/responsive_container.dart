import 'package:flutter/material.dart';

import '../../utils/responsive_utils.dart';

class ResponsiveContainer extends StatelessWidget {
  final Widget? child;
  final double? widthPercent;
  final double? heightPercent;
  final double? maxWidth;
  final double? maxHeight;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry? alignment;
  final Decoration? decoration;
  final BoxConstraints? constraints;
  final EdgeInsetsGeometry? margin;

  const ResponsiveContainer({
    super.key,
    this.child,
    this.widthPercent,
    this.heightPercent,
    this.maxWidth,
    this.maxHeight,
    this.padding,
    this.alignment,
    this.decoration,
    this.constraints,
    this.margin,
  });

  double _defaultMaxWidth(BuildContext context) {
    switch (context.deviceType) {
      case DeviceType.mobile:
        return context.screenSize.width;
      case DeviceType.tablet:
        return 720;
      case DeviceType.desktop:
        return 1100;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = widthPercent != null ? context.wp(widthPercent!) : null;
    final height = heightPercent != null ? context.hp(heightPercent!) : null;
    final boxConstraints = constraints ??
        BoxConstraints(
          maxWidth: maxWidth ?? _defaultMaxWidth(context),
          maxHeight: maxHeight ?? double.infinity,
        );

    return Container(
      width: width,
      height: height,
      padding: padding,
      alignment: alignment,
      decoration: decoration,
      constraints: boxConstraints,
      margin: margin,
      child: child,
    );
  }
}
