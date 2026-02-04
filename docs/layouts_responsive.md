# Layouts Responsive - MangoPOS

Fecha: 2026-02-03

Este documento describe el layout por pantalla (mobile, tablet, laptop/desktop y XL) y como cambian los tamanos de cards segun el ancho disponible. Se basa en los breakpoints y grids definidos en el codigo actual.

## Convenciones

### Breakpoints de referencia (no globales)
Algunas pantallas usan sus propios cortes. Para poder leer el documento se usan estas categorias:
- Mobile: < 768 px
- Tablet: 768 - 1023 px
- Laptop/Desktop: 1024 - 1439 px
- XL: >= 1440 px

Si una pantalla usa un breakpoint distinto, se indica en su seccion.

### Formulas de tamano de cards

**Grid con crossAxisCount fijo (GridView.count / SliverGridDelegateWithFixedCrossAxisCount)**
- cols = crossAxisCount
- itemWidth = (availableWidth - (cols - 1) * crossAxisSpacing) / cols
- itemHeight = itemWidth / childAspectRatio

**Grid con maxCrossAxisExtent (SliverGridDelegateWithMaxCrossAxisExtent)**
- cols = floor((availableWidth + crossAxisSpacing) / (maxCrossAxisExtent + crossAxisSpacing))
- itemWidth = (availableWidth - (cols - 1) * crossAxisSpacing) / cols
- itemHeight = itemWidth / childAspectRatio

**Wrap con cards de ancho fijo**
- itemWidth = ancho fijo definido en el widget
- itemHeight = depende del contenido

### Available width
- En general: availableWidth = ancho del contenedor padre menos padding horizontal.
- En pantallas con columnas fijas: availableWidth es el ancho de la columna donde vive el grid.

---

## Dashboard (`lib/presentation/dashboard/dashboard_view.dart`)

### Layout general
- Mobile (<768): layout vertical (Welcome, QuickActions, SalesChart, ActiveTables).
- Tablet (768-1023): layout vertical igual que mobile.
- Laptop/Desktop (>=1024): split view. Columna izquierda (2/3) con Welcome + QuickActions + SalesChart, columna derecha (1/3) con ActiveTables.
- XL (>=1440): igual que desktop; activa flag `isWide` para ajustes finos.

### Breakpoints internos
- isMobile: width < 768
- isTablet: 768 <= width < 1024
- isWide: width >= 1440
- isSplitView: width >= 1024

### Quick Actions - 4 cards pequenas (Acciones Rapidas)
- Grid:
  - Mobile: 2 columnas, childAspectRatio = 1.15
  - Tablet: 4 columnas, childAspectRatio = 1.3
  - Desktop/XL: 4 columnas, childAspectRatio = 1.4
- Spacing: mainAxisSpacing = 16, crossAxisSpacing = 16
- Min height: 110 px por card
- Available width:
  - Mobile/Tablet (stack): `screenWidth - 2 * padding`
  - Desktop (split): `leftColumnWidth = ((screenWidth - 2 * padding) - gap) * 2/3`
- Formula: usar la formula de Grid con crossAxisCount fijo.

### Dashboard metric cards (Total Ventas, Promedio, Dia Record)
- Mobile/Tablet: Wrap en 2 columnas.
  - itemWidth = (availableWidth - 16) / 2
- Desktop/XL: Row con Expanded (ancho igual dividido en 3).

### Otros cards
- SalesChart y ActiveTables no usan grid; tamanos dependen del contenido y el ancho de columna.

---

## Main Shell - Top Nav (`lib/presentation/shell/main_shell.dart`)
- Breakpoint: showLabel si width >= 1024.
- En Mobile/Tablet se ve solo el icono; en Desktop/XL se muestra icono + label.

---

## Login (`lib/presentation/auth/login/login_view.dart`)
- Breakpoint: isWide si width >= 980.
- Mobile/Tablet: layout vertical, video arriba (height 220), form card abajo.
- Laptop/XL: layout en Row, video pane a la izquierda y form card a la derecha.
- Form card: maxWidth 480 (no crece mas en desktop/XL).

