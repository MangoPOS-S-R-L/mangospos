# Carga del menú de cócteles — AZOTEA 046 BAR & GRILL

Negocio: `e7a63240-6492-4ed5-8057-319ab91a748c`
Fuente: foto de una libreta con los precios escritos a mano (2026-09-22). No hay CSV.

## Cómo se corre

1. **`00_diagnostico.sql`**: solo lee y devuelve una sola tabla. Pégame el resultado.
2. **`IMPORT_COMPLETO.sql`**: la carga. Pégalo entero en el SQL Editor de Supabase
   y dale Run. Al final sale un reporte de 12 filas y todas deben decir ✓.

| Archivo | Para qué |
|---|---|
| `00_diagnostico.sql` | Negocio, ajustes, impuestos (¿hay Ley?), áreas, menús, catálogo previo, nombres parecidos, columnas vivas |
| **`IMPORT_COMPLETO.sql`** | **La carga, en una sola transacción** |
| `99_rollback.sql` | La deshace. Aborta si algún producto ya se vendió |

Todo va en una sola transacción: si algo no cuadra, se revierte completa. Se
puede volver a correr, porque empareja por nombre sin mayúsculas ni tildes.

## ✅ Corrido en producción (2026-09-22)

`IMPORT_COMPLETO.sql` corrió con el reporte en **12/12 ✓**. Quedaron 21 productos
activos, todos con ITBIS 18% + LEY 10% incluidos y ruteados a BAR (`bar`, con 1
impresora), con el legacy igual a la N:M, enlazados a MENU PRINCIPAL y sin
nombres parecidos. Una Cuba Libre de $375 queda en 292.97 de base + 82.03 de
impuestos.

Pendiente:
- Una venta de prueba: la comanda debe salir por el BAR y la factura con ITBIS + LEY.
- Confirmar el precio del Tequila Sunrise (400 o 360).
- Los precios de Bahama Mama y Blue Lagoon: se agregan a la lista y se vuelve a correr.

## Diagnóstico (2026-09-22)

| Chequeo | Resultado |
|---|---|
| Negocio | AZOTEA 046 BAR & GRILL / Sucursal Principal, tipo Restaurante |
| Impuestos | ITBIS 18% y LEY 10% activos, ninguno con `is_service_fee`. La LEY no aplica en delivery |
| `service_fee_enabled` | `false` ✓ |
| Catálogo previo | 2 productos, ambos en AGUAS Y SODAS, con ITBIS + LEY y con ventas |
| Categorías | CERVEZAS, **COCTELES**, RONES, SHOT, VODKA y WHISKEY (todas vacías y en posición 0), más AGUAS Y SODAS (posición 1) |
| Área | **BAR** (`bar`) con 1 impresora |
| Menú | Uno solo: MENU PRINCIPAL |
| Choques | Ninguno de los 21 existe, y no hay nombres parecidos |

## Catálogo: 21 productos, precios con impuestos incluidos

| Categoría | Productos |
|---|---|
| **COCTELES** (la que ya existía) | Mojito de Coco · Mojito de Limón · Mojito de Fresa · Piña Colada con Alcohol, $330 c/u · Margarita $450 · Martini $350 · Long Island Iced Tea $450 · Cuba Libre $375 · Gin Tonic $350 · Sangría $350 · Sex on the Beach $450 · Tequila Sunrise $400 · Coco Paradise $400 · Velvet Sunset · Tropical Azotea · Brisa Tropical · Deseo Prohibido · Passion Mamey, $375 c/u |
| **TRAGOS** (nueva, posición 0) | Trago de Chivas $400 · Trago de Tequila $400 · Trago de la Casa $375 |

Dentro de COCTELES van en el orden de la libreta: clásicos, tropicales y de la
casa. La agrupación de la libreta no se convirtió en categorías, porque el dueño
ya tenía COCTELES creada y vacía. TRAGOS va en mayúsculas y en la posición 0,
como las demás categorías del negocio.

