# BUSINESS_LOGIC_SUMMARY.md — Reglas de Negocio Implementadas

> Generado: 2026-02-25 | Auditor: Lovable AI

---

## 1. REGLAS DE NEGOCIO IMPLEMENTADAS

### 1.1 Autenticación y Acceso (Migrado a Supabase)

| Regla | Implementación | Archivo |
|-------|---------------|---------|
| Login Real | Supabase Auth (Email y password) | `login_viewmodel.dart` |
| Resolución de Negocio | Busca `business_id` en tabla `user_businesses` y `memberships` al logear | `login_viewmodel.dart` |
| Roles en BD | Administrador, Supervisor, Manager, Cashier, Waiter, Cook, Delivery (Enum en DB) | `schema.sql` → `user_role` |
| Fallback a Admin (Riesgo) | Si la tabla `user_businesses` no retorna resultados, asume `PosRole.administrador` | `login_viewmodel.dart:83` |
| Estado de Sesión real | Guarda el `userId`, nombre, `posRole` y `businessId` globalmente | `SessionController` (Riverpod) |

### 1.2 Cálculos Fiscales

| Regla | Valor | Ubicación |
|-------|-------|-----------|
| ITBIS (IVA dominicano) | 18% fijo | `useCart.ts` (constante `TAX_RATE = 0.18`) |
| Propina legal | 10% del subtotal | `ManualSaleScreen.tsx` (constante `TIP_RATE = 0.10`) |
| Total venta rápida | `subtotal + ITBIS` | `useCart.ts` |
| Total venta manual | `subtotal + ITBIS + propina` | `ManualSaleScreen.tsx` |
| Tax incluido en producto | Flag `taxIncluded` en Product pero NO se usa en cálculo | `pos.ts` (definido, no utilizado) |
| Tax rate por producto | Campo `taxRate` en Product pero NO se usa | `pos.ts` (definido, no utilizado) |

### 1.3 Carrito y Orden

| Regla | Implementación |
|-------|---------------|
| Precio unitario = precio producto + suma de modificadores | `useCart.ts` → `addItem()` |
| Total item = precio unitario × cantidad | `useCart.ts` → `addItem()` |
| Cantidad 0 o negativa → eliminar item | `useCart.ts` → `updateItemQuantity()` |
| Producto con modificadores → abrir modal de personalización | `OrderScreen.tsx` → `handleProductSelect()` |
| Producto sin modificadores → agregar directo al carrito | `OrderScreen.tsx` → `handleProductSelect()` |

### 1.4 Pagos (Real con Supabase RPC)

| Regla | Implementación |
|-------|---------------|
| Procesamiento | Llamada a `fn_process_payment` (RPC base de datos) que inserta pago de forma atómica |
| Cambio (Vuelto) | Efectivo soporta entregar cambio, tarjeta no (`cashier_repository_new.dart`) |
| Confirmación y cierre | Libera la mesa y cierra orden automáticamente en DB si está pagada |

### 1.5 División de Cuenta

| Regla | Implementación |
|-------|---------------|
| Crear subcuentas manualmente | `SplitBillModal.tsx` → `createSubAccount()` |
| Asignar items seleccionados a subcuenta | `SplitBillModal.tsx` → `assignItemsToSubAccount()` |
| Dividir equitativamente entre N personas | `SplitBillModal.tsx` → `splitEqually()` |
| Cada subcuenta calcula su propio subtotal/tax/total | Tax rate 18% aplicado por subcuenta |
| Items asignados no pueden re-asignarse | `assignedItemIds` Set filtra items disponibles |

### 1.6 Mesas

| Regla | Implementación |
|-------|---------------|
| Estados: disponible, ocupado, pagando | `Table.status` type union |
| Al abrir mesa disponible, se asigna el mesero actual | `TablesGrid.tsx` → `handleTableClick()` |
| Al completar pago, mesa vuelve a disponible | `TablesGrid.tsx` → `handleOrderComplete()` |
| 3 zonas: Salón, Terraza, VIP | Tabs en TablesGrid |

### 1.7 Productos

| Regla | Implementación |
|-------|---------------|
| Al agregar producto, incrementar `productCount` de categoría | `ProductsContext.tsx` → `addProduct()` |
| Al eliminar producto, decrementar `productCount` | `ProductsContext.tsx` → `deleteProduct()` |
| Al cambiar categoría de producto, ajustar contadores | `ProductsContext.tsx` → `updateProduct()` |
| No eliminar categoría con productos | `ProductsContext.tsx` → `deleteCategory()` |
| Toggle disponibilidad | `Productos.tsx` → `handleToggleAvailable()` |

### 1.8 Stock Out (Cocina)

| Regla | Implementación |
|-------|---------------|
| Cocina puede marcar productos como agotados | `ProductAvailabilityContext` → `markAsStockOut()` |
| Productos agotados se filtran visualmente | Alerta en Cocina page |
| Se registra quién y cuándo marcó agotado | `StockOutProduct` con `markedAt`, `markedBy` |

---

## 2. VALIDACIONES

### Formularios

| Formulario | Validación | Tipo |
|-----------|-----------|------|
| PIN Login | Longitud exacta 4 | Client-side |
| Pago efectivo | `monto >= total` | Client-side |
| Pago tarjeta | `monto <= total` | Client-side |
| Eliminar producto | Confirmación AlertDialog | UX |
| Eliminar categoría | `products.some(p.categoryId === id)` → bloquea | Logic |
| Cantidad en carrito | `quantity <= 0` → eliminar | Logic |
| Todos los formularios de ajustes | Sin validación de campos obligatorios | ⚠️ Sin validación |

