# PRD 9 — Módulo de Inventario MangoPOS

| Campo | Valor |
|---|---|
| **Producto** | MangoPOS |
| **Módulo** | Inventario, Compras, Cuentas por Pagar |
| **Versión del documento** | 1.0 |
| **Fecha** | 2026-05-01 |
| **Autor** | Cristian — Innovech Software LLC |
| **Estado** | Aprobado para desarrollo |
| **Stack** | Flutter (Windows + Android), Supabase (PostgreSQL + PL/pgSQL), Coolify, Traefik, Cloudflare |

---

## 1. Resumen ejecutivo

MangoPOS hoy permite gestionar un menú de productos y emitir facturas de venta, pero **no controla inventario**. Este módulo agrega gestión completa de existencias multi-local con trazabilidad total: desde la solicitud de compra hasta el pago al proveedor, pasando por recepción, costeo y descuento automático en cada venta.

El diseño se ancla en un **kardex inmutable** (tabla `inventory_movements`) que sirve como libro mayor de todo movimiento de stock. El stock actual es un cache derivado, no la fuente de verdad. Esto permite auditoría completa, recálculos retroactivos cuando es necesario, y rollback seguro de errores operativos.

El alcance V1 es un **POS de restaurante/bar con items vendidos tal cual**, sin recetas ni BOM. La arquitectura ya contempla la evolución a recetas en V2 sin migración destructiva.

---

## 2. Contexto y motivación

### 2.1 Producto actual

MangoPOS es un POS basado en Flutter con variantes Windows desktop (publicado en Microsoft Store vía MSIX) y Android (Play Store + APK sideloaded). Backend en Supabase self-hosted sobre Coolify. La tabla `menu_items` ya gestiona el catálogo del menú con campos para productos preparados (`prep_minutes`, `print_area_code`, `is_beverage`, `dietary`).

El sistema ya existe parcialmente para inventario:

- `inventory_items` (datos maestros básicos: nombre, costo, min/max stock)
- `inventory_stock` (cantidad por bodega, sin costo promedio aún)
- `inventory_movements` (kardex con enum de tipos)
- `warehouses`, `suppliers`, `purchase_orders`, `purchase_order_items`, `menu_item_links`

Sin embargo, faltan: capas FIFO, recepciones formales, facturas de proveedor, cuentas por pagar, pagos, transferencias, ajustes, RPCs transaccionales, y la integración con ventas existentes.

### 2.2 Problema

1. **No hay control de existencias**: el negocio no sabe en tiempo real cuánto stock tiene de cada item ni en qué bodega.
2. **No hay costeo**: sin costo promedio o FIFO, no se puede calcular margen real por venta.
3. **No hay flujo de compras**: las compras al proveedor se manejan manualmente fuera del sistema.
4. **No hay cuentas por pagar**: no se sabe cuánto se le debe a cada proveedor ni qué facturas vencen.
5. **No hay multi-local**: el negocio crece a varias sucursales y no puede transferir stock entre ellas.

### 2.3 Oportunidad

Cerrar el ciclo operativo completo del negocio dentro de MangoPOS, eliminando la dependencia de planillas de Excel paralelas y reduciendo errores humanos. Habilita reportes de margen real, alertas de reorden, y trazabilidad fiscal (NCF, ITBIS) — todo crítico en el mercado dominicano.

---

## 3. Objetivos

### 3.1 Objetivos de negocio

| ID | Objetivo | Métrica de éxito |
|---|---|---|
| ON-1 | Reducir mermas no detectadas | Variancia de inventario físico vs sistema < 2% mensual |
| ON-2 | Eliminar quiebres de stock | < 5% de items en estado "out of stock" durante horas pico |
| ON-3 | Visibilidad financiera | 100% de facturas de proveedor registradas con CxP visible |
| ON-4 | Habilitar crecimiento multi-local | Soportar transferencias entre N bodegas sin pérdida de stock |
| ON-5 | Reportes de margen | Margen real (precio venta − costo) calculable por item, día y bodega |

### 3.2 Objetivos técnicos

