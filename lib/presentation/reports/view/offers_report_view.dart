import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mangopos/app/theme/mango_colors.dart';
import 'package:mangopos/core/theme/app_breakpoints.dart';
import 'package:mangopos/core/theme/app_colors.dart';
import 'package:mangopos/core/theme/app_spacing.dart';
import 'package:mangopos/presentation/reports/viewmodel/reports_viewmodel.dart';
import 'package:mangopos/presentation/reports/widgets/report_scaffold.dart';
import 'package:mangopos/presentation/reports/widgets/report_widgets.dart';

const Color _kOffersAccent = Color(0xFFD946A6);

/// Reporte "Ventas por oferta": listado detallado, transacción por transacción,
/// de cada vez que se aplicó una oferta (Fecha · Oferta · Producto · Cantidad ·
/// Monto), más un pivote con la cantidad despachada por producto. Fuente:
/// [ReportsRepository.getOffersSummary] (`lines` + `product_totals`).
class OffersReportView extends StatelessWidget {
  const OffersReportView({super.key});

  @override
  Widget build(BuildContext context) {
    return ReportScaffold(
      title: 'Ventas por oferta',
      category: ReportCategory.offers,
      body: (state, viewModel) =>
          _OffersReportBody(state: state, viewModel: viewModel),
    );
  }
}

class _OffersReportBody extends StatelessWidget {
  const _OffersReportBody({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final currency = state.currency.formatter;
    final qtyFormat = NumberFormat('#,##0.##', 'en_US');
    final lines = viewModel.getOfferDetailRows();
    final productTotals = viewModel.getOfferProductTotals();
    // ¿Hay ofertas en el rango (antes de filtrar)? Decide si mostramos la barra
    // de filtros y el placeholder correcto.
    final hasAnyOffers = viewModel.offerNameOptions().isNotEmpty;

    return ListView(
      padding: reportBodyPadding(context),
      children: [
        ReportHeroCard(
          title: 'Ventas por oferta',
          subtitle:
              'Cada vez que se aplicó una oferta, con el producto, la cantidad '
              'y el monto neto pagado en el período seleccionado.',
          period: formatReportPeriod(state),
          accentColor: _kOffersAccent,
          trailing: [
            ReportHeroStat(
              label: 'Productos despachados',
              value: qtyFormat.format(viewModel.offersTotalQuantity),
            ),
            ReportHeroStat(
              label: 'Valor a precio de menú',
              value: currency.format(viewModel.offersTotalValorMenu),
            ),
            ReportHeroStat(
              label: 'Descuento otorgado',
              value: currency.format(viewModel.offersTotalDescuento),
            ),
          ],
        ),
        if (state.error != null) ...[
          const SizedBox(height: AppSpacing.itemGap),
          Text(
            state.error!,
            style: const TextStyle(color: AppColors.destructive),
          ),
        ],
        if (!hasAnyOffers)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xl),
            child: const ReportSurfaceCard(
              child: ReportEmptyPlaceholder(
                icon: Icons.local_offer_outlined,
                message:
                    'No se registraron ventas con ofertas en el rango seleccionado.',
              ),
            ),
          )
        else ...[
          const SizedBox(height: AppSpacing.sectionGap),
          const ReportSectionLabel(
            title: 'Filtros',
            subtitle: 'Filtra el listado por oferta, producto, tipo o texto.',
          ),
          const SizedBox(height: AppSpacing.itemGap),
          _OffersFilterBar(state: state, viewModel: viewModel),
          if (lines.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sectionGap),
              child: ReportSurfaceCard(
                child: ReportEmptyPlaceholder(
                  icon: Icons.filter_alt_off_outlined,
                  message: 'No hay ofertas que coincidan con los filtros '
                      'seleccionados.',
                ),
              ),
            )
          else ...[
            const SizedBox(height: AppSpacing.sectionGap),
            const ReportSectionLabel(
              title: 'Productos en oferta',
              subtitle: 'Cantidad total despachada por cada producto.',
            ),
            const SizedBox(height: AppSpacing.itemGap),
            _ProductTotalsCard(
              rows: productTotals,
              totalQuantity: viewModel.offersTotalQuantity,
              qtyFormat: qtyFormat,
            ),
            const SizedBox(height: AppSpacing.sectionGap),
            const ReportSectionLabel(
              title: 'Detalle de ofertas',
              subtitle: 'Una fila por cada vez que se aplicó una oferta.',
            ),
            const SizedBox(height: AppSpacing.itemGap),
            _OffersDetailTable(
              rows: lines,
              currency: currency,
              qtyFormat: qtyFormat,
            ),
          ],
        ],
      ],
    );
  }
}

/// Barra de filtros del reporte de ofertas: oferta, producto, tipo y búsqueda.
class _OffersFilterBar extends StatelessWidget {
  const _OffersFilterBar({required this.state, required this.viewModel});

