# UI_FLOW_MAP.md — Mapa de Flujos de Usuario

> Generado: 2026-02-25 | Auditor: Lovable AI

---

## 1. FLUJO DE AUTENTICACIÓN (Migrado a Supabase Auth)

```
[LoginView] 
  ├─ Validar formato de Email y Password
  ├─ Llamada a `supabase.auth.signInWithPassword`
  │   ├─ Credenciales válidas
  │   │   ├─ Buscar `profile` y `user_businesses` en Base de Datos
  │   │   └─ Inyectar SessionController → Navegar a `AppRoutes.dashboard`
  │   └─ Credenciales inválidas → Mostrar error (snackbar)
```

**Post-login:** Se muestra `<BrowserRouter>` con todas las rutas disponibles.

---

## 2. FLUJO PRINCIPAL DE NAVEGACIÓN

```
[TopNavigation] (fija, siempre visible)
  ├─ Home (/) → [Index/Dashboard]
  ├─ Ventas (/ventas) → [Ventas]
  ├─ Caja (/caja) → [Caja]
  ├─ Cocina (/cocina) → [Cocina]
  ├─ Productos (/productos) → [Productos]
  ├─ Reportes (/reportes) → [Reportes]
  └─ Más Ajustes (/ajustes) → [Ajustes]

Items deshabilitados si el rol no tiene permiso (muestra candado).
Dropdown de usuario permite:
  ├─ Cambiar Rol (Demo) → setCurrentRole()
  └─ Cerrar Sesión → logout() → vuelve a [PinLogin]
```

---

## 3. FLUJO DE VENTAS POR ZONA (core)

```
[Ventas] 
  ├─ [VentasSidebar] → selector de modo
  └─ [TablesGrid]
       ├─ Tabs: Salón / Terraza / VIP
       ├─ Click mesa disponible
       │   └─ setSelectedTable → [OrderScreen]
       ├─ Click mesa ocupada (propia)
       │   └─ setSelectedTable → [OrderScreen]
       └─ Click mesa ocupada (otro mesero, no Admin/Sup)
           └─ [PinVerificationModal] 
               ├─ PIN válido → acceder a [OrderScreen]
               └─ PIN inválido → error
```

### OrderScreen (pantalla de orden)

```
[OrderScreen]
  ├─ [ProductCatalog] (derecha)
  │   ├─ Filtrar por categoría
  │   ├─ Buscar producto
  │   └─ Click producto
  │       ├─ Sin modificadores → addItem directo al carrito
  │       └─ Con modificadores → [ProductCustomizationModal]
  │           ├─ Seleccionar modificadores
  │           ├─ Ajustar cantidad
  │           ├─ Agregar notas
  │           └─ Confirmar → addItem al carrito
  │
  ├─ [Cart] (izquierda, 380px)
  │   ├─ +/- cantidad → updateItemQuantity
  │   ├─ Eliminar item → removeItem
  │   ├─ Limpiar carrito → clearCart
  │   ├─ "Enviar a Cocina" → setOrderSent(true) + toast
  │   ├─ "Dividir Cuenta" → [SplitBillModal]
  │   ├─ "Precuenta" → [PreBillModal]
  │   └─ "Cobrar" → [PaymentModal]
  │
  ├─ [PaymentModal]
  │   ├─ Seleccionar método: Efectivo / Tarjeta / Transferencia
  │   ├─ Ingresar monto (numpad o montos rápidos)
  │   └─ Confirmar → [InvoiceModal]
  │
  ├─ [InvoiceModal]
  │   ├─ Ver factura
  │   ├─ Imprimir (solo toast)
  │   └─ Cerrar → liberar mesa → volver a [TablesGrid]
  │
  ├─ [SplitBillModal]
  │   ├─ Crear subcuentas
  │   ├─ Asignar items a subcuentas
  │   ├─ Dividir en partes iguales
  │   └─ Confirmar → toast (subcuentas no se cobran individualmente)
  │
  └─ [PreBillModal]
      ├─ Vista previa de precuenta
      └─ Imprimir (solo toast)
```

---

## 4. FLUJO DE VENTA RÁPIDA

```
[Ventas?mode=rapida] → [QuickSaleScreen]
  ├─ [ProductCatalog] → seleccionar productos
  ├─ [Cart] (sin "Enviar a Cocina", sin "Dividir", sin "Precuenta")
  │   └─ "Cobrar" → [PaymentModal] → [InvoiceModal] → clearCart
  └─ Sin propina (solo ITBIS 18%)
```

---

## 5. FLUJO DE VENTA MANUAL

