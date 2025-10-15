import 'package:flutter/material.dart';

enum DeviceType { mobile, tablet, desktop }

extension ResponsiveContext on BuildContext {
  MediaQueryData get _mq => MediaQuery.of(this);
  Size get screenSize => _mq.size;
  double get shortestSide => screenSize.shortestSide;

  DeviceType get deviceType {
    final width = screenSize.width;
    if (width >= 1100) return DeviceType.desktop;
    if (width >= 700) return DeviceType.tablet;
    return DeviceType.mobile;
  }

  double wp(double percent) => screenSize.width * (percent / 100);
  double hp(double percent) => screenSize.height * (percent / 100);

  double _scaleValue(double mobile, double tablet, double desktop) {
    switch (deviceType) {
      case DeviceType.mobile:
        return mobile;
      case DeviceType.tablet:
        return tablet;
      case DeviceType.desktop:
        return desktop;
    }
  }

  double get iconScale => _scaleValue(0.85, 0.95, 1.0);
  double get textScale => _scaleValue(0.92, 0.98, 1.0);

  double iconSizeOf(double base) => base * iconScale;
  double sp(double fontSize) => fontSize * textScale;

  double get iconSize => iconSizeOf(24);
  double get iconSizeSmall => iconSizeOf(20);
  double get iconSizeLarge => iconSizeOf(32);

  double get smallFont => sp(12);
  double get bodyFont => sp(14);
  double get titleFont => sp(18);
  double get headlineFont => sp(22);

  bool get isMobile => deviceType == DeviceType.mobile;
  bool get isTablet => deviceType == DeviceType.tablet;
  bool get isDesktop => deviceType == DeviceType.desktop;
}