# ESPECIFICACIONES DE DISEÑO DASHBOARD - MANGO POS (FLUTTER)

## DESCRIPCIÓN GENERAL
Dashboard moderno tipo "Soft UI" con sombras suaves, bordes redondeados y colores vibrantes optimizado para múltiples formatos de pantalla (ultrawide, 16:9, 21:10 y tablet).

**Fuente Principal:** Plus Jakarta Sans (Google Fonts)
**Unidad de Medida:** Density-Independent Pixels (dp) para Flutter

---

## 1. PALETA DE COLORES (Token System)

### Colores Base (HSL - Fuente de Verdad)

```dart
// lib/core/theme/app_colors.dart

class AppColors {
  // Backgrounds
  static const Color background = Color(0xFFFAF9F7);        // hsl(30, 20%, 98%)
  static const Color card = Color(0xFFFFFFFF);              // hsl(0, 0%, 100%) - Blanco puro
  static const Color muted = Color(0xFFF0EBE7);             // hsl(30, 10%, 92%)
  static const Color accent = Color(0xFFF7F3F0);            // hsl(30, 20%, 94%)
  static const Color secondary = Color(0xFFF5F1EE);         // hsl(30, 15%, 95%)

  // Textos
  static const Color foreground = Color(0xFF231F1D);        // hsl(20, 14%, 12%)
  static const Color mutedForeground = Color(0xFF7D726D);   // hsl(20, 10%, 45%)

  // Bordes
  static const Color border = Color(0xFFE0DBD9);            // hsl(30, 15%, 88%)

  // Branding
  static const Color primary = Color(0xFFFB7116);           // hsl(25, 95%, 53%)
  static const Color primaryGradientEnd = Color(0xFFF99E1F); // hsl(35, 95%, 55%)

  // Estados
  static const Color success = Color(0xFF22C55E);           // hsl(142, 71%, 45%)
  static const Color warning = Color(0xFFF59E0B);           // hsl(38, 92%, 50%)
  static const Color info = Color(0xFF3B82F6);              // hsl(217, 91%, 60%)
  static const Color destructive = Color(0xFFEF4444);       // hsl(0, 84%, 60%)

  // Opacidades de Estado (para fondos)
  static final Color successBg = success.withOpacity(0.1);
  static final Color warningBg = warning.withOpacity(0.1);
  static final Color infoBg = info.withOpacity(0.1);
  static final Color primaryBg = primary.withOpacity(0.1);

  // Opacidades de Estado (para bordes)
  static final Color successBorder = success.withOpacity(0.2);
  static final Color warningBorder = warning.withOpacity(0.2);
  static final Color infoBorder = info.withOpacity(0.2);
  static final Color primaryBorder = primary.withOpacity(0.2);
}
```

### Gradientes

```dart
// lib/core/theme/app_gradients.dart

class AppGradients {
  // Gradient Mango - Usado en botones primarios
  static const LinearGradient mango = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFFB7116), // primary
      Color(0xFFF99E1F), // primaryGradientEnd
    ],
  );

  // Gradient Chart Fill - Para área bajo la curva
  static final LinearGradient chartFill = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      AppColors.primary.withOpacity(0.15),
      AppColors.primary.withOpacity(0.01),
    ],
  );
}
```

---

## 2. LAYOUT Y RESPONSIVIDAD (Grid System)

### Breakpoints del Sistema

```dart
// lib/core/theme/app_breakpoints.dart

class AppBreakpoints {
  static const double mobile = 640;           // sm
  static const double tablet = 1024;          // lg - contentWideBreakpoint
  static const double desktop = 1280;         // xl - twoColumnBreakpoint
  static const double ultrawide = 1920;       // Ultrawide
  
  static const double maxContentWidth = 1440; // Ancho máximo del contenido
}

// Helper para obtener el tipo de dispositivo
enum DeviceType { mobile, tablet, desktop, ultrawide }

DeviceType getDeviceType(double width) {
  if (width >= AppBreakpoints.ultrawide) return DeviceType.ultrawide;
  if (width >= AppBreakpoints.desktop) return DeviceType.desktop;
  if (width >= AppBreakpoints.tablet) return DeviceType.tablet;
  return DeviceType.mobile;
}
```