| ID | Objetivo |
|---|---|
| OT-1 | Toda mutación de stock pasa por RPC transaccional (PL/pgSQL) — nunca UPDATE suelto desde el cliente |
| OT-2 | Kardex (`inventory_movements`) es inmutable — corrección vía movimiento de reverso |
| OT-3 | RLS multi-tenant por `business_id` activo en todas las tablas |
| OT-4 | Concurrencia segura mediante `SELECT ... FOR UPDATE` sobre `inventory_stock` y `stock_layers` |
| OT-5 | API consistente para Flutter desktop y mobile sin lógica duplicada |

---

## 4. Usuarios y casos de uso

### 4.1 Roles

| Rol | Descripción | Permisos típicos |
|---|---|---|
| **Administrador** | Dueño o gerente general | Todo: configuración, reportes, ajustes, pagos |
| **Encargado de bodega** | Recibe mercancía, hace conteos | Recepción, transferencias, ajustes, consultas |
| **Comprador** | Genera órdenes de compra | OC, vista de proveedores, vista de stock |
| **Cajero / Mesero** | Vende productos | Solo consume stock vía facturación (sin acceso al módulo) |
| **Contador** | Registra facturas y pagos | Facturas de proveedor, CxP, pagos, reportes financieros |

### 4.2 Casos de uso priorizados

**CU-01 — Recibir mercancía contra orden de compra**
El encargado de bodega recibe un pedido del proveedor, valida cantidades vs OC, registra diferencias si las hay, y confirma la recepción. El sistema actualiza stock con costo provisional.

**CU-02 — Registrar factura del proveedor**
El contador recibe la factura física del proveedor, la asocia a una o más recepciones, registra NCF, ITBIS, fecha de vencimiento. El sistema crea la CxP y, si el costo de factura difiere del costo provisional, ajusta las capas remanentes.

**CU-03 — Vender un item (integración con flujo existente)**
El cajero factura una venta. El sistema resuelve cada `menu_item` a su `inventory_item` vía `menu_item_links` y descuenta el stock de la bodega configurada para esa venta, usando el método de costeo del item.

**CU-04 — Transferir stock entre bodegas**
El encargado del local A envía 20 botellas de Aperol al local B. Las botellas salen del local A → entran a bodega virtual `__IN_TRANSIT__`. Cuando el local B confirma recepción, salen de tránsito → entran al local B. Las diferencias se registran como merma con razón.

**CU-05 — Conteo físico (inventario)**
El encargado hace un conteo físico, ingresa las cantidades reales, y el sistema genera ajustes con razón (rotura, vencimiento, robo, error de conteo) para cuadrar el sistema con la realidad.

**CU-06 — Pagar a proveedor**
El contador registra un pago al proveedor. Puede aplicarse a una factura (parcial o total) o a varias. La CxP se actualiza con el saldo restante.

**CU-07 — Recibir alertas de reorden**
Cuando un item cae bajo su `min_stock`, el sistema notifica al encargado para generar una nueva OC.

---

## 5. Alcance

### 5.1 Dentro del alcance (V1)

- Items inventariables (sin recetas) enlazados 1:1 a `menu_items`
- Multi-bodega con transferencias y bodega virtual de tránsito
- Costeo dual: promedio ponderado o FIFO según el item
- Solicitud de compra → OC → Recepción (parcial/total) → Factura → CxP → Pago
- Ajustes manuales con razón obligatoria
- Conteos físicos
- Numeración correlativa secuencial por documento (PO-000001, GR-000001, etc.)
- Reportes: stock actual, kardex, low/out of stock, valorización, CxP por vencer, margen real
- Alertas de reorden por `min_stock`
- ITBIS (18% default) y NCF en facturas de proveedor
- Integración con flujo de venta existente (descuento automático al facturar)

### 5.2 Fuera del alcance (V2 o posterior)

- Recetas / BOM (cócteles preparados, platos compuestos)
- Lotes con fecha de vencimiento por capa (la estructura lo soporta, pero no se expone en UI)
- Códigos de barras con escáner físico (el campo `barcode` existe, escáner se integra después)
- Múltiples monedas (todo en DOP)
- Integración con DGII (e-CF) para facturas de proveedor
- Solicitudes de compra con flujo de aprobación multi-nivel
- Pronósticos de demanda / reorden inteligente
- App móvil dedicada para encargado de bodega (todo va sobre el cliente Flutter existente)
- Conciliación bancaria
- Devoluciones a proveedor (V1.1)

