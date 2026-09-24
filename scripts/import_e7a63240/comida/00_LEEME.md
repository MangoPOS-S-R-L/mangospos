# Carga del menú de comida: AZOTEA 046 BAR & GRILL

Negocio: `e7a63240-6492-4ed5-8057-319ab91a748c`
Fuente: lista de precios pegada en el chat (2026-09-23). Los cócteles se cargaron el 22-sep (`../IMPORT_COMPLETO.sql`).

## Cómo se corre

1. **`00_diagnostico_comida.sql`**: solo lee y devuelve una tabla. Lo importante es la sección 3 (¿hay área de cocina con impresora?).
2. **`IMPORT_COMIDA.sql`**: pégalo entero en el SQL Editor y dale Run. Al final sale un reporte de 12 filas.
3. (`99_rollback_comida.sql`): lo deshace. Aborta si algún plato ya se vendió.

Los tres `.sql` se generan con `./build.sh` a partir de `_productos.sql` (la lista) y de las plantillas `_tpl_*.sql`. **Para cambiar un precio, edita `_productos.sql` y corre `./build.sh`.**

## Qué carga

56 platos en 9 categorías nuevas, en las posiciones 10 a 18 (después de las bebidas). Llevan ITBIS 18% + LEY 10% **incluidos** (`inclusive`), igual que los cócteles, y van al área de la **cocina**, nunca al BAR.

| Categoría | Platos |
|---|---|
| ENTRADAS | 8 (la lista no traía título para esta sección) |
| ESPECIALES DE LA CASA Y PASTAS | 5 |
| CARNES | 9 |
| POLLO | 10 |
| MOFONGOS | 4 |
| MARISCOS, PESCADOS Y CHIVO | 6 |
| ENSALADAS | 4 |
| SOPAS | 3 |
| GUARNICIONES | 7 (productos sueltos, no modificadores) |

**No se carga:** Mofongo Azotea, porque no tiene precio.

## Decisiones

- **"Brisa tropical" ($295) se carga como "Brisa Tropical (Entrada)".** Ya existe el cóctel Brisa Tropical ($375), y la carga empareja por nombre, así que lo habría pisado. Además, la guarda 1f aborta si un nombre de la lista existe como bebida o fuera de las categorías de comida.
- "Indonsa con parisienne de camarones" va tal cual vino.
- Área: usa una de cocina (code `cocina`/`kitchen`/`kitchen_hot`/`comida`, o que se llame así). Si no hay ninguna, crea **"Cocina"** (`cocina`) sin impresora, y la fila 10 del reporte sale ✗ hasta que se le vincule una impresora en la app. Según el diagnóstico del 22-sep, el negocio solo tenía BAR.

## Ensayo local (2026-09-23)

`ensayo/run_tests.sh` usa PG15 y una réplica del estado de prod: el diagnóstico del 22-sep más los 21 cócteles cargados con el script real. Resultados:

- **S1**, como en prod: 56 platos y 11 ✓. El único ✗ es la impresora de la Cocina recién creada, que es lo esperado.
- **S2**, segunda corrida: no duplica nada.
- **S3**, rollback y re-import: el cóctel Brisa Tropical queda intacto.
- **S4**, con una venta: el rollback aborta.
- **S5**, con una COCINA `kitchen_hot` que ya tiene impresora: la usa y da 12/12.
- **S6**, con "Brisa Tropical" a secas: aborta sin tocar nada.
- **S7**, con la cocina apagada: no asigna área.
- **S8**, con un "SALMON AL GRILL" previo sin categoría: lo actualiza.
