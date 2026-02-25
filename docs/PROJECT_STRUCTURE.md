# PROJECT_STRUCTURE.md — Inventario Técnico Completo

> Generado: 2026-02-25 | Auditor: Lovable AI | Versión: MangoPOS v1.0

---

## 1. PANTALLAS (Pages)

| Ruta | Archivo (Flutter) | Descripción |
|------|---------|-------------|
| `/` | `lib/presentation/dashboard/dashboard_view.dart` | Dashboard principal |
| `/ventas` | `lib/presentation/sales/view/sales_shell_view.dart` | Punto de venta principal y rutas anidadas |
| `/ventas?mode=rapida` | `lib/presentation/sales/view/sale_quick_view.dart` | Venta rápida sin mesa |
| `/ventas?mode=manual` | `lib/presentation/sales/view/manual_sale_view.dart` | Venta manual con cajero |
| `/ventas/table/:id` | `lib/presentation/sales/view/table_order_screen.dart` | Pantalla de orden en mesa específica |
| `/caja` | `lib/presentation/cashier/view/cashier_view.dart` | Gestión de caja conectada a Supabase |
| `/cocina` | `lib/presentation/kitchen/view/kitchen_view.dart` | KDS con real-time en Supabase |
| `/clientes` | `lib/presentation/customers/view/customers_view.dart` | Clientes (repositorio pendiente) |
| `/productos` | `lib/presentation/products/view/products_view.dart` | Productos (repositorio pendiente) |
| `/reportes` | `lib/presentation/reports/view/reports_view.dart` | Reportes (repositorio pendiente) |
| `/ajustes` | `lib/presentation/settings/view/settings_view.dart` | Ajustes unificados |
| `/ajustes/usuarios` | `src/pages/ajustes/Usuarios.tsx` | Gestión de usuarios con formulario multi-paso |
| `/ajustes/mozos` | `src/pages/ajustes/Mozos.tsx` | Gestión de meseros |
| `/ajustes/modificadores` | `src/pages/ajustes/Modificadores.tsx` | CRUD de grupos de modificadores |
| `/ajustes/combos` | `src/pages/ajustes/Combos.tsx` | CRUD de combos/paquetes |
| `/ajustes/menu` | `src/pages/ajustes/MenuConfig.tsx` | Configuración de menús con horarios |
| `/ajustes/recetas` | `src/pages/ajustes/Recetas.tsx` | Recetas con ingredientes y costos |
| `/ajustes/insumos` | `src/pages/ajustes/Insumos.tsx` | Materias primas e inventario |
| `/ajustes/config-comandas` | `src/pages/ajustes/ConfigComandas.tsx` | Configuración de impresión de comandas |
| `/ajustes/config-precuentas` | `src/pages/ajustes/ConfigPrecuentas.tsx` | Configuración de precuentas |
| `/ajustes/turnos` | `src/pages/ajustes/Turnos.tsx` | Gestión de turnos de trabajo |
| `/ajustes/cajas` | `src/pages/ajustes/Cajas.tsx` | Configuración de cajas registradoras |
| `/ajustes/impuestos` | `src/pages/ajustes/Impuestos.tsx` | Configuración fiscal (ITBIS, propina) |
| `/ajustes/monedas` | `src/pages/ajustes/Monedas.tsx` | Configuración multi-moneda |
| `/ajustes/config-regionales` | `src/pages/ajustes/ConfigRegionales.tsx` | Idioma, zona horaria, formato |
| `/ajustes/sucursales` | `src/pages/ajustes/Sucursales.tsx` | Gestión de sucursales |
| `/ajustes/kardex` | `src/pages/ajustes/Kardex.tsx` | Kardex por sucursal |
| `/ajustes/salida-inventario` | `src/pages/ajustes/SalidaInventario.tsx` | Salidas de inventario |
| `/ajustes/mover-inventario` | `src/pages/ajustes/MoverInventario.tsx` | Transferencias entre almacenes |
| `/ajustes/cuadre-stock` | `src/pages/ajustes/CuadreStock.tsx` | Ajustes de stock |
| `/ajustes/mermas` | `src/pages/ajustes/Mermas.tsx` | Registro de mermas |
| `/ajustes/requerimientos` | `src/pages/ajustes/Requerimientos.tsx` | Solicitudes de stock |
| `/ajustes/lista-compras` | `src/pages/ajustes/ListaCompras.tsx` | Lista de compras |
| `/ajustes/registro-compras` | `src/pages/ajustes/RegistroCompras.tsx` | Registro de compras |
| `/ajustes/gestion-proveedores` | `src/pages/ajustes/GestionProveedores.tsx` | Catálogo de proveedores |
| `/ajustes/credito-proveedores` | `src/pages/ajustes/CreditoProveedores.tsx` | Cuentas por pagar |
| `/ajustes/impresoras` | `src/pages/ajustes/Impresoras.tsx` | Configuración de impresoras |
| `/ajustes/impresion-productos` | `src/pages/ajustes/ImpresionProductos.tsx` | Asignación impresora-producto |
| `/ajustes/impresion-comprobantes` | Reutiliza `ImpresionProductos.tsx` | Misma pantalla |
| `/ajustes/impresion-comandas` | Reutiliza `ImpresionProductos.tsx` | Misma pantalla |
| `/ajustes/tarjeta` | `src/pages/ajustes/Tarjeta.tsx` | Config pagos con tarjeta |
| `/ajustes/transferencias` | `src/pages/ajustes/Transferencias.tsx` | Config transferencias |
| `/ajustes/historial-pagos` | `src/pages/ajustes/HistorialPagos.tsx` | Historial de transacciones |
| `/ajustes/notas-credito` | `src/pages/ajustes/NotasCredito.tsx` | Notas de crédito |
| `/ajustes/monitor-ventas` | `src/pages/ajustes/MonitorVentas.tsx` | Monitor en tiempo real |
| `/ajustes/venta-credito` | `src/pages/ajustes/VentaCredito.tsx` | Venta a crédito |
| `/ajustes/gestion-creditos` | `src/pages/ajustes/GestionCreditos.tsx` | Cuentas por cobrar |
| `/ajustes/creditos-clientes` | `src/pages/ajustes/CreditosClientes.tsx` | Créditos de clientes |
| `/ajustes/gestion-costos` | `src/pages/ajustes/GestionCostos.tsx` | Control de costos |
| `/ajustes/gestion-metas` | `src/pages/ajustes/GestionMetas.tsx` | Metas de ventas |
| `/ajustes/tarjeta-fidelidad` | `src/pages/ajustes/TarjetaFidelidad.tsx` | Programa de fidelidad |
| `/ajustes/niveles-membresias` | `src/pages/ajustes/NivelesMembresias.tsx` | Membresías VIP |
| `/ajustes/promociones` | `src/pages/ajustes/Promociones.tsx` | Promociones y descuentos |
| `/ajustes/cupones` | `src/pages/ajustes/Cupones.tsx` | Códigos promocionales |
| `/ajustes/gift-cards` | `src/pages/ajustes/GiftCards.tsx` | Tarjetas de regalo |
| `/ajustes/puntos-recompensa` | `src/pages/ajustes/PuntosRecompensa.tsx` | Sistema de puntos |
| `/ajustes/historial-fidelidad` | `src/pages/ajustes/HistorialFidelidad.tsx` | Historial de fidelidad |
| `/ajustes/opciones-sistema` | `src/pages/ajustes/OpcionesSistema.tsx` | Opciones del sistema |
| `/ajustes/opciones-app` | `src/pages/ajustes/OpcionesApp.tsx` | Opciones de la app |
| `/ajustes/info-restaurante` | `src/pages/ajustes/InfoRestaurante.tsx` | Info del negocio |
| `/ajustes/gestion-sucursales` | `src/pages/ajustes/GestionSucursales.tsx` | Admin multi-sucursal |
| `/ajustes/actualizaciones` | `src/pages/ajustes/Actualizaciones.tsx` | Versiones |
| `/ajustes/integracion-marketing` | `src/pages/ajustes/IntegracionMarketing.tsx` | Marketing |
| `/ajustes/config-credito-fiscal` | `src/pages/ajustes/ConfigCreditoFiscal.tsx` | NCF y DGII |
| `/ajustes/informe-ventas` | `src/pages/ajustes/InformeVentas.tsx` | Informe de ventas |
| `/ajustes/informe-compras` | `src/pages/ajustes/InformeCompras.tsx` | Informe de compras |
| `/ajustes/informe-finanzas` | `src/pages/ajustes/InformeFinanzas.tsx` | Informe financiero |
| `/ajustes/informe-inventario` | `src/pages/ajustes/InformeInventario.tsx` | Informe de inventario |
| `/ajustes/informe-asistencia` | `src/pages/ajustes/InformeAsistencia.tsx` | Informe de personal |
| `/ajustes/indicadores` | `src/pages/ajustes/Indicadores.tsx` | Dashboard de KPIs |
| `*` | `src/pages/NotFound.tsx` | Página 404 |