---

## Cashier (`lib/presentation/cashier/view/cashier_view.dart`)

### Stats Cards (Ingresos/Egresos/Balance/Transacciones)
- Breakpoint: isWide si width > 800.
- Wide: 1 fila con 4 cards (Expanded).
- Narrow: 2 filas de 2 cards.
- Tamanos: cards ocupan el ancho disponible del Row. Altura por contenido.

### Action Cards (Apertura/Cierre/Historial/Gestion)
- Breakpoint: isWide si width > 800.
- Wide: 2 filas con 2 cards por fila.
- Narrow: 4 cards en columna.
- Tamanos: cards Expanded cuando estan en Row; alto por contenido.

---

## Open/Close Cash (`lib/presentation/cashier/view/open_close_cash_view.dart`)
- Breakpoint: isWide si width > 800.
- Wide: 2 cards en fila, width fijo 400 cada una.
- Narrow: 2 cards en columna, width = full.

---

## Sales Responsive Shell (`lib/presentation/sales/widgets/sales_responsive_layout.dart`)
- Breakpoint: desktop si width >= 1024.
- Desktop/XL: Row con columnas fijas:
  - Sidebar = 224 px
  - Cart = 380 px
  - Catalog = restante (Expanded)
- Mobile/Tablet: Catalog como body, sidebar en drawer (width 280) y cart en endDrawer (width 380).

---

## Manual Sale (`lib/presentation/sales/view/manual_sale_view.dart`)
- Breakpoint: isDesktop si width >= 1024.
- Desktop/XL:
  - Row: Catalog (Expanded) + Cart (width 400).
- Mobile/Tablet:
  - Catalog full width con bottom bar flotante.
  - Cart en modal bottom sheet (height = 0.85 * screenHeight).

### Product cards grid
- SliverGridDelegateWithMaxCrossAxisExtent:
  - maxCrossAxisExtent = 240
  - childAspectRatio = 0.8
  - crossAxisSpacing = 16
- Cols y tamanos segun formula de MaxCrossAxisExtent.

---

## Table Order Screen (`lib/presentation/sales/view/table_order_screen.dart`)

### Categories grid
- maxCrossAxisExtent = 220
- childAspectRatio = 1.4
- spacing = 16

### Products grid
- maxCrossAxisExtent = 200
- childAspectRatio = 0.9
- spacing = 16

Tamanos calculados con formula de MaxCrossAxisExtent.

---

## Sales By Zone (`lib/presentation/sales/view/sales_by_zone_view.dart`)
- Grid de mesas:
  - maxCrossAxisExtent = 240
  - childAspectRatio = 2.0
  - spacing = 12
- Tamanos calculados con formula de MaxCrossAxisExtent.

---

## Catalog Column (Sales) (`lib/presentation/sales/widgets/catalog_column.dart`)

### Products grid
- maxCrossAxisExtent = 250
- childAspectRatio = 4/3
- spacing = 16

### Categories grid
- maxCrossAxisExtent = 200
- childAspectRatio = 1.5
- spacing = 16

Tamanos calculados con formula de MaxCrossAxisExtent.

---

## Menu Browser Sheet (`lib/presentation/sales/view/menu_browser_sheet.dart`)
- Grid responsive de productos (FixedCrossAxisCount):
  - width < 560: 2 columnas
  - 560 - 819: 3 columnas
  - 820 - 1079: 4 columnas
  - 1080 - 1279: 5 columnas
  - 1280 - 1499: 6 columnas
  - 1500 - 1799: 7 columnas
  - >= 1800: 8 columnas
- childAspectRatio = 1.15
- spacing = 12
- Tamanos con formula de FixedCrossAxisCount.

---