---

## 6. Decisiones de diseño tomadas

Estas decisiones están cerradas y forman la base del desarrollo. Cualquier cambio requiere revisión formal de este PRD.

| # | Decisión | Razón |
|---|---|---|
| D1 | RPCs en **PL/pgSQL** dentro de Supabase | Transacciones nativas, locks sin red intermedia, consistencia garantizada bajo concurrencia |
| D2 | Numeración correlativa **simple secuencial** (`PO-000001`) | Simple, suficiente para V1, sin complejidad de formatos por año |
| D3 | Cuando la factura final cambia el costo, **solo se ajustan capas remanentes** | Pragmático: no recalcula ventas pasadas; emite `cost_adjustment` para auditoría |
| D4 | Bodega virtual `__IN_TRANSIT__` automática por business | Stock nunca se "pierde" durante transferencias multi-día |
| D5 | Stock actual es **cache** (`inventory_stock.average_cost` + `quantity_on_hand`); fuente de verdad es el kardex | Permite recalcular si hay corrupción, soporta auditoría temporal |
| D6 | Costeo configurable **por item** (`costing_method`: `average` o `fifo`) | Algunos productos perecederos requieren FIFO; otros (no perecederos) son más simples con promedio |
| D7 | `stock_layers` se mantiene siempre, aún en items con costeo `average` | Auditoría uniforme; permite cambiar método sin migración destructiva |
| D8 | V1 sin recetas: cada `menu_item` enlaza 1:1 a un `inventory_item` con `quantity_consumed = 1` | Modelo ya soporta recetas; V1 simplemente usa cardinalidad 1 |
| D9 | RLS multi-tenant **activo** desde Fase 0 | Seguridad por defecto, no agregada después |

---

## 7. Requisitos funcionales

### 7.1 Maestros

**RF-MA-01** Gestión de bodegas (CRUD): código, nombre, dirección, marca de bodega principal.

**RF-MA-02** Gestión de proveedores (CRUD): nombre, RNC, contacto, teléfono, email, dirección, condiciones de pago, notas.

**RF-MA-03** Gestión de items inventariables (CRUD): nombre, SKU, código de barras, unidad de medida, costo inicial, min/max stock, método de costeo (`average` o `fifo`).

**RF-MA-04** Vincular `menu_items` a `inventory_items` 1:1 mediante `menu_item_links` con `quantity_consumed` (siempre 1 en V1).

**RF-MA-05** Función de bootstrap (`bootstrap_menu_to_inventory_links`) que genera automáticamente los `inventory_items` faltantes a partir de los `menu_items` activos y crea los enlaces 1:1 sin duplicar por SKU/nombre.

### 7.2 Compras

**RF-CO-01** Crear orden de compra con: proveedor, bodega destino, items con cantidad y costo unitario, ITBIS por línea (default 18%), fecha esperada, notas.

**RF-CO-02** Estados de OC: `draft` → `sent` → `partial_received` → `received` → `closed`. También `cancelled`.

**RF-CO-03** Numeración automática `PO-000001` al crear (vía `next_document_number`).

**RF-CO-04** Editar OC en estado `draft`. Bloquear edición una vez `sent`.

**RF-CO-05** Cancelar OC en cualquier estado salvo `received` o `closed`.

### 7.3 Recepción

**RF-RE-01** Recepción puede ser **contra OC** o **directa** (sin OC previa).

**RF-RE-02** Recepción parcial soportada: una OC puede tener múltiples `goods_receipts`.

**RF-RE-03** Por cada línea: cantidad recibida, cantidad rechazada (calidad), notas.

**RF-RE-04** Al confirmar recepción, RPC `receive_goods()`:
- Crea `inventory_movements` tipo `receipt_provisional`
- Crea `stock_layers` con `is_provisional = true`
- Actualiza `inventory_stock.quantity_on_hand`
- Recalcula `average_cost` si el item es `costing_method = 'average'`
- Actualiza `purchase_order_items.quantity_received`
- Actualiza estado de la OC (`partial_received` o `received`)