**Total: ~70 rutas registradas**

---

## 2. COMPONENTES REUTILIZABLES

### Layout
| Componente | Archivo |
|-----------|---------|
| `MainLayout` | `src/components/layout/MainLayout.tsx` — Wrapper con TopNavigation + padding |
| `TopNavigation` | `src/components/layout/TopNavigation.tsx` — Barra superior fija con logo, nav, usuario |
| `NavLink` | `src/components/NavLink.tsx` |

### Ventas (módulo core)
| Componente | Archivo | Función |
|-----------|---------|---------|
| `VentasSidebar` | `src/components/ventas/VentasSidebar.tsx` | Sidebar con modos de venta |
| `TablesGrid` | `src/components/ventas/TablesGrid.tsx` | Grid de mesas + routing por mode |
| `TableCard` | `src/components/ventas/TableCard.tsx` | Card individual de mesa |
| `OrderScreen` | `src/components/ventas/OrderScreen.tsx` | Pantalla de orden (catálogo + carrito) |
| `QuickSaleScreen` | `src/components/ventas/QuickSaleScreen.tsx` | Venta rápida sin mesa |
| `ManualSaleScreen` | `src/components/ventas/ManualSaleScreen.tsx` | Venta manual con propina |
| `Cart` | `src/components/ventas/Cart.tsx` | Sidebar de carrito |
| `ProductCatalog` | `src/components/ventas/ProductCatalog.tsx` | Grid de productos por categoría |
| `ProductCustomizationModal` | `src/components/ventas/ProductCustomizationModal.tsx` | Modal de modificadores/notas |
| `PaymentModal` | `src/components/ventas/PaymentModal.tsx` | Modal de pago con numpad |
| `SplitBillModal` | `src/components/ventas/SplitBillModal.tsx` | División de cuentas (manual + equitativa) |
| `PreBillModal` | `src/components/ventas/PreBillModal.tsx` | Precuenta/pre-factura |
| `InvoiceModal` | `src/components/ventas/InvoiceModal.tsx` | Factura post-pago |
| `TableSelectionModal` | `src/components/ventas/TableSelectionModal.tsx` | Selector de mesa (venta manual) |

