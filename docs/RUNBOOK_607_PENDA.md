# Runbook — Auditoría del 607 de La Penda Express (agosto 2026)

`business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6`

Cierra los hallazgos H-1 y H-2 de la auditoría de DH Delgado Hernández & Asociados
del 31-ago-2026. **El orden importa**: hacerlo al revés declara de más.

---

## Qué se arregla y qué no

| Hallazgo | Qué es | Se cierra con |
|---|---|---|
| **H-1** · ITBIS en 0, RD$ 474 mil | El comprobante no separaba ITBIS de Ley | Pasos 2–5 |
| **H-2** · Ley 10% inventada, 104 facturas | El feed contable leía `order_item_tax_lines`, que no es historia | Paso 6 |
| **H-3** · 3 facturas por más de lo vendido | Ítems anulados después de facturar | **A mano** |
| **H-4** · 9 NCF sin venta ni cobro | Todos los ítems anulados, NCF vivo | **A mano** |

H-3 y H-4 son decisión del negocio: o se anulan formalmente o se reponen los productos.
No hay nada que programar ahí.

---

## El cambio de fondo

Los impuestos del comprobante pasan a salir **de la configuración del negocio**, no
de una regla cableada:

```
itbis_amount  ←  impuestos declarables
service_fee   ←  el resto
```

Quién decide qué es "declarable":

1. **`taxes.include_in_ecf`** — el interruptor de **Ajustes › Impuestos** ("se declara a
   la DGII"). Manda **sólo si el negocio ya lo configuró**, o sea si tiene al menos un
   impuesto activo marcado en `false`.
2. **Respaldo: el nombre del impuesto**, mientras nadie haya tocado el interruptor.

Por qué el respaldo: el backfill de `20260506_0004` dejó `include_in_ecf = NOT
is_service_fee`, así que un negocio que nunca tocó el interruptor tiene **todo** marcado
como declarable. Fiarse de eso a ciegas declararía la Ley 10% como ITBIS. Con el híbrido,
**no hay que cambiar la configuración de ningún negocio en producción**, y el día que
alguien apague el interruptor de la Ley la configuración toma el control sola.

`is_service_fee` **no se toca**: activarla duplica el impuesto en la factura impresa.

---

## Paso 1 · Verificar (solo lectura)

Correr `supabase/DIAGNOSTICO_auditoria_607_penda.sql`, secciones **8** y **10**.

- **Sección 10** → estado del interruptor. Informativo: el híbrido funciona igual.
- **Sección 8** → dice si falta el trigger de recompute (la migración `0009` lo resuelve
  en cualquier caso).

---

## Paso 2 · (opcional) El interruptor de la LEY

**No hace falta tocar nada para que esto funcione.** Con la LEY en `include_in_ecf =
true` (el default heredado), el híbrido cae al respaldo por nombre y reparte `18 / 10`
correctamente.

Apagar el interruptor de la Ley en **Ajustes › Impuestos** es lo semánticamente correcto
—una Propina Legal no es ITBIS— y hace que el reparto salga de la configuración en vez
del respaldo. Pero es opcional y se puede hacer después, con calma.

Si se hace, conviene saber que **no cambia lo que se le cobra al cliente**. Verificado:

- Ninguna función de la ruta de cobro lee `include_in_ecf` — `fn_resolve_order_item_tax_profile`
  y `fn_populate_item_tax_lines` filtran por `is_active`, `apply_on_*` y exclusiones por
  orden, nunca por esta bandera.
- En la app, el único consumidor del valor es un aviso visual en el diálogo de quitar
  impuestos, cuyo propio comentario dice *"Heurística SOLO para el aviso visual. No
  bloquea nada"*.
- La impresión no la usa. El e-CF lee el resultado (`itbis_amount`), no la bandera.

La bandera responde *"¿se declara a la DGII?"*, no *"¿se cobra?"*.

---

## Paso 3 · La función

```
supabase/migrations/20260902_0007_fd_split_by_tax_name.sql
```

Reparte por `include_in_ecf`, suma tasas por grupo (soporta más de dos impuestos) y
elimina el `ELSE 0` que hacía desaparecer el impuesto en silencio.

Solo afecta recomputes nuevos. No toca comprobantes ya emitidos.

---

## Paso 4 · El enganche de emisión

```
supabase/migrations/20260902_0009_ensure_recompute_fd_trigger.sql
```

`issue_fiscal_document` escribe el ITBIS directo desde `order.tax` y **no llama al
recompute** (medido). Sin este trigger, el paso 3 solo sirve para el backfill y los
comprobantes de septiembre nacen rotos igual.

La migración es condicional: crea únicamente lo que falte. Devuelve una fila si quedó bien.

**Prueba obligatoria antes de seguir:** cobrar una mesa de prueba con un producto al
28% y verificar que su comprobante nace con `itbis_amount` y `service_fee` correctos.
Si nace en cero, parar — el enganche no cerró y el backfill no tiene sentido todavía.

---

## Paso 5 · El backfill de agosto

```
supabase/BACKFILL_607_penda.sql
```

En orden: paso 1 (dry run) → paso 2 (total) → **cotejar con DH** → paso 2b (cuántas
filas) → paso 3 (triggers y e-CF) → paso 4 (el `UPDATE`, viene comentado).

- El total tiene que dar ~RD$ 779,169 de ITBIS corregido.
- Toma respaldo en `public._backup_fd_607_penda_agosto` antes de escribir.
- Verifica dentro de la transacción: si no cuadra, `ROLLBACK`.
- El UNDO está al final del archivo.
- **Correr en el SQL Editor de Studio.** Desde la app no falla: no hace nada, en
  silencio (`fiscal_documents` no tiene policy de UPDATE).

**No correr el paso 4 si el paso 3 muestra un trigger de e-CF en UPDATE**: un
comprobante electrónico ya transmitido se corrige con nota de crédito, no con UPDATE.

---

## Paso 6 · El feed contable

```
supabase/migrations/20260902_0008_analytics_ratio_from_items_only.sql
```

`analytics.documentos` deja de leer `order_item_tax_lines`. Esa tabla se reescribe
con DELETE+INSERT desde `menu_item_taxes` **al facturar**, mientras `order_items.tax`
se congela **al agregar el ítem**: si alguien cambia los impuestos de un producto
desde Más ajustes en medio del servicio, las líneas describen una venta que no ocurrió.
Medido en agosto: 451 de 19,494 ítems (2.3%), RD$ 58,277.94 de impuesto inventado.

Independiente de los pasos 2–5. Se puede aplicar antes o después.

---

## Después

- **Junio y julio** tienen el mismo hueco y ya están declarados → rectificativa ante
  la DGII. Decisión del negocio. El backfill sirve cambiando dos fechas.
- **Otros negocios** con Ley 10% y `include_in_ecf = true` tienen el mismo problema.
  Revisar antes de que les llegue su propia auditoría.
- **Nivel 2 pendiente**: `fiscal_document_taxes`, una fila por impuesto por comprobante,
  para que `itbis_amount`/`service_fee` queden derivadas y nadie las escriba a mano.
  No mezclar con esto.

---

## Rollback

Cada migración tiene su `_ROLLBACK.sql`. El backfill tiene su tabla de respaldo y su
UNDO. Nada de esto es irreversible.