**RF-RE-05** Numeración `GR-000001`.

### 7.4 Facturas de proveedor y CxP

**RF-FA-01** Registrar factura del proveedor: número, NCF, fecha emisión, fecha vencimiento, líneas (asociadas a `goods_receipt_items` cuando aplique), subtotal, ITBIS, otros cargos, total.

**RF-FA-02** Al crear la factura, generar automáticamente la `accounts_payable` con `total_amount`, `due_date`, `paid_amount = 0`.

**RF-FA-03** Si el `unit_cost` de la factura difiere del provisional de la recepción, RPC `finalize_receipt_costs()`:
- Marca `stock_layers.is_provisional = false`
- Ajusta `unit_cost` de capas remanentes
- Recalcula `average_cost` si aplica
- Emite `inventory_movements` tipo `cost_adjustment` por la diferencia

**RF-FA-04** No se recalculan ventas ya facturadas (decisión D3). El ajuste solo afecta stock remanente.

**RF-FA-05** Numeración `SI-000001` (o el número de la factura del proveedor — configurable).

### 7.5 Pagos a proveedor

**RF-PA-01** Registrar pago: proveedor, fecha, monto, método de pago, referencia, notas.

**RF-PA-02** Aplicar pago a una o varias CxP. Validar que la suma de aplicaciones = monto del pago.

**RF-PA-03** Actualizar `accounts_payable.paid_amount` y `status` (`pending` → `partially_paid` → `paid`).

**RF-PA-04** Numeración `SP-000001`.

### 7.6 Transferencias entre bodegas

**RF-TR-01** Crear transferencia: bodega origen, bodega destino, items con cantidades. La RPC `transfer_send()` valida stock disponible, descuenta de origen, suma a `__IN_TRANSIT__`.

**RF-TR-02** Confirmar recepción en destino con cantidades reales. La RPC `transfer_receive()` saca de `__IN_TRANSIT__`, agrega a destino, registra varianza con razón si difiere de lo enviado.

**RF-TR-03** Estados: `draft` → `sent` → `received`. También `cancelled`.

**RF-TR-04** Numeración `ST-000001`.

### 7.7 Ajustes e inventarios físicos

**RF-AJ-01** Crear ajuste con razón obligatoria: `physical_count`, `breakage`, `expiration`, `theft`, `correction`, `other`.

**RF-AJ-02** Por cada item: cantidad antes (snapshot), cantidad contada, diferencia auto-calculada.

**RF-AJ-03** Al confirmar, RPC `adjust_inventory()` genera `inventory_movements` tipo `adjustment_in` o `adjustment_out` según el signo.

**RF-AJ-04** Numeración `IA-000001`.

### 7.8 Integración con ventas

**RF-VE-01** Al confirmar una venta, RPC `sell_items()` itera sobre cada `menu_item_links`:
- Resuelve `menu_item → inventory_item`
- Multiplica por `quantity_consumed` (siempre 1 en V1)
- Consume capas según `costing_method`
- Actualiza `inventory_stock`
- Crea `inventory_movements` tipo `sale` con `reference_type = 'sale'` y `reference_id = sale.id`

**RF-VE-02** Si un `menu_item` no tiene link a `inventory_item`, se ignora (no bloquea la venta). Se loguea para revisión.

**RF-VE-03** Si no hay stock suficiente, comportamiento configurable por business: bloquear venta o permitir stock negativo (V1 default: permitir negativo, alertar).

**RF-VE-04** Devolución: RPC `return_sale_items()` genera `inventory_movements` tipo `sale_return`, repone capas (con costo histórico de la venta original).

### 7.9 Reportes

**RF-RP-01** Stock actual por bodega con filtros: in stock, low stock (`< min_stock`), out of stock (`= 0`).

**RF-RP-02** Kardex por item: todos los movimientos con cantidad, costo, balance acumulado.

**RF-RP-03** Valorización de inventario: stock × costo promedio actual, total por bodega y consolidado.

**RF-RP-04** CxP por vencer: agrupado por proveedor, con días vencidos.

**RF-RP-05** Historial de compras por proveedor: OCs, recepciones, facturas, pagos.