### Dashboard
| Componente | Archivo |
|-----------|---------|
| `WelcomeCard` | `src/components/dashboard/WelcomeCard.tsx` |
| `QuickActions` | `src/components/dashboard/QuickActions.tsx` |
| `SalesChart` | `src/components/dashboard/SalesChart.tsx` |
| `ActiveTablesWidget` | `src/components/dashboard/ActiveTablesWidget.tsx` |

### Auth
| Componente | Archivo |
|-----------|---------|
| `PinLogin` | `src/components/auth/PinLogin.tsx` — Login con PIN de 4 dígitos |
| `PinVerificationModal` | `src/components/auth/PinVerificationModal.tsx` — Verificación para acceder a mesa de otro mesero |

### Caja
| Componente | Archivo |
|-----------|---------|
| `BlindCashCloseModal` | `src/components/caja/BlindCashCloseModal.tsx` — Cierre a ciegas |

### Cocina
| Componente | Archivo |
|-----------|---------|
| `StockOutPanel` | `src/components/cocina/StockOutPanel.tsx` — Panel de productos agotados |

### Productos
| Componente | Archivo |
|-----------|---------|
| `ProductFormModal` | `src/components/productos/ProductFormModal.tsx` — Formulario crear/editar producto |
| `CategoryFormModal` | `src/components/productos/CategoryFormModal.tsx` — Formulario de categoría |