  final ReportsState state;
  final ReportsViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final offerOptions = viewModel.offerNameOptions();
    final productOptions = viewModel.offerProductOptions();
    // En teléfono cada filtro ocupa el ancho completo (se apilan); en
    // pantallas anchas conservan su ancho fijo y fluyen en el Wrap. Antes
    // los anchos fijos (240/240/280) desbordaban / reflujaban feo en móvil.
    final isMobile = ResponsiveHelper.isMobile(context);
    final offerWidth = isMobile ? double.infinity : 240.0;
    final searchWidth = isMobile ? double.infinity : 280.0;

    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: offerWidth,
                child: _dropdown(
                  label: 'Oferta',
                  value: state.offerOfferFilter,
                  allLabel: 'Todas las ofertas',
                  options: offerOptions,
                  onChanged: viewModel.setOfferOfferFilter,
                ),
              ),
              SizedBox(
                width: offerWidth,
                child: _dropdown(
                  label: 'Producto',
                  value: state.offerProductFilter,
                  allLabel: 'Todos los productos',
                  options: productOptions,
                  onChanged: viewModel.setOfferProductFilter,
                ),
              ),
              SizedBox(
                width: searchWidth,
                child: _SearchField(
                  query: state.offerSearchQuery,
                  onChanged: viewModel.setOfferSearchQuery,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _typeChip('Todas', OfferTypeFilter.all),
                    _typeChip('Combos', OfferTypeFilter.deal),
                    _typeChip('Promos automáticas', OfferTypeFilter.promo),
                  ],
                ),
              ),
              if (viewModel.hasOfferFilters)
                TextButton.icon(
                  onPressed: viewModel.clearOfferFilters,
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Limpiar'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _typeChip(String label, OfferTypeFilter type) {
    final selected = state.offerTypeFilter == type;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => viewModel.setOfferTypeFilter(type),
      selectedColor: _kOffersAccent.withValues(alpha: 0.18),
      labelStyle: TextStyle(
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? _kOffersAccent : AppColors.foreground,
        fontSize: 12.5,
      ),
      side: BorderSide(
        color: selected ? _kOffersAccent : AppColors.border,
      ),
      backgroundColor: AppColors.background,
    );
  }

  static Widget _dropdown({
    required String label,
    required String? value,
    required String allLabel,
    required List<String> options,
    required ValueChanged<String?> onChanged,
  }) {
    // Si el valor seleccionado ya no está en las opciones (cambió el rango),
    // lo tratamos como "todas" para no romper el Dropdown.
    final safeValue = (value != null && options.contains(value)) ? value : null;
    return DropdownButtonFormField<String>(
      key: ValueKey('offer-dd-$label-$safeValue'),
      initialValue: safeValue,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: AppColors.background,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(reportRadius),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(reportRadius),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(reportRadius),
          borderSide: const BorderSide(color: MangoColors.primaryOrange),
        ),
      ),
      items: [
        DropdownMenuItem<String>(value: null, child: Text(allLabel)),
        for (final option in options)
          DropdownMenuItem<String>(value: option, child: Text(option)),
      ],
      onChanged: onChanged,
    );
  }
}

/// Campo de búsqueda con controlador propio (StatefulWidget) para no perder
/// el cursor al actualizar el estado del reporte.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.query, required this.onChanged});

  final String query;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.query);

  @override
  void didUpdateWidget(_SearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sincroniza si el estado se limpió desde fuera (botón "Limpiar").
    if (widget.query != _controller.text) {
      _controller.text = widget.query;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        hintText: 'Buscar oferta o producto',
        prefixIcon: const Icon(Icons.search),
        filled: true,
        fillColor: AppColors.background,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(reportRadius),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(reportRadius),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(reportRadius),
          borderSide: const BorderSide(color: MangoColors.primaryOrange),
        ),
      ),
    );
  }
}

/// Pivote: cantidad despachada por producto, con la suma total al final.
class _ProductTotalsCard extends StatelessWidget {
  const _ProductTotalsCard({
    required this.rows,
    required this.totalQuantity,
    required this.qtyFormat,
  });

  final List<OfferProductTotal> rows;
  final double totalQuantity;
  final NumberFormat qtyFormat;