**RF-RP-06** Margen real por venta: precio − costo (de las capas consumidas).

**RF-RP-07** Alertas activas: items bajo `min_stock`, facturas próximas a vencer (configurable, default 7 días).

---

## 8. Requisitos no funcionales

### 8.1 Rendimiento

- **RNF-1** Las RPC de venta (`sell_items`) deben completarse en < 200ms p95 con hasta 50 líneas por venta.
- **RNF-2** El reporte de stock actual debe cargar en < 1s para businesses con < 10,000 items.
- **RNF-3** El kardex de un item debe paginarse: 50 movimientos por página.

### 8.2 Concurrencia

- **RNF-4** Dos cajas simultáneas vendiendo el mismo item no deben generar inconsistencias en `quantity_on_hand` ni en costos. Garantizado vía `SELECT ... FOR UPDATE`.
- **RNF-5** Una recepción y una venta concurrentes deben serializarse a nivel de `(item_id, warehouse_id)`.

### 8.3 Seguridad

- **RNF-6** RLS multi-tenant en todas las tablas: ningún usuario debe ver datos de otro `business_id`.
- **RNF-7** Las RPC deben validar `business_id` del usuario autenticado vs. el `business_id` del recurso.
- **RNF-8** Roles enforced en cliente (UI) y backend (RPC). El backend no confía en el cliente.

### 8.4 Auditabilidad

- **RNF-9** Todo movimiento de stock queda registrado en `inventory_movements` con `created_by` y `created_at`.
- **RNF-10** Los registros del kardex son inmutables. Correcciones se hacen con movimientos de reverso, nunca con UPDATE/DELETE.

### 8.5 Disponibilidad y resiliencia

- **RNF-11** El sistema debe seguir vendiendo (`sell_items`) aún si los reportes están temporalmente lentos.
- **RNF-12** En caso de pérdida de conexión Supabase, el cliente Flutter debe encolar ventas localmente y reintentar (mecanismo ya existente en el POS).

### 8.6 Localización

- **RNF-13** UI en español (es-DO).
- **RNF-14** Moneda: peso dominicano (DOP), formato `RD$ 1,234.56`.
- **RNF-15** ITBIS por defecto 18%, configurable por línea de OC/factura.

---

## 9. Arquitectura y modelo de datos

### 9.1 Principios

1. **Kardex como libro mayor**: `inventory_movements` es la fuente de verdad. Stock derivado.
2. **Capas siempre**: `stock_layers` se crea para todos los items, independiente del método de costeo. Permite cambio de método sin migración destructiva.
3. **RPCs en PL/pgSQL**: toda mutación de stock pasa por funciones transaccionales con locks explícitos.
4. **RLS por defecto**: cada tabla con `business_id` tiene política `business_member_access`.

### 9.2 Tablas principales

| Tabla | Propósito | Estado |
|---|---|---|
| `inventory_items` | Catálogo de items inventariables | Existe — extender con `costing_method`, `barcode`, `updated_at` |
| `warehouses` | Bodegas físicas y virtuales | Existe — usar como está |
| `inventory_stock` | Cache de stock por item × bodega | Existe — extender con `average_cost`, `quantity_reserved` |
| `inventory_movements` | Kardex inmutable | Existe — agregar enums faltantes |
| `stock_layers` | Capas de costo por entrada (FIFO + auditoría) | Nueva |
| `menu_item_links` | Puente menú → inventario | Existe — extender con `quantity_consumed` |
| `suppliers` | Proveedores | Existe |
| `purchase_orders` + `_items` | Órdenes de compra | Existen |
| `goods_receipts` + `_items` | Recepciones | Nuevas |
| `supplier_invoices` + `_lines` | Facturas de proveedor | Nuevas |
| `accounts_payable` | CxP | Nueva |
| `supplier_payments` + `_applications` | Pagos a proveedor | Nuevas |
| `stock_transfers` + `_items` | Transferencias | Nuevas |
| `inventory_adjustments` + `_items` | Ajustes / conteos | Nuevas |
| `document_sequences` | Numeración correlativa | Nueva |

### 9.3 Funciones (RPC) críticas