### Espaciado (Spacing System)

```dart
// lib/core/theme/app_spacing.dart

class AppSpacing {
  // Spacing base (múltiplos de 4dp)
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;
  static const double xxxl = 32.0;

  // Spacing específico del dashboard
  static const double containerPadding = 24.0;    // p-6
  static const double sectionGap = 24.0;          // gap-6
  static const double cardPadding = 24.0;         // p-6
  static const double itemGap = 16.0;             // gap-4
  static const double tightGap = 12.0;            // gap-3
}
```

### Border Radius

```dart
// lib/core/theme/app_radius.dart

class AppRadius {
  static const double sm = 6.0;                   // rounded-sm
  static const double md = 8.0;                   // rounded-lg
  static const double lg = 12.0;                  // rounded-xl
  static const double iconBox = 10.0;             // rounded-lg para icon boxes
  static const double full = 9999.0;              // rounded-full

  // Aplicaciones específicas
  static const double card = 12.0;
  static const double button = 8.0;
  static const double badge = 9999.0;
}
```

### Contenedor Principal

```dart
// lib/presentation/dashboard/widgets/dashboard_container.dart

class DashboardContainer extends StatelessWidget {
  final Widget child;

  const DashboardContainer({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(maxWidth: AppBreakpoints.maxContentWidth),
      margin: EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
      padding: EdgeInsets.all(AppSpacing.containerPadding),
      child: child,
    );
  }
}
```

### Grid Principal (Desktop XL >= 1280dp)

```dart
// lib/presentation/dashboard/layouts/desktop_layout.dart

class DesktopDashboardLayout extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Columna Izquierda (66%)
        Expanded(
          flex: 2,
          child: Column(
            children: [
              WelcomeCard(),
              SizedBox(height: AppSpacing.sectionGap),
              QuickActionsSection(),
              SizedBox(height: AppSpacing.sectionGap),
              SalesChartCard(),
            ],
          ),
        ),
        SizedBox(width: AppSpacing.sectionGap),
        // Columna Derecha (33%) - Sticky
        Expanded(
          flex: 1,
          child: ActiveTablesCard(),
        ),
      ],
    );
  }
}
```

### Layout Mobile/Tablet (< 1280dp)

```dart
// lib/presentation/dashboard/layouts/mobile_layout.dart

class MobileDashboardLayout extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        WelcomeCard(),
        SizedBox(height: AppSpacing.sectionGap),
        QuickActionsSection(),
        SizedBox(height: AppSpacing.sectionGap),
        SalesChartCard(),
        SizedBox(height: AppSpacing.sectionGap),
        ActiveTablesCard(),
      ],
    );
  }
}
```

---

## 3. COMPONENTES DETALLADOS

### A. WELCOME CARD (Tarjeta de Bienvenida)

**IMPORTANTE: La Welcome Card NO tiene gradiente, es fondo blanco puro**