### Usuarios
| Componente | Archivo |
|-----------|---------|
| `UserFormModal` | `src/components/usuarios/UserFormModal.tsx` — Formulario multi-paso de usuario |

### UI (shadcn/ui)
**~50 componentes** en `src/components/ui/` (accordion, alert, badge, button, calendar, card, chart, checkbox, dialog, dropdown, form, input, label, popover, progress, scroll-area, select, separator, sheet, sidebar, skeleton, slider, sonner, switch, table, tabs, textarea, toast, toggle, tooltip, etc.)

---

## 3. HOOKS PERSONALIZADOS

| Hook | Archivo | Función |
|------|---------|---------|
| `useCart` | `src/hooks/use-cart.ts` | Estado del carrito: items, addItem, updateQuantity, remove, subtotal/tax/total (ITBIS 18% hardcodeado) |
| `useMobile` | `src/hooks/use-mobile.tsx` | Detección de viewport mobile |
| `useToast` | `src/hooks/use-toast.ts` | Hook del sistema de toast |

---

## 4. PROVIDERS / CONTEXT (State Management)

| Provider (Riverpod) | Archivo | Estado que maneja |
|----------|---------|-------------------|
| `sessionProvider` | `lib/presentation/auth/login/session_controller.dart` | Auth, user_id, business_id, rol actual |
| `tablesProvider` | Varios en `sales/state/` | Sincronización de mesas activas |
| `cartProvider` | `lib/presentation/sales/state/cart_controller.dart` | Carrito de compras, ítems, totales |
| `kitchenProvider` | `lib/presentation/kitchen/state/` | Suscripción real-time a comandas de cocina (`kds_active_items`) |

---

## 5. TIPOS (TypeScript)

| Archivo | Tipos definidos |
|---------|-----------------|
| `src/types/pos.ts` | Product, CartItem, Category, Table, Order, SubAccount, Payment, Menu, Modifier, ModifierGroup, SelectedModifier, PaymentMethod, ProductType |
| `src/types/users.ts` | User, Role, Permission, PermissionGroup, EmploymentInfo, EmergencyContact, EmployeeDocument, UserFormData, RoleFormData + constantes DEFAULT_ROLES, ALL_PERMISSIONS |

---

## 6. DATOS MOCK / HARDCODEADOS

