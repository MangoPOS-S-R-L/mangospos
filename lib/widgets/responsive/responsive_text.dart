import 'package:flutter/material.dart';

import '../../utils/responsive_utils.dart';

class ResponsiveText extends StatelessWidget {
  final String data;
  final TextStyle? style;
  final double? fontSize;
  final TextAlign? textAlign;
  final TextOverflow? overflow;
  final int? maxLines;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final bool? softWrap;
  final Locale? locale;
  final StrutStyle? strutStyle;
  final TextDirection? textDirection;
  final double scale;

  const ResponsiveText(
    this.data, {
    super.key,
    this.style,
    this.fontSize,
    this.textAlign,
    this.overflow,
    this.maxLines,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.softWrap,
    this.locale,
    this.strutStyle,
    this.textDirection,
    this.scale = 1,
  });

  @override
  Widget build(BuildContext context) {
    final baseStyle = style ?? DefaultTextStyle.of(context).style;
    final baseSize = fontSize ?? baseStyle.fontSize ?? 14;
    final scaledSize = context.sp(baseSize) * scale;
    final mergedStyle = baseStyle.copyWith(fontSize: scaledSize);

    return Text(
      data,
      style: mergedStyle,
      textAlign: textAlign,
      overflow: overflow,
      maxLines: maxLines,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      softWrap: softWrap,
      locale: locale,
      strutStyle: strutStyle,
      textDirection: textDirection,
    );
  }
}