### Permisos

| Validación | Implementación |
|-----------|---------------|
| Acceso a módulo | `useModuleAccess()` → checks compuestos |
| Acción específica | `hasPermission(code)` → lookup en array de permisos del rol |
| Admin bypass | Siempre `true` si `currentRole === "Administrador"` |

---

## 3. SUPOSICIONES DEL SISTEMA

| Suposición | Detalle |
|-----------|---------|
| Moneda única | Todo en RD$ (Peso Dominicano), sin conversión |
| ITBIS fijo 18% | No lee de configuración, hardcoded en `useCart` |
| Propina 10% solo en venta manual | No configurable |
| Un solo negocio | Sin multi-tenant |
| Una sola sucursal activa | Sin filtro por sucursal |
| Una sola caja | Caja #001 hardcodeada |
| PIN de 4 dígitos exactos | No soporta 5-6 dígitos |
| Usuarios predefinidos | No se pueden crear nuevos desde PinLogin |
| Sesión no persistente | Recarga = logout |
| Sin inventario real | Stock out es solo un flag en memoria |
| Sin facturación fiscal | NCF mencionado pero no implementado |

---

## 4. ESTADOS DE ENTIDADES

### Mesa (`dining_tables.state`)
```
disponible → occupied → (se cierra desde RPC Supabase) → disponible
```
**Nota Actualizada:** La mesa ocupa y desocupa sesiones transaccionalmente creando registros en la tabla `table_sessions` por un cajero/mesero específico.

### Orden (`orders.status` o `status_ext`)
```
open | active | closed | void
```
**Nota Actualizada:** Las órdenes viven permanentemente en BD. Los items adentro (`order_items.status`) viajan por los estados draft, sent, pending, preparing, ready, served.

### Comanda KDS
```
waiting → preparing (botón "Preparar") → completed (botón "Listo")
```
**Nota:** Los botones existen pero no ejecutan la transición. Los estados son estáticos en el mock.

### Usuario (`UserStatus`)
```
active | inactive | suspended
```
**Nota:** Solo visual en el formulario de usuarios. No afecta el login.

### Producto (`Product.available`)
```
true | false (toggle)
```
**Nota:** Solo afecta la UI de la tabla de productos admin. No filtra en el catálogo de ventas.

### Caja
```
cerrada → abierta (aperturar) → cerrada (cierre a ciegas)
```
**Nota:** Estado local `useState(false)`, se pierde al navegar.

### SubCuenta (`SubAccount.paid`)
```
false → true (cuando se paga)
```
**Nota:** Definido pero la acción de pagar subcuenta individual no está implementada.

---

## 5. LÓGICA DUPLICADA

| Duplicación | Ubicación A | Ubicación B | Impacto |
|------------|------------|------------|---------|
| Productos mock | `src/data/mock-products.ts` (20 prods) | `ProductsContext.tsx` (8 prods) | Catálogo de ventas y admin usan datos diferentes |
| Cálculo de tax | `useCart.ts` (TAX_RATE = 0.18) | `SplitBillModal.tsx` (TAX_RATE = 0.18) | Si cambia el rate, hay que actualizar en 2 lugares |
| Categorías | `mock-products.ts` (6 cats: bebidas, entradas...) | `ProductsContext.tsx` (6 cats: Platos Fuertes, Sopas...) | IDs y nombres diferentes |
| Formateo de moneda | `PaymentModal` (`RD$ ${amount.toLocaleString}`) | `SplitBillModal` (`RD$${amount.toLocaleString}`) | Formato inconsistente (con/sin espacio) |
| Roles/colores | `PinLogin.tsx` (roleColors) | `TopNavigation.tsx` (roleColors) | Mismo mapeo duplicado |
| Usuarios mock | `PinLogin.tsx` (MOCK_USERS) | No existe en ningún otro lugar | Los usuarios del login no son los mismos que los de `/ajustes/usuarios` |

---

## 6. CÓDIGO MUERTO / NO UTILIZADO

| Código | Archivo | Observación |
|--------|---------|-------------|
| `Order` interface | `pos.ts` | Definida pero nunca se instancia |
| `Payment` interface | `pos.ts` | Definida pero nunca se usa |
| `Table.orderId` | `pos.ts` | Definido pero nunca se asigna |
| `Table.status = "pagando"` | `pos.ts` | Definido pero nunca se transiciona |
| `Product.cost` | `pos.ts` | Definido pero nunca se usa |
| `Product.sku` | `pos.ts` | Definido pero nunca se usa |
| `Product.barcode` | `pos.ts` | Definido pero nunca se usa |
| `Product.taxIncluded` | `pos.ts` | Definido pero el cálculo siempre aplica tax encima |
| `Product.taxRate` | `pos.ts` | Definido pero siempre se usa 18% fijo |
| `NavLink` componente | `NavLink.tsx` | Componente huérfano, no se importa en ningún lado |
| `SettingsPlaceholder` | `ajustes/SettingsPlaceholder.tsx` | No se importa en ninguna ruta |
| `ImpresionComprobantes` route | `App.tsx` | Usa `ImpresionProductos` (reutilización incorrecta) |
| `ImpresionComandas` route | `App.tsx` | Usa `ImpresionProductos` (reutilización incorrecta) |