## Menu Browser Tabs (`lib/presentation/sales/view/widgets/menu_browser_tabs.dart`)
- Grid responsive de productos (FixedCrossAxisCount):
  - width < 560: 2 columnas
  - 560 - 819: 3 columnas
  - 820 - 1079: 4 columnas
  - 1080 - 1279: 5 columnas
  - >= 1280: 6 columnas
- childAspectRatio = 1.0
- spacing = 14

---

## KDS Kitchen Display (`lib/presentation/kds/screens/kitchen_display_screen.dart`)
- Grid de ordenes:
  - maxCrossAxisExtent = 400
  - childAspectRatio = 0.8
  - spacing = 16
- Tamanos con formula de MaxCrossAxisExtent.

---

## Reports (`lib/presentation/reports/view/reports_view.dart`)
- Grid fijo de categorias:
  - crossAxisCount = 5
  - childAspectRatio = 1.0 (square)
  - spacing = 24
- No hay breakpoints; en pantallas pequenas quedara muy denso.

---

## Settings (`lib/presentation/settings/view/settings_view.dart`)
- Grid de cards por seccion (FixedCrossAxisCount):
  - width >= 1200: 4 columnas
  - 900 - 1199: 3 columnas
  - 560 - 899: 2 columnas
  - < 560: 1 columna
- childAspectRatio = 3.2
- spacing = 12

---

## Printing Home (`lib/presentation/settings/more settings/printing/main/printing_home_view.dart`)
- Grid de cards (FixedCrossAxisCount):
  - width >= 1200: 3 columnas
  - 720 - 1199: 2 columnas
  - < 720: 1 columna
- childAspectRatio = 2.8
- spacing = 16 x 14

---

## Printing Receipts (`lib/presentation/settings/more settings/printing/receipts/view/printing_receipts_view.dart`)
- Grid fijo:
  - crossAxisCount = 2
  - childAspectRatio = 2.5
  - spacing = 24
- No breakpoints; ajustar si se requiere mejor mobile.

---

## Printing Products (`lib/presentation/settings/more settings/printing/products/view/printing_products_view.dart`)
- Grid fijo:
  - crossAxisCount = 3
  - childAspectRatio = 0.9
  - spacing = 16
- No breakpoints; ajustar si se requiere mejor mobile.

---

## Printing Orders (`lib/presentation/settings/more settings/printing/orders/view/printing_orders_view.dart`)
- Grid fijo:
  - crossAxisCount = 2
  - childAspectRatio = 2.5
  - spacing = 24
- No breakpoints; ajustar si se requiere mejor mobile.

---

## Customers Detail (`lib/presentation/customers/view/customer_detail_view.dart`)
- Cards de pedidos en Wrap:
  - width fijo = 400 px
  - spacing = 24
- En mobile se apilan 1 por fila; en desktop entran 2 o 3 segun ancho.

---

## Payments Modal - Numpad (`lib/presentation/payments/widgets/payment_modal.dart`)
- Grid fijo:
  - crossAxisCount = 3
  - childAspectRatio = 1.6
  - spacing = 12

---

## Pantallas sin responsive explicito
Estas pantallas no tienen breakpoints ni grids responsivos en el codigo actual (layout unico):
- Kitchen View (`lib/presentation/kitchen/view/kitchen_view.dart`)
- Products View (`lib/presentation/products/view/products_view.dart`)
- Customers View (`lib/presentation/customers/view/customers_view.dart`)
- Quick Sale / Sale Quick (`lib/presentation/sales/view/quick_sale_view.dart`, `lib/presentation/sales/view/sale_quick_view.dart`)
- Sale Manual / Table Order wrappers (`lib/presentation/sales/view/sale_manual_view.dart`, `lib/presentation/sales/view/table_order_screen.dart` fuera de grids)
- Self Service (`lib/presentation/sales/view/self_service_view.dart`)
- Settings subviews (users, roles, taxes, menus, categories, zones, printers list, etc.) donde no se declara LayoutBuilder/Grid responsive.

Si quieres, puedo ampliar este documento con formulas y cards especificas de cada subvista.