| Ubicación | Tipo de dato | Contenido |
|-----------|-------------|-----------|
| `src/data/mock-products.ts` | Catálogo de ventas | 20 productos con modificadores (bebidas, entradas, platos, postres, combos, extras) |
| `src/contexts/ProductsContext.tsx` | Catálogo admin | 8 productos iniciales (duplicación parcial con mock-products) |
| `src/components/auth/PinLogin.tsx` | Usuarios demo | 6 usuarios: Carlos (Admin/0000), María (Supervisor/1111), Pedro (Cajero/2222), Ana (Mesero/1234), Luis (Mesero/5678), José (Cocina/3333) |
| `src/components/ventas/TablesGrid.tsx` | Mesas | 14 mesas: 8 salón, 4 terraza, 2 VIP, algunas con estado ocupado mock |
| `src/pages/Caja.tsx` | Movimientos | 5 movimientos hardcodeados, stats fijos (RD$ 45,200 ingresos, 28 transacciones) |
| `src/pages/Cocina.tsx` | Comandas | 4 órdenes mock con items y tiempos |
| `src/pages/Clientes.tsx` | Clientes | 5 clientes mock con historial |
| `src/pages/Reportes.tsx` | Estadísticas | Todos los valores hardcodeados (RD$ 1,250,000 ventas, 842 transacciones, etc.) |
| `src/pages/Ajustes.tsx` | Info negocio | RNC mock, NCF disponibles, impresoras activas |
| `src/types/users.ts` | Roles y permisos | 6 roles predefinidos con ~100 permisos granulares |
| Cada página `/ajustes/*` | Datos internos | Cada pantalla de configuración tiene su propio `useState` con datos iniciales mock |

---

## 7. ESTADOS SIMULADOS / LÓGICA TEMPORAL

| Área | Detalle |
|------|---------|
| **Autenticación** | PIN-based, sin backend, usuarios en array constante. No hay sesión persistente. |
| **Permisos** | Evaluados en memoria desde DEFAULT_ROLES. Demo de cambio de rol en TopNavigation. |
| **Carrito** | Estado local en `useCart` hook. Se pierde al navegar fuera. |
| **Mesas** | Estado local en `TablesGrid`. Se resetean al recargar. |
| **Productos admin** | `ProductsContext` en memoria. Se pierden al recargar. |
| **Productos ventas** | `mock-products.ts` (archivos separados, no sincronizados con ProductsContext). |
| **Stock out** | `ProductAvailabilityContext` en memoria. |
| **Pagos** | Solo UI. No se registra ningún pago. El "pago" solo muestra la factura y libera la mesa. |
| **Envío a cocina** | Solo cambia flag `orderSent` local. No se envía nada al KDS. |
| **Impresión** | Todos los botones de "imprimir" solo muestran `toast.success`. |
| **Todas las config** | Cada página de ajustes tiene su propio `useState` independiente. No hay persistencia. |

---

## 8. VALIDACIONES ACTUALES

| Contexto | Validación |
|----------|------------|
| PIN Login | Longitud = 4, match contra array de usuarios mock |
| PIN Verification | Match del PIN contra rol requerido |
| Pago efectivo | `amountReceived >= total` para habilitar botón |
| Pago tarjeta/transferencia | `numericAmount <= total` (permite parcial) |
| Eliminar categoría | Solo si no tiene productos asociados |
| Formulario producto | Campos requeridos manejados por el modal |
| Cantidad carrito | Si `quantity <= 0`, se elimina el item |
| Acceso a mesa | Si es de otro mesero y no eres Admin/Supervisor, requiere PIN |
| Permisos de módulo | `hasPermission()` evalúa código de permiso contra rol actual |

---

## 9. SERVICIOS / INTEGRACIONES (Actualizado)

**El sistema ya no es un prototipo local. Está conectado a:**

- **Supabase Backend**: Migrado completamente. Uso extenso de `supabase_flutter`.
- **Supabase Auth**: Manejo de inicio de sesión seguro con JWTs.
- **Supabase RPCs**: Lógica transaccional compleja movida a la base de datos (Ej: `fn_process_payment`, `fn_close_order_and_table`).
- **Supabase Realtime**: Websockets nativos usados en cocina (`KitchenRepository`).
- **Agente de impresión local (`printer-service`)**: Puente Node/Binario ejecutado transparentemente por la app Flutter nativa (escrito en `main.dart`) para hablar ESC/POS con impresoras.
