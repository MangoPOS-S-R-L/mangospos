#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Genera el import de catalogo de BARRA PAYAN (business e0aef218).

Fuente: dos fotos del menu impreso (2026-09-07). No hay CSV ni export.

DECISIONES tomadas con el dueño el 2026-09-07:
  1. IMPUESTOS: "impuestos incluidos" -> tax_mode='inclusive' + vinculo a
     ITBIS 18%. El $450 del Club YA contiene el ITBIS; el cliente paga $450.
     Sin el vinculo en menu_item_taxes el POS facturaria ITBIS 0 (esa tabla
     es la UNICA fuente del impuesto por producto desde el PRD 2.5).
     La Ley 10% NO se vincula: no la cobran.
  2. JUGOS: las columnas NAT/CA del menu son Natural (en agua) y Con Leche.
     Cada sabor entra como DOS productos con sufijo, porque la diferencia de
     precio no es fija ($25 en unos, $50 en otros) y un modificador unico no
     la puede representar.
  3. ADICIONALES: van como grupo de modificadores enganchado a los 10
     sandwiches, no como productos sueltos.
  4. AREAS: SANDWICHERA (comida) y JUGUERA (bebida), que ya existen creadas
     en el negocio.

Uso: python3 scripts/build_import_e0aef218.py
"""
import os

BID = "e0aef218-ab95-4ba4-b8ef-036fab1c07c7"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "import_e0aef218")
STG = "public._import_e0aef218"

# ---------------------------------------------------------------------------
# Catalogo transcrito de las fotos.
# `ok=False` marca el precio que NO se leyo con certeza (la columna de OTRAS
# BEBIDAS esta tachada/desgastada en la foto). Se listan aparte para confirmar.
# ---------------------------------------------------------------------------

SANDWICHES = [
    ("Club Sándwich", 450, "Pollo o pierna de cerdo, jamón, queso derretido cheddar o gouda, tomate y salsas."),
    ("Payán Especial", 310, "Pollo o pierna de cerdo, jamón, queso cheddar, queso danés, tomate y salsas."),
    ("Sándwich Completo", 295, "Pollo, pierna de cerdo, jamón y queso, acompañados de rodajas de tomate fresco y salsas."),
    ("Sándwich de Pierna", 295, "Pierna de cerdo asada, queso (cheddar, danés, gouda o mozzarella), tomate y salsas."),
    ("Sándwich de Pollo", 295, "Pollo asado, queso (cheddar, danés, gouda o mozzarella), tomate y salsas."),
    ("Juancito Caminador", 250, "Queso cheddar, huevo, lechuga, tomate, cebolla y salsas."),
    ("Sándwich de Jamón y Queso", 250, "Jamón de pierna, queso danés o cheddar y salsas."),
    ("Sándwich de Huevo y Queso", 250, "Huevo, queso derretido (cheddar, danés o mozzarella), cebolla, tomate y salsas."),
    ("Sándwich de Salami y Queso", 250, "Salami, queso (cheddar, danés o mozzarella), cebolla, tomate y salsas."),
    ("Derretido de Queso", 250, "2 quesos, 3 quesos y 4 quesos."),
]

OTROS = [
    ("Tostada Especial", 200, None),
    ("Tostada", 50, None),
    ("Tostada de Ajo", 60, None),
    ("Servicio de Papas", 120, None),
]

# sabor -> (precio natural, precio con leche)
JUGOS = [
    ("Limón", 150, 175), ("Chinola", 175, 225), ("Tamarindo", 125, 175),
    ("Cereza", 125, 175), ("Piña", 125, 175), ("Melón", 125, 175),
    ("Guineo", 125, 175), ("Fresa", 175, 225), ("Granadillo", 175, 225),
    ("Lechoza", 125, 175), ("Zapote", 125, 175), ("China", 175, 225),
    ("Mango", 175, 225), ("Pitahaya", 175, 225),
]

# nombre, precio, leido_con_certeza
BEBIDAS = [
    ("Agua", 175, False),
    ("Refresco", 175, True),
    ("Leche", 145, False),
    ("Café con Leche", 175, True),
    ("Capuccino Italiano", 175, True),
    ("Capuccino Caramelo", 225, True),
    ("Capuccino Suizo", 225, True),
    ("Mocachino", 175, True),
    ("Chocolate", 175, False),
    ("Café Dominicano", 225, False),
    ("Cortadito", 225, False),
    ("Expreso", 225, False),
]

ADICIONALES = [
    ("Queso cheddar o danés", 95),
    ("Pollo o Pierna", 100),
    ("Jamón", 75),
    ("Salami", 55),
    ("Huevo", 30),
]

CATEGORIAS = [("Sándwiches", 0), ("Otros", 1), ("Jugos", 2), ("Bebidas", 3)]

# categoria -> nombre del area de comanda (tal como aparece en la app)
AREA_DE = {
    "Sándwiches": "SANDWICHERA",
    "Otros": "SANDWICHERA",
    "Jugos": "JUGUERA",
    "Bebidas": "JUGUERA",
}


def q(s):
    return "null" if s is None else "'" + str(s).replace("'", "''") + "'"


def build_rows():
    """Devuelve (categoria, nombre, precio, descripcion, is_beverage, pos, dudoso)."""
    rows, pos = [], 0
    for name, price, descr in SANDWICHES:
        rows.append(("Sándwiches", name, price, descr, False, pos, False)); pos += 1
    for name, price, descr in OTROS:
        rows.append(("Otros", name, price, descr, False, pos, False)); pos += 1
    for sabor, nat, leche in JUGOS:
        rows.append(("Jugos", "Jugo de %s (Natural)" % sabor, nat, None, True, pos, False)); pos += 1
        rows.append(("Jugos", "Jugo de %s (Con Leche)" % sabor, leche, None, True, pos, False)); pos += 1
    for name, price, ok in BEBIDAS:
        rows.append(("Bebidas", name, price, None, True, pos, not ok)); pos += 1
    return rows


def main():
    os.makedirs(OUT, exist_ok=True)
    rows = build_rows()
    dudosos = [r for r in rows if r[6]]

    vals = ",\n  ".join(
        "(%s, %s, %s, %s, %s, %d, %s)" % (
            q(cat), q(name), ("%.2f" % price), q(descr),
            "true" if bev else "false", pos, q(AREA_DE[cat]))
        for cat, name, price, descr, bev, pos, _ in rows
    )

    nombres = ",\n    ".join("(%s)" % q(r[1]) for r in rows)
    sandwiches = ",\n    ".join("(%s)" % q(n) for n, _, _ in SANDWICHES)
    mods = ",\n    ".join(
        "(%s, %6.2f, %d)" % (q(n), d, i) for i, (n, d) in enumerate(ADICIONALES))
    cats = ",\n  ".join("(%s, %d)" % (q(n), p) for n, p in CATEGORIAS)

    ctx = {"bid": BID, "vals": vals, "n": len(rows), "nombres": nombres,
           "sandwiches": sandwiches, "mods": mods, "cats": cats,
           "n_sand": len(SANDWICHES), "n_mods": len(ADICIONALES),
           "n_cats": len(CATEGORIAS),
           "n_sandwichera": sum(1 for r in rows if r[6 - 6] and AREA_DE[r[0]] == "SANDWICHERA"),
           "n_juguera": sum(1 for r in rows if AREA_DE[r[0]] == "JUGUERA")}
    ctx["n_sandwichera"] = sum(1 for r in rows if AREA_DE[r[0]] == "SANDWICHERA")

    with open(os.path.join(OUT, "IMPORT_COMPLETO.sql"), "w", encoding="utf-8") as f:
        f.write(FULL_TPL % ctx)

    with open(os.path.join(OUT, "99_rollback.sql"), "w", encoding="utf-8") as f:
        f.write(ROLLBACK_TPL % ctx)

    print("IMPORT_COMPLETO.sql: %d productos (%d dudosos)" % (len(rows), len(dudosos)))
    for r in dudosos:
        print("  ? %-22s %s" % (r[1], r[2]))
    from collections import Counter
    for cat, n in Counter(r[0] for r in rows).items():
        print("  %-12s %3d  -> %s" % (cat, n, AREA_DE[cat]))


STAGING_TPL = """-- ============================================================================
-- Import de catálogo — BARRA PAYÁN
-- Business %(bid)s
-- Fuente: fotos del menú impreso (2026-09-07). Generado por
--         scripts/build_import_e0aef218.py — no editar a mano.
-- ============================================================================
--
-- PASO 1 — Tabla de staging con los %(n)d productos.
--   No toca nada del catálogo real. Se borra en el paso 05.
-- ============================================================================

begin;

drop table if exists %(stg)s;

create table %(stg)s (
  categoria  text not null,
  name       text not null,
  price      numeric(12,2) not null,
  descr      text,
  is_bev     boolean not null,
  posicion   int not null,
  area       text not null
);

insert into %(stg)s (categoria, name, price, descr, is_bev, posicion, area) values
  %(vals)s;

commit;

-- ============================================================================
-- VERIFICACIÓN — esperado: %(n)d filas, 0 nombres repetidos.
-- ============================================================================

select count(*) as filas from %(stg)s;

select categoria, area, count(*) as productos
from %(stg)s group by categoria, area order by min(posicion);

-- Debe dar 0 filas.
select lower(name) as nombre, count(*)
from %(stg)s group by lower(name) having count(*) > 1;
"""


if __name__ == "__main__":
    main()
