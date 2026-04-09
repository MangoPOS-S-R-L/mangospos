import 'package:flutter/material.dart';

/// A shimmer-animated skeleton placeholder for loading states.
/// Use instead of CircularProgressIndicator for a smoother UX.
class SkeletonBox extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const SkeletonBox({
    super.key,
    this.width = double.infinity,
    required this.height,
    this.borderRadius = 12,
  });

  @override
  Widget build(BuildContext context) {
    return _ShimmerWrap(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFFE0E0E0),
          borderRadius: BorderRadius.circular(borderRadius),
        ),
      ),
    );
  }
}

/// Skeleton that mimics the CashierView layout during initial load.
class CashierSkeleton extends StatelessWidget {
  const CashierSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F2),
      body: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header skeleton
            const SkeletonBox(height: 100),
            const SizedBox(height: 20),
            // Stats cards row
            Row(
              children: const [
                Expanded(child: SkeletonBox(height: 110)),
                SizedBox(width: 12),
                Expanded(child: SkeletonBox(height: 110)),
                SizedBox(width: 12),
                Expanded(child: SkeletonBox(height: 110)),
              ],
            ),
            const SizedBox(height: 20),
            // Action cards 2x2
            Row(
              children: const [
                Expanded(child: SkeletonBox(height: 100)),
                SizedBox(width: 12),
                Expanded(child: SkeletonBox(height: 100)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: const [
                Expanded(child: SkeletonBox(height: 100)),
                SizedBox(width: 12),
                Expanded(child: SkeletonBox(height: 100)),
              ],
            ),
            const SizedBox(height: 20),
            // Recent movements list
            const SkeletonBox(height: 24, width: 180, borderRadius: 6),
            const SizedBox(height: 12),
            for (int i = 0; i < 4; i++) ...[
              const SkeletonBox(height: 56),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

/// Skeleton that mimics the SalesByZoneView table grid during load.
class ZoneGridSkeleton extends StatelessWidget {
  const ZoneGridSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // Tab bar skeleton
          Row(
            children: [
              for (int i = 0; i < 3; i++) ...[
                SkeletonBox(width: 80, height: 36, borderRadius: 8),
                if (i < 2) const SizedBox(width: 8),
              ],
              const Spacer(),
              const SkeletonBox(width: 120, height: 28, borderRadius: 8),
            ],
          ),
          const SizedBox(height: 24),
          // Grid skeleton
          Expanded(
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                childAspectRatio: 1.6,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: 12,
              itemBuilder: (_, __) => const SkeletonBox(height: 140),
            ),
          ),
        ],
      ),
    );
  }
}

/// Skeleton for a single zone's table grid (used inside TabBarView).
class ZoneTablesSkeleton extends StatelessWidget {
  const ZoneTablesSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(24),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 1.6,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: 8,
      itemBuilder: (_, __) => const SkeletonBox(height: 140),
    );
  }
}

/// Wraps a child with a shimmer animation effect.
class _ShimmerWrap extends StatefulWidget {
  final Widget child;
  const _ShimmerWrap({required this.child});

  @override
  State<_ShimmerWrap> createState() => _ShimmerWrapState();
}

class _ShimmerWrapState extends State<_ShimmerWrap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _animation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: const [
                Color(0xFFE0E0E0),
                Color(0xFFF5F5F5),
                Color(0xFFE0E0E0),
              ],
              stops: [
                _animation.value - 0.3,
                _animation.value,
                _animation.value + 0.3,
              ],
            ).createShader(bounds);
          },
          blendMode: BlendMode.srcATop,
          child: child!,
        );
      },
      child: widget.child,
    );
  }
}
