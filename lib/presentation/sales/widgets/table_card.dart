import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../domain/models/ventas_table.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';

/// Card de mesa con diseño responsive
///
/// Documentación completa: DISENO_CARDS_MESAS.txt v2.0
///
/// Características:
/// - Alto fijo: 140px
/// - Ancho flexible: mínimo 240px
/// - Barra de estado izquierda: 6px
/// - Border radius: 12px
/// - Hover: scale 1.02x + cambio de sombra
class TableCard extends StatefulWidget {
  final VentasTable table;
  final String? currentUserId;
  final VoidCallback? onTap;
  final bool isOpening;
  final bool enabled;

  const TableCard({
    super.key,
    required this.table,
    this.currentUserId,
    this.onTap,
    this.isOpening = false,
    this.enabled = true,
  });

  @override
  State<TableCard> createState() => _TableCardState();
}

class _TableCardState extends State<TableCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isOwnTable = widget.currentUserId != null
        ? widget.table.isOwnTable(widget.currentUserId!)
        : false;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      child: GestureDetector(
        onTap: (widget.isOpening || !widget.enabled) ? null : widget.onTap,
        child: Opacity(
          opacity: widget.enabled ? 1 : 0.65,
          child: AnimatedScale(
            scale: _isHovered && widget.enabled ? 1.02 : 1.0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              height: 140, // FIJO - NO cambia
              constraints: const BoxConstraints(
                minWidth: 240, // Ancho mínimo
              ),
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(12), // rounded-xl
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: _isHovered && widget.enabled ? 0.08 : 0.05,
                    ),
                    blurRadius: _isHovered && widget.enabled ? 12 : 3,
                    offset: _isHovered && widget.enabled
                        ? const Offset(0, 4)
                        : const Offset(0, 1),
                  ),
                ],
                // Barra de color izquierda de 6px
                border: Border(
                  left: BorderSide(color: _getBorderColor(), width: 6),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(
                  12,
                ), // Reducido de 16 a 12 para evitar overflow
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // SECCIÓN SUPERIOR
                    _buildTopSection(isOwnTable),

                    // SECCIÓN MEDIA - Divisor con espaciado fijo
                    const SizedBox(height: 8),
                    Container(
                      height: 1,
                      width: double.infinity,
                      color: AppColors.borderDivider,
                    ),
                    const SizedBox(height: 8),

                    // SECCIÓN INFERIOR
                    _buildBottomSection(isOwnTable),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Sección superior: Código, estado y total
  Widget _buildTopSection(bool isOwnTable) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Lado izquierdo: Código y estado
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Código de mesa con efecto hover
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style: AppTextStyles.tableCode.copyWith(
                color: _isHovered ? AppColors.primary : AppColors.foreground,
              ),
              child: Text(widget.table.code),
            ),

            const SizedBox(height: 2),

            // Estado
            Text(
              _getStatusText(),
              style: AppTextStyles.tableStatus.copyWith(
                color: _getStatusColor(),
              ),
            ),
          ],
        ),

        // Lado derecho: Total (solo si está ocupada)
        if (widget.table.isOccupied && widget.table.total != null)
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatCurrency(widget.table.total!),
                  style: AppTextStyles.tableTotal.copyWith(
                    color: AppColors.foreground,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (widget.table.customerName?.trim().isNotEmpty == true) ...[
                  const SizedBox(height: 4),
                  Text(
                    widget.table.customerName!.trim(),
                    style: AppTextStyles.tableWaiter.copyWith(
                      color: AppColors.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// Sección inferior: Métricas, mesero o texto de disponible
  Widget _buildBottomSection(bool isOwnTable) {
    // Mostrar spinner si está abriendo
    if (widget.isOpening) {
      return Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _getStatusColor(),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Abriendo...',
            style: AppTextStyles.tableMetrics.copyWith(
              color: _getStatusColor(),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    if (widget.table.isOccupied) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Métricas: Invitados y Tiempo
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.table.guests != null) ...[
                Icon(
                  Icons.people_outline,
                  size: 16,
                  color: AppColors.mutedForeground,
                ),
                const SizedBox(width: 4),
                Text(
                  '${widget.table.guests}',
                  style: AppTextStyles.tableMetrics.copyWith(
                    color: AppColors.mutedForeground,
                  ),
                ),
                const SizedBox(width: 12), // Reducido de 16 a 12
              ],
              if (widget.table.time != null) ...[
                Icon(
                  Icons.access_time,
                  size: 16,
                  color: AppColors.mutedForeground,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    widget.table.time!,
                    style: AppTextStyles.tableMetrics.copyWith(
                      color: AppColors.mutedForeground,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8), // Reducido para evitar overflow
          // Mesero y badge "Tu mesa"
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.person_outline,
                          size: 14,
                          color: AppColors.mutedForeground,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            (widget.table.waiterName != null &&
                                    widget.table.waiterName!.trim().isNotEmpty)
                                ? widget.table.waiterName!
                                : 'Sin mesero',
                            style: AppTextStyles.tableWaiter.copyWith(
                              color: AppColors.mutedForeground,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Badge "Tu mesa"
              if (isOwnTable)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color:
                        AppColors.successBackground, // success con 10% opacidad
                    borderRadius: BorderRadius.circular(9999), // rounded-full
                  ),
                  child: Text(
                    'Tu mesa',
                    style: AppTextStyles.tableBadge.copyWith(
                      color: AppColors.success,
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    }

    // Mesa disponible - texto con 60% opacidad
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        'Toca para asignar',
        style: AppTextStyles.tableEmptyPrompt.copyWith(
          color: AppColors.foregroundMuted, // foreground con 60% opacidad
        ),
      ),
    );
  }

  /// Obtiene el color de la barra izquierda según el estado
  Color _getBorderColor() {
    switch (widget.table.status) {
      case TableStatus.disponible:
        return AppColors.success; // Verde
      case TableStatus.ocupado:
        return AppColors.warning; // Naranja
      case TableStatus.pagando:
        return AppColors.info; // Azul
    }
  }

  /// Obtiene el color del texto de estado
  Color _getStatusColor() {
    return _getBorderColor();
  }

  /// Obtiene el texto del estado
  String _getStatusText() {
    return widget.table.status.label;
  }

  /// Formatea el monto en pesos dominicanos
  String _formatCurrency(double amount) {
    return 'RD\$ ${NumberFormat('#,##0', 'en_US').format(amount)}';
  }
}