| RPC | Responsabilidad |
|---|---|
| `next_document_number()` | Numeración correlativa atómica |
| `ensure_in_transit_warehouse()` | Crear/obtener bodega virtual `__IN_TRANSIT__` por business |
| `bootstrap_menu_to_inventory_links()` | Migración inicial de menú a inventario |
| `receive_goods()` | Confirmar recepción (manual o contra OC) |
| `finalize_receipt_costs()` | Convertir capas provisionales en finales al recibir factura |
| `sell_items()` | Descontar stock al facturar venta |
| `return_sale_items()` | Reponer stock por devolución de venta |
| `transfer_send()` / `transfer_receive()` | Transferencias entre bodegas |
| `adjust_inventory()` | Ajustes manuales con razón |
| `register_supplier_payment()` | Aplicar pago a una o varias CxP |

---

## 10. Flujos clave

### 10.1 Flujo de compra completo

```
[Solicitud informal] → Crear OC (draft) → Enviar OC al proveedor (sent)
    → Recibir mercancía (parcial o total) → Stock + capas provisionales
    → Llega factura física → Registrar factura → Crear CxP
    → finalize_receipt_costs() ajusta capas a costo real
    → Pagar (parcial o total) → CxP actualizada
```

### 10.2 Flujo de venta con descuento de stock

```
Mesero / cajero → Confirma factura
    → sell_items() resuelve menu_item → inventory_item
    → Para cada item: lock stock + consumir capas (FIFO o avg)
    → Crear movements tipo 'sale' con reference a la venta
    → Actualizar inventory_stock
    → Si bajo min_stock: emitir alerta
```

### 10.3 Flujo de transferencia entre bodegas

```
Bodega A → transfer_send(items) → Stock A baja, IN_TRANSIT sube
    → Movimiento físico (camioneta, persona)
    → Bodega B → transfer_receive(items, cantidades reales)
    → Si cantidades coinciden: IN_TRANSIT baja, Stock B sube
    → Si difieren: registrar varianza como ajuste de merma
```

---

## 11. UI/UX guidelines

### 11.1 Lineamientos generales

- Mantener el lenguaje visual de MangoPOS actual (colores, tipografía, componentes Flutter ya existentes).
- Usar la captura del menú lateral del usuario (Inventory / Add items / In stock / Low stock / Out of stock) como punto de entrada principal.
- Mostrar siempre el contexto de bodega activa en la barra superior cuando se trabaja en operaciones de stock.

### 11.2 Pantallas principales (alto nivel)

1. **Dashboard de Inventario**: tarjetas con conteo de items in/low/out of stock, valor total inventario, alertas activas.
2. **Listado de items**: tabla con búsqueda, filtros por categoría/bodega/estado de stock, columnas configurables.
3. **Detalle de item**: stock por bodega, kardex paginado, costo actual, vinculación a `menu_items`.
4. **Recepción**: wizard de 3 pasos (seleccionar OC o crear directa → líneas con cantidades → confirmar).
5. **Factura de proveedor**: formulario con líneas vinculables a recepciones pendientes.
6. **CxP**: listado por vencer, con acción rápida "Registrar pago".
7. **Transferencia**: formulario de envío + bandeja de "Por recibir" en bodega destino.
8. **Ajuste / Conteo físico**: pantalla optimizada para tablet con ingreso rápido por SKU/barcode.
9. **Reportes**: stock actual, kardex, valorización, CxP, margen.

### 11.3 Mobile vs Desktop

- **Desktop (Windows)**: enfoque en operaciones de oficina (compras, facturas, reportes, configuración).
- **Mobile (Android tablet)**: enfoque en operaciones de bodega (recepción, conteo, transferencias). Pantallas optimizadas para ingreso rápido.

---

## 12. Plan de release por fases