```
[Ventas?mode=manual] → [ManualSaleScreen]
  ├─ Paso 1: [TableSelectionModal] → seleccionar mesa
  ├─ Paso 2: [ProductCatalog] + [Cart] (con propina 10%)
  │   ├─ "Enviar a Cocina" → toast
  │   ├─ "Precuenta" → [PreBillModal]
  │   └─ "Cobrar" → [PaymentModal] → [InvoiceModal] → volver atrás
  └─ Total = subtotal + ITBIS 18% + Propina 10%
```

---

## 6. FLUJO DE CAJA (Migrado a Supabase)

```
[CashierView]
  ├─ Estado: Caja Cerrada
  │   └─ "Aperturar Caja" → RPC `fn_open_cash_session`
  │
  ├─ Estado: Caja Abierta
  │   ├─ Ver balance calculado vía SQL
  │   ├─ "Ingreso" / "Egreso" → Inserta `cash_transactions` en tiempo real
  │   └─ "Cerrar Caja" → [BlindCashCloseModal]
  │       ├─ Ingresar conteo (efectivo/tarjeta)
  │       ├─ Calcular diferencias vs esperado (calculado por triggers DB)
  │       └─ Confirmar cierre → Update `cash_register_sessions` status

  │
  └─ Cards de módulos (Historial, Gestión de Cierres) → botones sin navegación
```

---

## 7. FLUJO DE COCINA / KDS (Tiempo Real Supabase)

```
[KitchenView]
  ├─ Websocket escuchando vista `kds_active_items` de Supabase
  │
  ├─ Columna "En Espera" (`pending`)
  │   └─ Botón "Preparar" → RPC `fn_start_preparing_order`
  │
  ├─ Columna "En Preparación" (`preparing`)
  │   └─ Botón "Listo" → RPC `fn_mark_order_ready`
  │
  ├─ [StockOutPanel] → marcar productos como agotados
  │   └─ (Pendiente conectar a DB)
  │
  └─ Auto-refresh es automático gracias a los streams de Supabase
```

---

## 8. FLUJO DE PRODUCTOS

```
[Productos]
  ├─ Buscar por nombre
  ├─ Filtrar por categoría
  ├─ "Agregar Elemento de Menú" → [ProductFormModal] → addProduct()
  ├─ Toggle disponible → updateProduct({ available })
  ├─ Menú ··· → Editar → [ProductFormModal] → updateProduct()
  └─ Menú ··· → Eliminar → [AlertDialog] → deleteProduct()
```

---

## 9. FLUJO DE CLIENTES

```
[Clientes]
  ├─ Buscar por nombre/email/teléfono
  ├─ Stats hardcodeados
  ├─ "Agregar Cliente" → sin funcionalidad
  ├─ "Importar" / "Exportar" → sin funcionalidad
  └─ Menú ··· por cliente → sin funcionalidad
```

---

## 10. FLUJO DE AJUSTES

```
[Ajustes] → Grid de ~70 items organizados en 16 secciones
  ├─ Items que redirigen a pantallas existentes (Ventas, Caja, Productos, Clientes)
  └─ Items que abren pantallas propias de config (/ajustes/*)
      └─ Cada pantalla tiene CRUD local con useState
          ├─ Agregar → modal con formulario
          ├─ Editar → modal con datos pre-llenados
          └─ Eliminar → confirmación → filter del array
```

---

## 11. PANTALLAS SIN FUNCIONALIDAD REAL

| Pantalla | Estado |
|----------|--------|
| Delivery (`/ventas?mode=delivery`) | Muestra grid de mesas, sin lógica delivery |
| Self Service (`/ventas?mode=selfservice`) | Muestra grid de mesas, sin lógica self-service |
| Reportes (todos) | Solo stats hardcodeados, sin datos reales |
| Informes (ajustes) | Pantallas placeholder con datos mock |
| Impresión | Todos los "imprimir" son toast |
| Notificaciones (campana) | Sin funcionalidad |
| "Asignar cliente" | Botón sin acción en OrderScreen, QuickSale, ManualSale |

---

## 12. DEPENDENCIAS ENTRE PANTALLAS

| Pantalla origen | Dato compartido | Pantalla destino |
|----------------|-----------------|------------------|
| PinLogin | `currentUser`, `currentRole` | TopNavigation, TablesGrid, OrderScreen |
| ProductsContext | `products`, `categories` | Productos, Combos, posiblemente Recetas |
| ProductAvailabilityContext | `stockOutProducts` | Cocina (alerta), ProductCatalog (filtro visual) |
| TablesGrid | `tables` (local) | OrderScreen, ManualSaleScreen |
| useCart | `items`, `subtotal`, `tax`, `total` | Cart, PaymentModal, SplitBillModal, PreBillModal, InvoiceModal |

**Nota:** `mock-products.ts` y `ProductsContext` son dos fuentes de datos separadas y NO están sincronizadas. El catálogo de ventas usa `mock-products.ts`, mientras que la página de Productos admin usa `ProductsContext`.