**No se cargan:** Bahama Mama y Blue Lagoon, porque no tienen precio, ni Mango,
que está tachado.

## Lectura de la libreta (dudas)

| Renglón | Qué dice | Qué se cargó |
|---|---|---|
| Mojitos | "330" escrito encima de "350 - 380", ambos tachados | $330 los tres sabores |
| Margarita | "400" tachado, "450" | $450 |
| Tequila Sunrise | "(400 - 360)", con otro número tachado | **$400, por confirmar** |
| Gin tonic - Sangría | "350 ambos" | $350 cada uno |
| "Tragos Chiva" | Chivas | Trago de Chivas |

Los mojitos van como tres productos, uno por sabor, y no como un modificador:
así el bartender lee el sabor en la comanda y el reporte los separa.

## Impuestos

`tax_mode = 'inclusive'`: el precio de la libreta es lo que paga el cliente.
Siempre se vincula el ITBIS 18%. Para la Ley 10% hay un parámetro al principio
del script (`_cf_cfg.ley`). **Aquí quedó en `si`**, porque el negocio tiene la
LEY y la carta actual la lleva. Se fijó en vez de dejar `auto` para no depender
de solo 2 productos. Las opciones son:

- `auto`: si el negocio no tiene Ley, no se vincula. Si la tiene,
  copia lo que hace el catálogo actual: la vincula si está en el 90% o más, y
  no la vincula si está en el 10% o menos. Si no hay catálogo, o si está
  mezclado, aborta y pregunta.
- `si` / `no`: fuerza la decisión.

Con la Ley en modo incluido **el precio no sube**: el 10% se saca del precio.
Una Cuba Libre de $375 queda en 292.97 de base + 52.73 de ITBIS + 29.30 de LEY.

Aborta si la Ley tiene `is_service_fee = true` o si `service_fee_enabled` está
encendido, porque en esos casos se cobraría dos veces.

## Área de comanda

| Situación | Qué hace |
|---|---|
| `kitchen_enabled = false` | Ninguna área. La venta marca los ítems como listos |
| Hay un área `bar`/`barra` activa (por code o por nombre) | Esa |
| Hay una sola área activa | Esa |
| No hay ninguna área | Reactiva `bar`/`barra` si estaba apagada, o crea **"Bar"** (`bar`) sin impresora |
| Hay varias y ninguna es del bar | **Aborta** y las lista |

Escribe los dos mecanismos: `menu_item_print_areas` y el legacy `print_area_code`.
Aquí va a **BAR** (`bar`), que ya tiene impresora.

**Rollback:** solo borra la categoría TRAGOS. COCTELES no se toca, porque la
creó el dueño.

## Ensayo local (2026-09-22)

Se probó en un Postgres 15 local con el stub de 007 (sin acceso a prod). Pasaron
los 17 escenarios: negocio vacío, segunda corrida sin duplicar, rollback y
re-import, Ley auto (sin catálogo aborta; todo con Ley → la vincula; nada con
Ley → no; mezclado aborta; `si` la fuerza), Ley con `is_service_fee` aborta,
cocina apagada, `barra`, área única, "BAR" por nombre, varias áreas sin bar
aborta, producto previo en MAYÚSCULAS, inactivo y vendido (se actualiza y el
rollback aborta), "Mojito" a secas (el reporte lo marca), dos menús aborta,
producto repetido aborta y negocio sin ITBIS aborta.

Con el diagnóstico en mano, se armó una réplica del estado real: 7 categorías,
AGUA y SODA vendidas con ITBIS + LEY, y BAR con impresora. El diagnóstico sale
igual al de prod. En la réplica, la carga pasa **12/12 ✓**, la segunda corrida
no cambia nada, el rollback deja COCTELES y los 2 productos previos intactos, y
el re-import vuelve a dar 12/12.
