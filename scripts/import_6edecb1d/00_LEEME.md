# Carga del menú — TÍA SARA

Negocio: `6edecb1d-e940-45ff-83b5-044ca08319fb`
Fuente: foto del menú impreso (2026-09-14). No hay CSV ni export.

## Cómo se corre

1. **`00_diagnostico.sql`**: solo lee. Pégame el resultado.
2. **`IMPORT_COMPLETO.sql`**: la carga. Pégalo entero en el SQL Editor de
   Supabase y dale Run. Al final sale una tabla de 14 filas y todas deben
   decir ✓.

| Archivo | Para qué |
|---|---|
| `00_diagnostico.sql` | Negocio, impuestos, áreas, catálogo previo, menús, columnas vivas |
| **`IMPORT_COMPLETO.sql`** | **La carga, en una sola transacción** |
| `99_rollback.sql` | Deshace la carga. Aborta si algún producto ya se vendió |

Va todo en una transacción. Primero comprueba todo y después, antes del commit,
verifica los 24 productos uno por uno. Si algo no cuadra, revierte entero. Se
puede volver a correr: empareja por nombre, actualiza lo que existe e inserta
lo que falta. Para corregir un precio, cámbialo en la lista del script y
córrelo de nuevo.

## ✅ Diagnóstico corrido — 2026-09-14

| Chequeo | Resultado |
|---|---|
| ITBIS 18% | uno solo, activo, `is_service_fee = false`, `include_in_ecf = true` ✓ |
| Canales del ITBIS | zona, manual, venta rápida, para llevar, delivery: los 5 ✓ |
| `service_fee_enabled` | `false` ✓ (no cobran Ley) |
| Catálogo previo | 0 categorías, 0 productos, 0 grupos, 0 menús: sin riesgo de duplicados |
| Áreas de comanda | **ninguna**: el import crea "Cocina" (`cocina`) |
| Ajustes | `auto_print_order = true`, `kitchen_enabled = true`, `printerless_kitchen = false`, `inventory_mode = none`, DOP |
| Columnas vivas | sin NOT NULL sin default que el script no llene. `menu_item_groups.position` existe (se escribe el orden de los grupos). `menu_items.product_type` existe, pero la app no la usa |

Como no hay ninguna área, la fila 10 del reporte ("Impresoras en el área") va a
salir **✗ y es esperado**: hay que vincular la impresora a "Cocina" en la app.
Con `auto_print_order` encendido, hasta entonces la comanda no sale.

## Decisiones del dueño (2026-09-14)

| | |
|---|---|
| Impuesto | ITBIS 18% **incluido** (`inclusive`). Pechu Tía 6 = $425 → base 360.17 + ITBIS 64.83 |
| Ley 10% | **No se cobra.** Aborta si `service_fee_enabled` está encendido |
| "PECHURINA" | Se llama **Pechu Tía** (corrección a mano en la foto) |
| Combos | El acompañamiento es **obligatorio al marcar** |

## Catálogo: 24 productos, 8 categorías, todo al área de cocina

| Categoría | Productos |
|---|---|
| Combos Tía Sara | Tía Sara 1 $475 · Tía Sara 2 $645 · Tía Sara Simple $350 · Tía Sara Feliz $575 · Tía Sara Súper Familiar $1,500 |
| Pechu Tía | 6 Piezas $425 · 8 Piezas $495 |
| Pica Pollo | 2 Piezas $350 · 3 Piezas $425 · 4 Piezas $525 · 5 Piezas $650 |
| Alitas de Pollo | 5 Piezas $445 · 6 Piezas $495 · 8 Piezas $700 |
| Extra Tía Sara | Alitas con Salsa Barbacoa $550 · Alitas Honey Mustard $575 · Tía Americana Buffalo $575 |
| Tía Pops | Tía Pops $300 |
| Agranda tu Orden | Papas Fritas · Tostones · Palitos de Yuca, $150 c/u |
| Salsas | La Sobrina · Especial Tía Sara · Wasakaka, $50 c/u |

Los combos y los Extra llevan la descripción del menú en `description`.

### Modificadores de los combos

Todos son de **1 sola opción, obligatorios y en $0**. Salen escritos en la
comanda debajo del combo.

| Combo | Pide |
|---|---|
| Tía Sara 1, Tía Sara Feliz | Acompañamiento 1 |
| Tía Sara Simple | Muslo (largo / corto) + Acompañamiento 1 |
| Tía Sara 2 | Acompañamiento 1 y 2 |
| Tía Sara Súper Familiar | Acompañamiento 1, 2, 3 y 4 |

Opciones de cada acompañamiento: Papas Fritas, Tostones, Palitos de Yuca.

**Por qué van en grupos separados y no en un "elige 2":** el diálogo de la POS
guarda la selección en un `Set`, así que no deja escoger la misma opción dos
veces. Con grupos separados el Tía Sara 2 sí puede salir con dos papas fritas.

## Cómo escoge el área de comanda

- Si existe `cocina`, usa esa.
- Si no, y hay **una** sola área de comida activa, usa esa.
- Si no hay ninguna, **crea** "Cocina" (`cocina`).
- Si hay varias, **aborta** y las lista.

Las áreas de sistema (`cashier`, `fiscal`, `cash_close`) no cuentan. Escribe
**los dos** mecanismos: `menu_item_print_areas` (N:M) y el legacy
`print_area_code`. Sin el legacy, el producto cae en `kitchen_hot` y "Enviar a
cocina" revienta.

## Qué más escribe (sin esto el menú no sirve)

- `menu_item_taxes`: sin fila, la factura sale con ITBIS 0.00.
- `menu_item_links`: sin fila, el producto no aparece en la caja. Reusa el
  menú activo o crea "Menú Principal". Aborta si hay más de uno.

## Ensayo local (2026-09-14)

Postgres 15 local con un stub del esquema (`schema.sql` + migraciones). No hay
acceso a prod. Los 11 escenarios pasaron:

| Escenario | Resultado |
|---|---|
| Diagnóstico | corre sin error |
| Negocio vacío | 24 productos / 8 categorías / 5 grupos / 14 opciones / 10 enlaces; crea `cocina` y el menú |
| Segunda corrida | idéntico, no duplica |
| Rollback → re-import | 0 → 24 |
| Catálogo previo ("PAPAS FRITAS" $100 con Ley, área bar y vendida) | queda $150, inclusive, solo ITBIS, solo cocina; el rollback aborta por la venta |
| Sin ITBIS activo · dos áreas sin cocina · `service_fee_enabled` · dos menús | aborta sin escribir nada |
| Una sola área (`freidora`) · `cocina` desactivada · sin columna `position` | funciona |

## Pendientes / dudas

1. **Impresora del área.** La fila 10 del reporte dice cuántas tiene. Con 0 la
   comanda no sale. Se vincula en Ajustes → Impresoras.
2. **"SUPER FAMILIAR 22.0"**: el menú trae ese "22.0" pegado al nombre. Lo
   cargué como "Tía Sara Súper Familiar".
3. **Salsas** entran como productos de $50, no como modificadores.
4. Un producto que ya existía con el mismo nombre **conserva su nombre**
   (p. ej. en MAYÚSCULAS); solo se actualizan precio, categoría, impuesto y
   área.
5. Sin inventario, costos, SKU ni código de barras: el menú no los trae.