  @override
  Widget build(BuildContext context) {
    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Producto',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                      color: AppColors.mutedForeground,
                    ),
                  ),
                ),
                Text(
                  'Cantidad',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    color: AppColors.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: rows.length,
            separatorBuilder: (_, _) => Divider(
                height: 1, color: AppColors.border.withValues(alpha: 0.4)),
            itemBuilder: (context, index) {
              final row = rows[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        row.productName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.foreground,
                        ),
                      ),
                    ),
                    Text(
                      qtyFormat.format(row.quantity),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        color: AppColors.foreground,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Suma total',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                Text(
                  qtyFormat.format(totalQuantity),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13.5,
                    color: AppColors.foreground,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Listado detallado: Fecha · Oferta · Producto · Cantidad · Monto.
class _OffersDetailTable extends StatelessWidget {
  const _OffersDetailTable({
    required this.rows,
    required this.currency,
    required this.qtyFormat,
  });

  final List<OfferDetailLine> rows;
  final NumberFormat currency;
  final NumberFormat qtyFormat;

  @override
  Widget build(BuildContext context) {
    final isMobile = ResponsiveHelper.isMobile(context);
    final dateFormat =
        DateFormat(isMobile ? 'dd/MM HH:mm' : 'dd/MM/yyyy HH:mm:ss');
    final totalQty = rows.fold<double>(0, (s, r) => s + r.quantity);
    final totalValorMenu = rows.fold<double>(0, (s, r) => s + r.valorMenu);
    final totalDescuento = rows.fold<double>(0, (s, r) => s + r.descuento);

    // En teléfono la fila de 6 columnas se aplasta; cada aplicación de oferta
    // se muestra como tarjeta apilada, con una tarjeta de totales al final.
    if (isMobile) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...rows.map(
            (row) => ReportRecordCard(
              title: row.offerName,
              fields: [
                ReportRecordField('Producto', row.productName),
                ReportRecordField(
                  'Fecha',
                  row.dateTime != null ? dateFormat.format(row.dateTime!) : '—',
                ),
                ReportRecordField('Cantidad', qtyFormat.format(row.quantity)),
                ReportRecordField('Valor', currency.format(row.valorMenu)),
                ReportRecordField(
                  'Descuento',
                  currency.format(row.descuento),
                  emphasize: true,
                ),
              ],
            ),
          ),
          ReportRecordCard(
            title: 'Total',
            highlight: true,
            fields: [
              ReportRecordField('Cantidad', qtyFormat.format(totalQty)),
              ReportRecordField('Valor', currency.format(totalValorMenu)),
              ReportRecordField(
                'Descuento',
                currency.format(totalDescuento),
                emphasize: true,
              ),
            ],
          ),
        ],
      );
    }

    return ReportSurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                _headerCell('Fecha', flex: 3),
                _headerCell('Oferta', flex: 2),
                _headerCell('Producto', flex: 3),
                _headerCell('Cant.', flex: 1, end: true),
                _headerCell('Valor', flex: 2, end: true),
                _headerCell('Desc.', flex: 2, end: true),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: rows.length,
            separatorBuilder: (_, _) => Divider(
                height: 1, color: AppColors.border.withValues(alpha: 0.4)),
            itemBuilder: (context, index) {
              final row = rows[index];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    _textCell(
                      row.dateTime != null ? dateFormat.format(row.dateTime!) : '—',
                      flex: 3,
                      muted: true,
                    ),
                    _textCell(row.offerName, flex: 2, bold: true),
                    _textCell(row.productName, flex: 3),
                    _textCell(
                      qtyFormat.format(row.quantity),
                      flex: 1,
                      end: true,
                    ),
                    _textCell(
                      currency.format(row.valorMenu),
                      flex: 2,
                      end: true,
                    ),
                    _textCell(
                      currency.format(row.descuento),
                      flex: 2,
                      end: true,
                      bold: true,
                    ),
                  ],
                ),
              );
            },
          ),
          Divider(height: 1, color: AppColors.border.withValues(alpha: 0.6)),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                const Expanded(
                  flex: 8,
                  child: Text(
                    'Total',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      color: AppColors.foreground,
                    ),
                  ),
                ),
                _totalCell(qtyFormat.format(totalQty), flex: 1),
                _totalCell(currency.format(totalValorMenu), flex: 2),
                _totalCell(currency.format(totalDescuento), flex: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _totalCell(String value, {required int flex}) {
    return Expanded(
      flex: flex,
      child: Text(
        value,
        textAlign: TextAlign.end,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 13.5,
          color: AppColors.foreground,
        ),
      ),
    );
  }

  static Widget _headerCell(String label, {required int flex, bool end = false}) {
    return Expanded(
      flex: flex,
      child: Text(
        label,
        textAlign: end ? TextAlign.end : TextAlign.start,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
          color: AppColors.mutedForeground,
        ),
      ),
    );
  }

  static Widget _textCell(
    String value, {
    required int flex,
    bool end = false,
    bool bold = false,
    bool muted = false,
  }) {
    return Expanded(
      flex: flex,
      child: Text(
        value,
        textAlign: end ? TextAlign.end : TextAlign.start,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          fontSize: 12.5,
          color: muted ? AppColors.mutedForeground : AppColors.foreground,
        ),
      ),
    );
  }
}
