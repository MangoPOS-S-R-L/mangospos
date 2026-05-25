import 'package:flutter/material.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_spacing.dart';

/// Skeleton genérico para los reportes — se muestra mientras los datos
/// están cargando por primera vez (cuando aún no hay snapshot en
/// memoria). Refleja la forma general de los reportes: 4 stat cards
/// arriba, un chart grande, y 3 tablas/listados horizontales abajo.
///
/// La animación de shimmer corre con un único AnimationController que
/// se cancela cuando el widget se desmonta — sin Timer, sin
/// dependencias externas.
class ReportSkeletonView extends StatefulWidget {
  const ReportSkeletonView({super.key});

  @override
  State<ReportSkeletonView> createState() => _ReportSkeletonViewState();
}

class _ReportSkeletonViewState extends State<ReportSkeletonView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1400),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = ResponsiveHelper.isMobile(context);
    final pad = isMobile ? 12.0 : AppSpacing.containerPadding;

    return SingleChildScrollView(
      padding: EdgeInsets.all(pad),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => _SkeletonBody(
          progress: _controller.value,
          isMobile: isMobile,
        ),
      ),
    );
  }
}

class _SkeletonBody extends StatelessWidget {
  const _SkeletonBody({required this.progress, required this.isMobile});

  final double progress;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    final crossAxisCount = isMobile ? 2 : 4;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 4 stat cards arriba
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          mainAxisSpacing: AppSpacing.itemGap,
          crossAxisSpacing: AppSpacing.itemGap,
          childAspectRatio: isMobile ? 1.6 : 2.1,
          children: List.generate(
            4,
            (_) => _SkeletonCard(progress: progress, height: 80),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        // Chart grande
        _SkeletonCard(progress: progress, height: isMobile ? 200 : 260),
        const SizedBox(height: AppSpacing.lg),
        // 3 listas/tablas
        ...List.generate(
          3,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.itemGap),
            child: _SkeletonCard(progress: progress, height: isMobile ? 90 : 110),
          ),
        ),
      ],
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard({required this.progress, required this.height});

  final double progress;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      clipBehavior: Clip.antiAlias,
      child: CustomPaint(
        painter: _ShimmerPainter(progress: progress),
        child: const SizedBox.expand(),
      ),
    );
  }
}

/// Pinta un gradiente diagonal que se mueve de izquierda a derecha,
/// reciclándose. Lo hacemos con CustomPainter en vez de ShaderMask
/// para evitar el overhead de re-evaluar layout en cada frame.
class _ShimmerPainter extends CustomPainter {
  _ShimmerPainter({required this.progress});

  final double progress;

  static const _baseColor = Color(0xFFF1F2F4);
  static const _highlightColor = Color(0xFFE5E7EB);

  @override
  void paint(Canvas canvas, Size size) {
    final basePaint = Paint()..color = _baseColor;
    canvas.drawRect(Offset.zero & size, basePaint);

    // El highlight se mueve de -1.0 (fuera, izquierda) a 2.0 (fuera, derecha).
    final shift = -1.0 + progress * 3.0;
    final startX = shift * size.width;
    final endX = startX + size.width * 0.6;

    final gradient = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: const [_baseColor, _highlightColor, _baseColor],
      stops: const [0.0, 0.5, 1.0],
    );

    final rect = Rect.fromLTWH(startX, 0, endX - startX, size.height);
    final shimmerPaint = Paint()..shader = gradient.createShader(rect);
    canvas.drawRect(rect, shimmerPaint);
  }

  @override
  bool shouldRepaint(covariant _ShimmerPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