| Fase | Entregable | Días estimados | Acumulado |
|---|---|---|---|
| **0** | Schema completo (ALTERs + tablas nuevas + RLS + helpers) | 3-4 | 4 |
| **1** | UI de maestros: bodegas, proveedores, items + bootstrap de menú | 4-5 | 9 |
| **2** | Recepción manual + RPC `receive_goods` + vista de stock por bodega | 5-6 | 15 |
| **3** | Integración con ventas: RPC `sell_items` + reporte de margen | 4-5 | 20 |
| **4** | Transferencias entre bodegas (send/receive con IN_TRANSIT) | 3-4 | 24 |
| **5** | Ajustes e inventarios físicos | 3-4 | 28 |
| **6** | Órdenes de compra completas (CRUD + estados + recepción contra OC) | 5-6 | 34 |
| **7** | Facturas de proveedor + CxP + finalize_receipt_costs | 4-5 | 39 |
| **8** | Pagos a proveedor con aplicaciones múltiples | 3-4 | 43 |
| **9** | Reportes y alertas (low stock, CxP por vencer, valorización) | 4-5 | 48 |

**MVP vendible: Fases 0-3 (~20 días)**. Permite gestionar stock, recibir mercancía, vender con descuento automático, y reportar margen.

**Release completo V1: 38-48 días** trabajando solo a ritmo sostenible.

### 12.1 Hitos de release

- **M1 — Inventory MVP** (fin Fase 3): se vende y se descuenta correctamente. Suficiente para piloto en un local pequeño.
- **M2 — Multi-local** (fin Fase 5): transferencias y ajustes operativos. Listo para crecer.
- **M3 — Ciclo de compras completo** (fin Fase 8): OC, factura, CxP, pago. Ciclo financiero cerrado.
- **M4 — V1 final** (fin Fase 9): reportes y alertas. GA público.

---

## 13. Métricas de éxito y KPIs

### 13.1 KPIs operativos (medibles desde el sistema)

- % de ventas con stock correctamente descontado (objetivo: 100%)
- Tiempo promedio de recepción de mercancía (objetivo: < 10 min por OC pequeña)
- % de facturas de proveedor registradas dentro de 48h de recepción (objetivo: > 90%)
- Variancia entre conteo físico y sistema (objetivo: < 2% mensual)
- Tiempo p95 de RPC `sell_items` (objetivo: < 200ms)

### 13.2 KPIs de negocio (medibles a 90 días post-launch)

- Reducción de quiebres de stock vs. baseline pre-módulo
- Margen real promedio por categoría de menú
- DSO de proveedores (días promedio de pago)
- Items con rotación lenta identificados (no vendidos en 30 días)

### 13.3 KPIs de adopción

- # businesses activos usando el módulo / total businesses
- # de bodegas configuradas por business
- # de OCs creadas por mes
- # de transferencias entre bodegas por mes

---

## 14. Riesgos y mitigaciones

| Riesgo | Probabilidad | Impacto | Mitigación |
|---|---|---|---|
| Concurrencia en ventas simultáneas genera inconsistencias de stock | Media | Alto | RPCs con `SELECT FOR UPDATE`. Tests de carga antes de release. |
| Migración de items existentes duplica registros | Media | Medio | `bootstrap_menu_to_inventory_links` es idempotente y deduplica por SKU/nombre. |
| Stock negativo permitido genera caos contable | Media | Alto | Configuración por business. Default V1 permite negativo con alerta visible. V1.1 evalúa cambio. |
| Capas FIFO crecen indefinidamente y degradan performance | Baja | Medio | Índice parcial `where remaining_quantity > 0`. Job de archivo de capas vacías > 1 año. |
| Costo provisional vs final genera reclamos contables | Media | Medio | `cost_adjustment` movement deja rastro. Reporte específico de ajustes para contador. |
| Transferencias quedan colgadas en `__IN_TRANSIT__` | Baja | Medio | Reporte "Transferencias pendientes > 7 días". Notificación al admin. |
| Adopción lenta por usuarios no técnicos | Alta | Alto | Onboarding guiado en V1.1. Importación masiva desde Excel. Videos cortos por flujo. |
| RLS mal configurada expone datos cross-tenant | Baja | Crítico | Tests automatizados de RLS por business. Auditoría manual antes de release. |

---

## 15. Dependencias

### 15.1 Internas (MangoPOS)

- Sistema de autenticación de Supabase (`auth.uid()`) y tabla de membresía business-user.
- Flujo de facturación existente (debe invocar `sell_items` al confirmar venta).
- Sistema de roles existente (debe agregarse permisos de inventario).