```dart
// lib/presentation/dashboard/widgets/welcome_card.dart

class WelcomeCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= AppBreakpoints.tablet;

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.card, // Blanco puro, SIN gradiente
        border: Border.all(color: AppColors.border, width: 1),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.cardElevated,
      ),
      child: isWide
          ? _buildWideLayout()
          : _buildNarrowLayout(),
    );
  }

  Widget _buildWideLayout() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(child: _buildLeftContent()),
        SizedBox(width: AppSpacing.xxl),
        _buildRightActions(),
      ],
    );
  }

  Widget _buildNarrowLayout() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLeftContent(),
        SizedBox(height: AppSpacing.xxl),
        _buildRightActions(),
      ],
    );
  }

  Widget _buildLeftContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Fecha
        Text(
          'Lunes, 2 De Febrero De 2026',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.mutedForeground,
          ),
        ),
        SizedBox(height: AppSpacing.sm),
        // Título con gradiente
        RichText(
          text: TextSpan(
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
            children: [
              TextSpan(
                text: '¡Bienvenido a ',
                style: TextStyle(color: AppColors.foreground),
              ),
              TextSpan(
                text: 'MangoPOS',
                style: TextStyle(
                  foreground: Paint()
                    ..shader = AppGradients.mango.createShader(
                      Rect.fromLTWH(0, 0, 200, 70),
                    ),
                ),
              ),
              TextSpan(
                text: '!',
                style: TextStyle(color: AppColors.foreground),
              ),
            ],
          ),
        ),
        SizedBox(height: AppSpacing.md),
        // Meta Info
        Wrap(
          spacing: AppSpacing.lg,
          runSpacing: AppSpacing.sm,
          children: [
            _buildMetaItem(Icons.store, 'Restaurante Demo'),
            _buildMetaItem(Icons.person, 'Usuario: Admin'),
            _buildMetaItem(Icons.attach_money, 'Caja #001'),
          ],
        ),
      ],
    );
  }

  Widget _buildMetaItem(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppColors.mutedForeground),
        SizedBox(width: 6),
        Text(
          text,
          style: TextStyle(
            fontSize: 14,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }

  Widget _buildRightActions() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Badge "Caja cerrada"
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: AppColors.warningBg,
            borderRadius: BorderRadius.circular(AppRadius.button),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock, size: 16, color: AppColors.warning),
              SizedBox(width: AppSpacing.sm),
              Text(
                'Caja cerrada',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.warning,
                ),
              ),
            ],
          ),
        ),
        SizedBox(width: AppSpacing.md),
        // Botón "Aperturar Caja"
        Container(
          decoration: BoxDecoration(
            gradient: AppGradients.mango,
            borderRadius: BorderRadius.circular(AppRadius.button),
            boxShadow: AppShadows.mango,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {},
              borderRadius: BorderRadius.circular(AppRadius.button),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: 10,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 16, color: Colors.white),
                    SizedBox(width: AppSpacing.sm),
                    Text(
                      'Aperturar Caja',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
```

### B. QUICK ACTIONS (Acciones Rápidas)

```dart
// lib/presentation/dashboard/widgets/quick_actions_section.dart

class QuickActionsSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Acciones Rápidas',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
          ),
        ),
        SizedBox(height: AppSpacing.lg),
        _buildPrimaryActions(),
        SizedBox(height: AppSpacing.sectionGap),
        _buildQuickActionsGrid(),
      ],
    );
  }

  Widget _buildPrimaryActions() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Row(
          children: [
            // Nueva Venta (con gradiente)
            Expanded(
              child: _PrimaryActionCard(
                icon: Icons.add_shopping_cart,
                title: 'Nueva Venta',
                subtitle: 'Ir al punto de venta',
                gradient: AppGradients.mango,
                onTap: () {},
              ),
            ),
            SizedBox(width: AppSpacing.sectionGap),
            // Delivery (fondo blanco)
            Expanded(
              child: _PrimaryActionCard(
                icon: Icons.delivery_dining,
                title: 'Delivery',
                subtitle: 'Pedidos para entrega',
                backgroundColor: AppColors.card,
                iconColor: AppColors.info,
                iconBackgroundColor: AppColors.infoBg,
                textColor: AppColors.foreground,
                onTap: () {},
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildQuickActionsGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppBreakpoints.tablet;
        final crossAxisCount = isWide ? 4 : 2;

        return GridView.count(
          shrinkWrap: true,
          physics: NeverScrollableScrollPhysics(),
          crossAxisCount: crossAxisCount,
          crossAxisSpacing: AppSpacing.sectionGap,
          mainAxisSpacing: AppSpacing.sectionGap,
          childAspectRatio: 1.2,
          children: [
            _QuickActionCard(
              icon: Icons.people,
              title: 'Mozos',
              subtitle: 'Gestionar meseros',
              color: AppColors.info,
            ),
            _QuickActionCard(
              icon: Icons.print,
              title: 'Imprimir Productos',
              subtitle: 'Etiquetas y códigos',
              color: AppColors.success,
            ),
            _QuickActionCard(
              icon: Icons.receipt,
              title: 'Comprobantes',
              subtitle: 'NCF y facturas',
              color: AppColors.warning,
            ),
            _QuickActionCard(
              icon: Icons.campaign,
              title: 'Publicidad',
              subtitle: 'Promociones activas',
              color: AppColors.primary,
            ),
          ],
        );
      },
    );
  }
}

// Widget para acciones primarias (Nueva Venta y Delivery)
class _PrimaryActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Gradient? gradient;
  final Color? backgroundColor;
  final Color? iconColor;
  final Color? iconBackgroundColor;
  final Color? textColor;
  final VoidCallback onTap;

  const _PrimaryActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.gradient,
    this.backgroundColor,
    this.iconColor,
    this.iconBackgroundColor,
    this.textColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasGradient = gradient != null;

    return Container(
      decoration: BoxDecoration(
        gradient: gradient,
        color: backgroundColor,
        border: hasGradient ? null : Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Row(
              children: [
                // Icon Box
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: iconBackgroundColor ?? Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Icon(
                    icon,
                    size: 24,
                    color: iconColor ?? Colors.white,
                  ),
                ),
                SizedBox(width: AppSpacing.lg),
                // Text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: textColor ?? Colors.white,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: (textColor ?? Colors.white).withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Widget para acciones pequeñas (grid de 4)
class _QuickActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;

  const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {},
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Icon Box
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(AppRadius.iconBox),
                  ),
                  child: Icon(icon, size: 20, color: color),
                ),
                SizedBox(height: AppSpacing.sm),
                // Title
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.foreground,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: 2),
                // Subtitle
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.mutedForeground,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

### C. SALES CHART (Gráfico de Ventas)

```dart
// lib/presentation/dashboard/widgets/sales_chart_card.dart

class SalesChartCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          SizedBox(height: AppSpacing.xxl),
          _buildStatsRow(),
          SizedBox(height: AppSpacing.xxl),
          _buildChart(),
          SizedBox(height: AppSpacing.lg),
          _buildTrendIndicator(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 640;

        if (isWide) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildTitleSection(),
              _buildFilterButton(),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTitleSection(),
            SizedBox(height: AppSpacing.lg),
            _buildFilterButton(),
          ],
        );
      },
    );
  }

  Widget _buildTitleSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Resumen de Ventas',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
          ),
        ),
        SizedBox(height: 4),
        Text(
          'Últimos 7 días',
          style: TextStyle(
            fontSize: 14,
            color: AppColors.mutedForeground,
          ),
        ),
      ],
    );
  }

  Widget _buildFilterButton() {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.secondary,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.calendar_today, size: 14, color: AppColors.foreground),
          SizedBox(width: AppSpacing.sm),
          Text(
            'Esta semana',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.foreground,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: 'Total Ventas',
            value: 'RD\$446,900',
            color: AppColors.success,
          ),
        ),
        SizedBox(width: AppSpacing.lg),
        Expanded(
          child: _StatCard(
            label: 'Promedio Diario',
            value: 'RD\$63,843',
            color: AppColors.info,
          ),
        ),
        SizedBox(width: AppSpacing.lg),
        Expanded(
          child: _StatCard(
            label: 'Día Récord',
            value: 'RD\$92,400',
            color: AppColors.primary,
          ),
        ),
      ],
    );
  }

  Widget _buildChart() {
    return Container(
      height: 256,
      child: Center(
        child: Text(
          'Chart Component Here (fl_chart)',
          style: TextStyle(color: AppColors.mutedForeground),
        ),
      ),
    );
  }

  Widget _buildTrendIndicator() {
    return Container(
      padding: EdgeInsets.only(top: AppSpacing.lg),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.trending_up, size: 16, color: AppColors.success),
          SizedBox(width: 6),
          Text(
            '+12.5%',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.success,
            ),
          ),
          SizedBox(width: 6),
          Text(
            'vs. semana anterior',
            style: TextStyle(
              fontSize: 14,
              color: AppColors.mutedForeground,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        border: Border.all(color: color.withOpacity(0.2)),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.mutedForeground,
            ),
          ),
          SizedBox(height: AppSpacing.sm),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
```

### D. ACTIVE TABLES (Mesas Activas)

```dart
// lib/presentation/dashboard/widgets/active_tables_card.dart

class ActiveTablesCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: AppColors.card,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: AppShadows.cardElevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          SizedBox(height: AppSpacing.lg),
          _buildTablesList(),
          SizedBox(height: AppSpacing.lg),
          _buildFooter(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Mesas Activas',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.foreground,
          ),
        ),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: AppColors.warningBg,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Text(
            '3 ocupadas',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: AppColors.warning,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTablesList() {
    final tables = [
      {'zone': 'Salón Principal', 'persons': 4, 'time': '45:23', 'total': 'RD\$ 2,850'},
      {'zone': 'Salón Principal', 'persons': 2, 'time': '28:10', 'total': 'RD\$ 1,200'},
      {'zone': 'Terraza', 'persons': 6, 'time': '1:12:45', 'total': 'RD\$ 5,400'},
    ];

    return Column(
      children: tables.map((table) => Padding(
        padding: EdgeInsets.only(bottom: AppSpacing.md),
        child: _TableItem(
          zone: table['zone'] as String,
          persons: table['persons'] as int,
          time: table['time'] as String,
          total: table['total'] as String,
        ),
      )).toList(),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: EdgeInsets.only(top: AppSpacing.lg),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.border),
        ),
      ),
      child: Center(
        child: TextButton.icon(
          onPressed: () {},
          icon: Icon(Icons.arrow_forward, size: 16),
          label: Text('Ver todas las mesas'),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.primary,
            textStyle: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _TableItem extends StatelessWidget {
  final String zone;
  final int persons;
  final String time;
  final String total;

  const _TableItem({
    required this.zone,
    required this.persons,
    required this.time,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.secondary.withOpacity(0.5),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: InkWell(
        onTap: () {},
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Row(
          children: [
            // Icon Box
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.warningBg,
                borderRadius: BorderRadius.circular(AppRadius.button),
              ),
              child: Center(
                child: Text(
                  'SP${persons}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warning,
                  ),
                ),
              ),
            ),
            SizedBox(width: AppSpacing.md),
            // Info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    zone,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.foreground,
                    ),
                  ),
                  SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.people, size: 12, color: AppColors.mutedForeground),
                      SizedBox(width: 4),
                      Text(
                        '$persons personas',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                      SizedBox(width: AppSpacing.sm),
                      Icon(Icons.access_time, size: 12, color: AppColors.mutedForeground),
                      SizedBox(width: 4),
                      Text(
                        time,
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.mutedForeground,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Total
            Text(
              total,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

---

## 4. SOMBRAS (Box Shadows)

```dart
// lib/core/theme/app_shadows.dart

class AppShadows {
  // Card Elevada - Usada en la mayoría de cards
  static const List<BoxShadow> cardElevated = [
    BoxShadow(
      color: Color(0x0D000000), // rgba(0, 0, 0, 0.05)
      offset: Offset(0, 1),
      blurRadius: 3,
    ),
    BoxShadow(
      color: Color(0x14000000), // rgba(0, 0, 0, 0.08)
      offset: Offset(0, 4),
      blurRadius: 12,
    ),
  ];

  // Card Interactiva - Hover state
  static const List<BoxShadow> cardInteractive = [
    BoxShadow(
      color: Color(0x12000000), // rgba(0, 0, 0, 0.07)
      offset: Offset(0, 4),
      blurRadius: 6,
    ),
    BoxShadow(
      color: Color(0x1A000000), // rgba(0, 0, 0, 0.1)
      offset: Offset(0, 8),
      blurRadius: 16,
    ),
  ];

  // Sombra Suave - Para tooltips y dropdowns
  static const List<BoxShadow> soft = [
    BoxShadow(
      color: Color(0x14000000), // rgba(0, 0, 0, 0.08)
      offset: Offset(0, 2),
      blurRadius: 8,
      spreadRadius: -2,
    ),
  ];

  // Sombra Mango - Para botones primarios
  static final List<BoxShadow> mango = [
    BoxShadow(
      color: AppColors.primary.withOpacity(0.3),
      offset: Offset(0, 4),
      blurRadius: 8,
    ),
  ];

  static final List<BoxShadow> mangoHover = [
    BoxShadow(
      color: AppColors.primary.withOpacity(0.4),
      offset: Offset(0, 6),
      blurRadius: 12,
    ),
  ];
}
```

---

## 5. TIPOGRAFÍA

```dart
// lib/core/theme/app_typography.dart

class AppTypography {
  static const String fontFamily = 'Plus Jakarta Sans';

  // Text Styles
  static const TextStyle xs = TextStyle(
    fontSize: 12,
    fontFamily: fontFamily,
  );

  static const TextStyle sm = TextStyle(
    fontSize: 14,
    fontFamily: fontFamily,
  );

  static const TextStyle base = TextStyle(
    fontSize: 16,
    fontFamily: fontFamily,
  );

  static const TextStyle lg = TextStyle(
    fontSize: 18,
    fontFamily: fontFamily,
  );

  static const TextStyle xl = TextStyle(
    fontSize: 20,
    fontFamily: fontFamily,
  );

  static const TextStyle xl2 = TextStyle(
    fontSize: 24,
    fontFamily: fontFamily,
  );

  static const TextStyle xl3 = TextStyle(
    fontSize: 30,
    fontFamily: fontFamily,
  );

  // Font Weights
  static const FontWeight normal = FontWeight.w400;
  static const FontWeight medium = FontWeight.w500;
  static const FontWeight semibold = FontWeight.w600;
  static const FontWeight bold = FontWeight.w700;
  static const FontWeight extrabold = FontWeight.w800;
}
```

### Configuración en pubspec.yaml

```yaml
dependencies:
  flutter:
    sdk: flutter
  google_fonts: ^6.1.0

# O si prefieres incluir la fuente localmente:
flutter:
  fonts:
    - family: Plus Jakarta Sans
      fonts:
        - asset: assets/fonts/PlusJakartaSans-Regular.ttf
          weight: 400
        - asset: assets/fonts/PlusJakartaSans-Medium.ttf
          weight: 500
        - asset: assets/fonts/PlusJakartaSans-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/PlusJakartaSans-Bold.ttf
          weight: 700
        - asset: assets/fonts/PlusJakartaSans-ExtraBold.ttf
          weight: 800
```

---

## 6. ANIMACIONES Y TRANSICIONES

```dart
// lib/core/theme/app_animations.dart

class AppAnimations {
  // Duraciones
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 300);

  // Curves
  static const Curve easeOut = Curves.easeOut;
  static const Curve easeInOut = Curves.easeInOut;

  // Hover Effects (para web/desktop)
  static const double hoverLiftOffset = -2.0;
  static const double hoverScale = 1.05;
  static const double hoverOpacity = 0.8;
}
```

### Ejemplo de uso con MouseRegion (para hover effects)

```dart
class HoverableCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const HoverableCard({required this.child, this.onTap});

  @override
  _HoverableCardState createState() => _HoverableCardState();
}

class _HoverableCardState extends State<HoverableCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: AppAnimations.normal,
        curve: AppAnimations.easeOut,
        transform: Matrix4.translationValues(
          0,
          _isHovered ? AppAnimations.hoverLiftOffset : 0,
          0,
        ),
        decoration: BoxDecoration(
          boxShadow: _isHovered 
            ? AppShadows.cardInteractive 
            : AppShadows.cardElevated,
        ),
        child: widget.child,
      ),
    );
  }
}
```

---

## 7. RESPONSIVE BEHAVIOR

### Comportamiento por Breakpoint

```dart
// lib/core/utils/responsive_helper.dart

class ResponsiveHelper {
  static bool isMobile(BuildContext context) {
    return MediaQuery.of(context).size.width < AppBreakpoints.mobile;
  }

  static bool isTablet(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return width >= AppBreakpoints.mobile && width < AppBreakpoints.tablet;
  }

  static bool isDesktop(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    return width >= AppBreakpoints.tablet && width < AppBreakpoints.desktop;
  }

  static bool isDesktopXL(BuildContext context) {
    return MediaQuery.of(context).size.width >= AppBreakpoints.desktop;
  }

  static bool isUltrawide(BuildContext context) {
    return MediaQuery.of(context).size.width >= AppBreakpoints.ultrawide;
  }

  // Helper para obtener el número de columnas del grid
  static int getQuickActionsColumns(BuildContext context) {
    return isDesktop(context) || isDesktopXL(context) ? 4 : 2;
  }

  // Helper para determinar si usar layout horizontal
  static bool useWideLayout(BuildContext context) {
    return MediaQuery.of(context).size.width >= AppBreakpoints.tablet;
  }
}
```

### Tabla de Comportamientos

| Breakpoint | Width | WelcomeCard | QuickActions | Layout | ActiveTables |
|------------|-------|-------------|--------------|--------|--------------|
| Mobile | < 640dp | Vertical | 2 cols | Single column | Full width |
| Tablet | 640-1023dp | Vertical | 2 cols | Single column | Full width |
| Desktop | 1024-1279dp | Horizontal | 4 cols | Single column | Full width |
| Desktop XL | 1280-1919dp | Horizontal | 4 cols | 2+1 grid | Sticky right |
| Ultrawide | >= 1920dp | Horizontal | 4 cols | 2+1 grid (centered) | Sticky right |

---

## 8. ESTRUCTURA DE ARCHIVOS RECOMENDADA

```
lib/
├── core/
│   ├── theme/
│   │   ├── app_colors.dart
│   │   ├── app_gradients.dart
│   │   ├── app_spacing.dart
│   │   ├── app_radius.dart
│   │   ├── app_shadows.dart
│   │   ├── app_typography.dart
│   │   ├── app_breakpoints.dart
│   │   └── app_animations.dart
│   └── utils/
│       └── responsive_helper.dart
├── presentation/
│   └── dashboard/
│       ├── dashboard_view.dart
│       ├── layouts/
│       │   ├── desktop_layout.dart
│       │   └── mobile_layout.dart
│       └── widgets/
│           ├── dashboard_container.dart
│           ├── welcome_card.dart
│           ├── quick_actions_section.dart
│           ├── sales_chart_card.dart
│           └── active_tables_card.dart
└── main.dart
```

---

## 9. CHECKLIST DE IMPLEMENTACIÓN

- [ ] Configurar Plus Jakarta Sans en pubspec.yaml
- [ ] Crear archivos de tema (colors, gradients, spacing, etc.)
- [ ] Implementar WelcomeCard **SIN gradiente** (fondo blanco puro)
- [ ] Implementar QuickActionsSection con grid responsive
- [ ] Implementar SalesChartCard con stats y placeholder para chart
- [ ] Implementar ActiveTablesCard
- [ ] Configurar layouts responsive (mobile y desktop)
- [ ] Aplicar sombras según especificación
- [ ] Implementar hover effects para web/desktop
- [ ] Validar responsive en todos los breakpoints
- [ ] Validar colores HSL correctos
- [ ] Validar spacing consistente (múltiplos de 4dp)

---

## 10. NOTAS IMPORTANTES

1. **Welcome Card SIN Gradiente**: La tarjeta de bienvenida debe tener fondo blanco puro (`Color(0xFFFFFFFF)`), no gradiente.

2. **Unidades en DP**: Todos los valores están en density-independent pixels (dp), que Flutter maneja automáticamente.

3. **Fuente de Verdad HSL**: Usar los valores de color exactos definidos en `AppColors`.

4. **Max Width Centrado**: El contenido nunca debe exceder 1440dp de ancho.

5. **Spacing System**: Mantener múltiplos de 4dp para todos los espaciados.

6. **Gradiente Mango**: Solo usar en botón "Aperturar Caja" y "Nueva Venta".

7. **Hover States**: Implementar solo para web/desktop usando `MouseRegion`.

8. **Performance**: Usar `const` constructors donde sea posible para optimizar rendimiento.

---

## RESUMEN DE VALORES CLAVE

```dart
// Spacing
static const double containerPadding = 24.0;
static const double sectionGap = 24.0;
static const double cardPadding = 24.0;

// Radius
static const double card = 12.0;
static const double button = 8.0;
static const double iconBox = 10.0;

// Max Width
static const double maxContentWidth = 1440;

// Breakpoints
static const double mobile = 640;
static const double tablet = 1024;
static const double desktop = 1280;

// Colors (principales)
static const Color primary = Color(0xFFFB7116);
static const Color background = Color(0xFFFAF9F7);
static const Color card = Color(0xFFFFFFFF);
static const Color foreground = Color(0xFF231F1D);
```

---

**VERSIÓN:** 2.0 (Flutter)  
**ÚLTIMA ACTUALIZACIÓN:** Febrero 2026  
**PLATAFORMA:** Flutter (Web, Desktop, Mobile)  
**FRAMEWORK UI:** Custom Soft UI Design System
