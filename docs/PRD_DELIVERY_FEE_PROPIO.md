# PRD — Fee de Delivery Propio

**Fecha:** 2026-06-25
**Estado:** Fase 1 (DB) escrita, sin aplicar. Resto pendiente.

## Problema

En una venta de **delivery propio** (`delivery_type='own'`) el negocio cobra un
monto de envío que **varía por distancia** (ej. 50, 100, 150, 200). Hoy MangoPOS
no tiene forma de cobrarlo: el cajero tendría que meterlo como "producto", lo
cual lo grava con impuestos y ensucia el catálogo/reportes.

## Requisitos (del dueño)

1. Al cobrar un delivery propio, el cajero **define el monto del delivery**.
2. Hay **presets** (ej. 50 / 100 / 150 / 200) + monto libre.
3. Es **obligatorio** (no se puede cobrar un delivery propio sin fee).
4. **Mínimo** configurable en Ajustes.
5. **No es un producto**: es un **cargo extra, sin impuestos** (exento).

## Decisiones cerradas

- **D1 — Entrada del monto:** en el **modal de cobro** (gate obligatorio). Al
  cobrar un delivery propio, el modal exige elegir/escribir el monto
  (presets + libre, ≥ mínimo) antes de permitir el pago.
- **D2 — Fiscal:** el fee es **monto EXENTO**: no entra a la base de ITBIS/LEY,
  aparece como **línea "Delivery"** en el comprobante y suma al total →
  `total = subtotal + ITBIS + LEY + Delivery(exento)`.
- **D3 — Alcance:** solo `delivery_type='own'`. Uber Eats / Pedidos Ya traen su
  propio fee y quedan fuera.
- **D4 — Mandatorio + mínimo** configurables por negocio (se puede apagar el
  requerimiento; el mínimo por defecto = 0).

## Modelo de datos

- `orders.delivery_fee numeric(12,2) DEFAULT 0 NOT NULL` — cargo extra exento.
- `business_settings`:
  - `delivery_fee_required boolean DEFAULT true`
  - `delivery_fee_min numeric(12,2) DEFAULT 0`
  - `delivery_fee_presets jsonb DEFAULT '[]'` — arreglo de montos sugeridos.

## Cálculo de totales (clave)

`calculate_order_totals` **suma `orders.delivery_fee` al total DESPUÉS de
impuestos** (no entra a `subtotal`/`tax`):

```
_total := _subtotal + _tax + _service_fee - _discounts + _delivery_fee;
```

Crítico: el trigger `trg_recompute_order_on_items_change` llama a
`calculate_order_totals` en cada cambio de ítem, así que la función DEBE
preservar el fee — por eso se lee de `orders.delivery_fee` adentro, no se pasa
por fuera. `fn_set_delivery_fee(order_id, monto)` fija la columna y recomputa.

## Fiscal / NCF

`issue_fiscal_document` copia `o.subtotal`/`o.tax`/`o.total`. Como el fee vive
en `o.total` pero NO en `o.subtotal`/`o.tax`, el NCF queda:
`fd.total = items_total + delivery_fee`, con `fd.subtotal`/`fd.itbis` solo de los
ítems. El monto exento = `fd.total − (fd.subtotal + fd.itbis + fd.service_fee)`.
El recibo imprime la línea **"Delivery"** leyendo `orders.delivery_fee`.

> Nota e-CF: para comprobantes electrónicos (E3x) DGII pide montos exentos
> explícitos. F-futuro: poblar el bloque exento del e-CF con `delivery_fee`.

## Fases

- **F1 — DB/totales (este PRD):** columnas + `calculate_order_totals` con fee +
  `fn_set_delivery_fee` + ROLLBACK. **SIN aplicar.**
- **F2 — Cobro/UI:** gate obligatorio en el modal de pago de delivery propio
  (presets + monto libre, ≥ mínimo); panel de totales muestra "Delivery".
- **F3 — Ajustes:** Ajustes → Entrega a domicilio: presets + mínimo + requerido.
- **F4 — Impresión:** precuenta/recibo con la línea "Delivery" (exento).
- **F5 — Reportes:** ingreso por delivery rastreado aparte.

## Fuera de alcance (F1)

Split bill en delivery (el fee es order-level, no por check); e-CF exento
explícito; Uber/PedidosYa.