### 15.2 Externas

- Supabase self-hosted operativo (Coolify, Traefik, Cloudflare).
- PostgreSQL 15+ con extensión `pgcrypto`.
- Cliente Flutter ≥ versión actual de MangoPOS.

### 15.3 Bloqueos potenciales

- Si la tabla de membresía no se llama `business_users(user_id, business_id)`, la función `user_belongs_to_business` debe ajustarse antes de Fase 0.
- Si los enums `inventory_movement_type` y `purchase_status` ya tienen valores con nombres distintos a los propuestos, la migración debe alinearse.

---

## 16. Glosario

- **Kardex**: Libro mayor inmutable de movimientos de inventario. Tabla `inventory_movements`.
- **Capa (layer)**: Lote de stock con costo unitario asociado. Tabla `stock_layers`.
- **Costo provisional**: Costo registrado al recibir mercancía, antes de tener la factura final del proveedor.
- **Costo final**: Costo confirmado al registrar la factura del proveedor. Puede diferir del provisional por descuentos, fletes, ITBIS.
- **CxP (Cuentas por Pagar)**: Saldo pendiente con un proveedor por una factura recibida. Tabla `accounts_payable`.
- **NCF**: Número de Comprobante Fiscal (DGII República Dominicana).
- **ITBIS**: Impuesto sobre Transferencias de Bienes Industrializados y Servicios (DR). Default 18%.
- **RNC**: Registro Nacional de Contribuyentes (DR).
- **FIFO**: First In, First Out — primer lote en entrar es el primero en salir.
- **Costo promedio ponderado**: `(stock_actual × costo_actual + cantidad_entrada × costo_entrada) / (stock_actual + cantidad_entrada)`.
- **BOM (Bill of Materials)**: Receta — lista de ingredientes que componen un producto. Fuera de alcance V1.
- **RPC**: Remote Procedure Call. Funciones PL/pgSQL invocadas desde Flutter vía Supabase.
- **RLS**: Row Level Security — políticas de Postgres que filtran filas por usuario.

---

## 17. Anexos

### 17.1 Estado actual del schema (verificado 2026-05-01)

Tablas ya existentes con su estado:
- `inventory_items` — extender (Fase 0)
- `inventory_stock` — extender (Fase 0)
- `inventory_movements` — completo
- `menu_item_links` — extender (Fase 0)
- `warehouses`, `suppliers` — completas
- `purchase_orders`, `purchase_order_items` — completas

Tablas a crear (Fase 0):
- `stock_layers`, `goods_receipts(_items)`, `supplier_invoices(_lines)`, `accounts_payable`, `supplier_payments(_applications)`, `stock_transfers(_items)`, `inventory_adjustments(_items)`, `document_sequences`.

### 17.2 Archivo de migración

Migración SQL completa de Fase 0 entregada en archivo separado: `001_inventory_phase0_schema.sql`. Incluye ALTERs idempotentes, creación de tablas, función `next_document_number`, función `ensure_in_transit_warehouse`, función `bootstrap_menu_to_inventory_links`, RLS multi-tenant, y triggers.

### 17.3 Próximas migraciones

- `002_inventory_rpcs.sql` — RPCs core (`receive_goods`, `sell_items`, `transfer_send/receive`, `adjust_inventory`, `finalize_receipt_costs`, `register_supplier_payment`).
- `003_inventory_views.sql` — Vistas y reportes (low/out stock, kardex, valorización, CxP por vencer, margen real).

### 17.4 Decisiones pendientes para V1.1+

- Permitir/bloquear venta con stock negativo (config por business).
- Política de archivo de capas vacías > 1 año.
- Importación masiva de items desde Excel/CSV.
- Codigo de barras con escáner físico USB (Bluetooth para tablet).
- Soporte de lotes con fecha de vencimiento.

---

**Aprobaciones**

| Rol | Nombre | Fecha | Firma |
|---|---|---|---|
| Product Owner | Cristian | 2026-05-01 | _________ |
| Tech Lead | Cristian | 2026-05-01 | _________ |
| Stakeholder negocio | _________ | _________ | _________ |

---

*Fin del documento.*
