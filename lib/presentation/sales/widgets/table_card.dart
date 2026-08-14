import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/currency/business_currency.dart';
import '../../../core/currency/business_currency_provider.dart';
import '../../../domain/models/ventas_table.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_text_styles.dart';
import '../view/theme/table_status_style.dart';

/// Ancho mínimo que el card necesita para dibujar su contenido sin truncar.
///
/// Es público a propósito: el grid del salón tiene que descontarlo al calcular
/// columnas. Antes el grid partía de un ancho base de 220 y rendía celdas de
/// 227 dp; como el card no puede encogerse por debajo de este valor, el nombre
/// del mesero y el total se recortaban. Si los dos números se separan, vuelve
/// el defecto — por eso vive aquí y no duplicado en el grid.
const double kTableCardMinWidth = 240.0;

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
  /// PRD-12 F3: long-press en una mesa OCUPADA abre el menú "Unir
  /// con otra mesa…". El padre decide si lo conecta (típicamente solo
  /// en sales_by_zone_view, no en selectores tipo modal).
  final VoidCallback? onLongPress;
  final bool isOpening;
  final bool enabled;

  const TableCard({
    super.key,
    required this.table,
    this.currentUserId,
    this.onTap,
    this.onLongPress,
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
    final palette = tableStatusPalette(widget.table.status);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.forbidden,
      child: GestureDetector(
        onTap: (widget.isOpening || !widget.enabled) ? null : widget.onTap,
        onLongPress: (widget.isOpening || !widget.enabled)
            ? null
            : widget.onLongPress,
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
                minWidth: kTableCardMinWidth,
              ),
              decoration: BoxDecoration(
                // Solo cambia el color: el fondo va tintado según el estado.
                color: palette.surface,
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
              // El borde de 1px del estado va como decoración DELANTERA: con
              // borderRadius, Flutter lanza assert si un mismo Border mezcla
              // colores por lado, y la barra de 6px de arriba tiene que
              // seguir siendo el BorderSide izquierdo de siempre.
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.border),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  // `max` + Spacer, no `min`: el card mide 140 dp fijos y con
                  // `min` la columna se apretaba arriba dejando el hueco
                  // debajo, así que la hora y el "Toca para asignar" quedaban
                  // pegados al estado. Ahora la identidad se ancla arriba, el
                  // contexto abajo, y el aire sobrante queda en medio.
                  mainAxisSize: MainAxisSize.max,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // BANDA 1 - Identidad y dinero
                    _buildTopSection(isOwnTable),

                    // La holgura del card se reparte 3:1 — tres cuartas partes
                    // arriba y una cuarta abajo. El contexto baja respecto al
                    // estado sin llegar a pegarse al borde inferior.
                    //
                    // Son Spacer y no un alto fijo porque si el usuario sube el
                    // tamaño de texto del sistema, ambos se encogen a cero
                    // antes que desbordar.
                    const Spacer(flex: 3),

                    // BANDA 2 - Separador. Solo cuando hay dinero arriba:
                    // la mesa disponible no lo lleva.
                    if (widget.table.hasActiveSession) ...[
                      Container(
                        height: 1,
                        width: double.infinity,
                        color: AppColors.cardDivider,
                      ),
                      const SizedBox(height: 10),
                    ],

                    // BANDA 3 - Contexto
                    _buildBottomSection(isOwnTable),

                    const Spacer(flex: 1),
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

        // Lado derecho: Total. Se muestra siempre que la mesa tenga
        // sesión activa (ocupado o pagando) — el cajero debe ver lo
        // que el cliente debe aunque ya se imprimió la precuenta.
        if (widget.table.hasActiveSession && widget.table.total != null)
          Flexible(
            child: Consumer(
              builder: (context, ref, _) {
                final currency = currentBusinessCurrencyOrFallback(ref);
                return Text(
                  _formatCurrency(currency, widget.table.total!),
                  // Spec: el total va a 16px/700. El token compartido
                  // se queda en 14 porque lo reusa Delivery Express.
                  style: AppTextStyles.tableTotal.copyWith(
                    fontSize: 16,
                    color: AppColors.foreground,
                  ),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                );
              },
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

    if (widget.table.hasActiveSession) {
      // Banda 3 del diseño: UNA sola línea de contexto separada por "·"
      // («4 · 00:45 · Luis Gómez»), con la marca "Tu mesa" al otro extremo.
      // Los iconos de comensales/reloj/mesero salieron: a 14px el punto medio
      // separa igual y deja la línea entera para el nombre del mesero.
      final waiter = widget.table.waiterName?.trim();
      final contextLine = <String>[
        if (widget.table.guests != null) '${widget.table.guests}',
        if (widget.table.time != null) widget.table.time!,
        (waiter != null && waiter.isNotEmpty) ? waiter : 'Sin mesero',
      ].join(' · ');

      final customer = widget.table.customerName?.trim();

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  contextLine,
                  style: AppTextStyles.tableMetrics.copyWith(
                    color: AppColors.mutedForeground,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              // Badge "Tu mesa"
              if (isOwnTable) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    // success con 10% opacidad
                    color: AppColors.successBackground,
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
            ],
          ),

          // El cliente va DEBAJO del mesero y la hora, cerrando la card.
          if (customer != null && customer.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              customer,
              style: AppTextStyles.tableWaiter.copyWith(
                color: AppColors.foreground,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      );
    }

    // Mesa disponible. Si la card esta deshabilitada (caja cerrada o sin
    // permisos) el texto activo "Toca para asignar" engaña al cajero.
    // Mostramos un placeholder neutro que coincida con la accion real.
    final emptyText = widget.enabled ? 'Toca para asignar' : 'Caja cerrada';
    return Text(
      emptyText,
      style: AppTextStyles.tableEmptyPrompt.copyWith(
        color: AppColors.foregroundMuted, // foreground con 60% opacidad
      ),
    );
  }

  /// Obtiene el color de la barra izquierda según el estado.
  /// Delega al helper compartido para no diverger del floor map.
  Color _getBorderColor() => tableStatusColor(widget.table.status);

  /// Obtiene el color del texto de estado
  Color _getStatusColor() {
    return _getBorderColor();
  }

  /// Obtiene el texto del estado. Para un borrador local sin sincronizar
  /// añade "· Sin subir" (en el mismo naranja de "Ocupado") para que el cajero
  /// sepa que la mesa aún no llegó al servidor. Se reusa la línea de estado
  /// para no agregar alto y evitar overflow en la tarjeta de 140px fijos.
  String _getStatusText() {
    final base = widget.table.status.label;
    return widget.table.isPendingSync ? '$base · Sin subir' : base;
  }

  /// Formatea el monto con el símbolo de la moneda del negocio. Mantiene el
  /// formato compacto sin decimales (estilo tarjeta de mesa); solo cambia el
  /// símbolo según la moneda configurada.
  String _formatCurrency(BusinessCurrency currency, double amount) {
    return '${currency.symbol} ${NumberFormat('#,##0', 'en_US').format(amount)}';
  }
}
