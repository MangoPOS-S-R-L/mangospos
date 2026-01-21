import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';

class ReportsView extends ConsumerWidget {
  const ReportsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(reportsViewModelProvider);
    final viewModel = ref.read(reportsViewModelProvider.notifier);

    return PopScope(
      canPop: state.selectedCategory == null,
      onPopInvoked: (didPop) {
        if (didPop) return;
        viewModel.selectCategory(null);
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (state.selectedCategory != null)
                          Padding(
                            padding: const EdgeInsets.only(right: 16.0),
                            child: IconButton(
                              icon: const Icon(
                                Icons.arrow_back,
                                color: MangoColors.darkGray,
                              ),
                              onPressed: () => viewModel.selectCategory(null),
                            ),
                          ),
                        Text(
                          state.selectedCategory == null
                              ? 'Informes'
                              : viewModel.getCategoryTitle(
                                  state.selectedCategory!,
                                ),
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: MangoColors.darkGray,
                          ),
                        ),
                      ],
                    ),
                    if (state.selectedCategory == null) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Mira y analiza todos los números que genera tu negocio',
                        style: TextStyle(
                          fontSize: 16,
                          color: MangoColors.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              Expanded(
                child: state.selectedCategory == null
                    ? _buildGrid(context, viewModel)
                    : _buildReportList(
                        context,
                        viewModel,
                        state.selectedCategory!,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(BuildContext context, ReportsViewModel viewModel) {
    return GridView.count(
      crossAxisCount: 5, // Increased to make cards smaller
      padding: const EdgeInsets.all(24),
      mainAxisSpacing: 24,
      crossAxisSpacing: 24,
      childAspectRatio: 1.0, // Square cards
      children: ReportCategory.values.map((category) {
        return _ReportCard(
          title: viewModel.getCategoryTitle(category),
          icon: viewModel.getCategoryIcon(category),
          onTap: () => viewModel.selectCategory(category),
        );
      }).toList(),
    );
  }

  Widget _buildReportList(
    BuildContext context,
    ReportsViewModel viewModel,
    ReportCategory category,
  ) {
    final reports = viewModel.getReportsForCategory(category);

    return ListView.separated(
      padding: const EdgeInsets.all(24),
      itemCount: reports.length,
      separatorBuilder: (context, index) => const SizedBox(height: 16),
      itemBuilder: (context, index) {
        final report = reports[index];
        return _ReportListItem(
          title: report.title,
          description: report.description,
          onTap: report.onTap ?? () {},
        );
      },
    );
  }
}

class _ReportCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final VoidCallback onTap;

  const _ReportCard({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: MangoColors.cardBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: MangoColors.primaryOrange.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: MangoColors.primaryOrange),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: MangoColors.darkGray,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportListItem extends StatelessWidget {
  final String title;
  final String description;
  final VoidCallback onTap;

  const _ReportListItem({
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: MangoColors.cardBorder),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: MangoColors.darkGray,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 14,
                      color: MangoColors.muted,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: MangoColors.muted),
          ],
        ),
      ),
    );
  }
}
