#!/usr/bin/env python3
"""
Genera el SQL de carga de productos para el negocio 35c5076a-...
- Solo productos vendibles (precio1 no nulo)
- Crea categorias a partir del 'departamento' (quita prefijo "(NN)")
- Mapea: descripcion->name, precio1->price, costo->cost, codigo->sku,
  barcode = codigo si es numerico de 12-14 digitos (EAN/UPC/GTIN)
- Impuestos ITBIS 18% + LEY 10%, ambos INCLUSIVOS, a cada producto
- Idempotente: re-ejecutable sin duplicar (guardas NOT EXISTS / ON CONFLICT)

Uso:
  python3 scripts/build_products_import_35c5076a.py "/ruta/productos (1).json" \
      > scripts/import_products_35c5076a.sql
"""
import json, re, sys

BID = "35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6"

def q(s):
    """Escapa un texto para literal SQL (o NULL)."""
    if s is None:
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"

def num(x):
    if x is None:
        return "NULL"
    return repr(float(x))

def cat_name(dept):
    """(02) CERVEZAS -> CERVEZAS ; () -> None ; (21) -> None"""
    if not dept:
        return None
    m = re.match(r"^\(\d*\)\s*(.*)$", dept.strip())
    name = (m.group(1) if m else dept).strip()
    return name or None

def barcode_of(codigo):
    c = (codigo or "").strip()
    return c if re.fullmatch(r"\d{12,14}", c) else None

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else \
        "/Users/cristiangomez/Downloads/productos (1).json"
    data = json.load(open(path, encoding="utf-8"))

    # Solo vendibles
    rows = [d for d in data if d.get("precio1") is not None]

    # Categorias distintas (orden alfabetico, posicion estable)
    cats = sorted({c for c in (cat_name(d.get("departamento")) for d in rows) if c})

    out = []
    w = out.append
    w("-- ============================================================")
    w(f"-- Carga de productos -> negocio {BID}")
    w(f"-- {len(rows)} productos vendibles | {len(cats)} categorias")
    w("-- Impuestos: ITBIS 18% + LEY 10% (ambos INCLUSIVOS) por producto")
    w("-- Idempotente: puede re-ejecutarse sin duplicar.")
    w("-- Correr en Supabase Studio (SQL Editor) o psql.")
    w("-- ============================================================")
    w("begin;")
    w("")
    w("-- Salvaguarda: el negocio debe tener EXACTAMENTE los 2 impuestos esperados.")
    w("do $$")
    w("declare n int;")
    w("begin")
    w(f"  select count(*) into n from public.taxes")
    w(f"   where business_id = '{BID}' and name in ('ITBIS','LEY')")
    w("     and coalesce(is_active,true);")
    w("  if n <> 2 then")
    w("    raise exception 'Se esperaban 2 impuestos activos (ITBIS, LEY), hay %', n;")
    w("  end if;")
    w("end $$;")
    w("")

    # 1) Categorias
    w("-- 1) Categorias (crea solo las que falten)")
    w("insert into public.categories (id, business_id, name, position, is_active)")
    w("select gen_random_uuid(), '%s'::uuid, v.name, v.pos, true" % BID)
    w("from (values")
    cat_vals = ",\n".join(
        "  (%s, %d)" % (q(c), i) for i, c in enumerate(cats, start=1)
    )
    w(cat_vals)
    w(") as v(name, pos)")
    w("where not exists (")
    w("  select 1 from public.categories c")
    w("  where c.business_id = '%s'::uuid and c.name = v.name" % BID)
    w(");")
    w("")

    # 2) Staging
    w("-- 2) Staging de productos")
    w("create temp table _stage (")
    w("  codigo text, name text, price numeric, cost numeric,")
    w("  dept text, barcode text")
    w(") on commit drop;")
    w("")
    w("insert into _stage (codigo, name, price, cost, dept, barcode) values")
    vals = []
    for d in rows:
        vals.append("  (%s, %s, %s, %s, %s, %s)" % (
            q(d.get("codigo")),
            q((d.get("descripcion") or "").strip()),
            num(d.get("precio1")),
            num(d.get("costo")),
            q(cat_name(d.get("departamento"))),
            q(barcode_of(d.get("codigo"))),
        ))
    w(",\n".join(vals) + ";")
    w("")

    # 3) Actualizar existentes (match por sku) -> precio, costo, categoria, inclusivo
    w("-- 3) UPSERT: actualizar productos que YA existen (match por sku)")
    w("--    Sobrescribe nombre, precio, costo, categoria y barcode con el archivo,")
    w("--    y los deja en tax_mode = 'inclusive'.")
    w("update public.menu_items mi")
    w("set name        = s.name,")
    w("    price       = s.price,")
    w("    cost        = s.cost,")
    w("    barcode     = s.barcode,")
    w("    category_id = c.id,")
    w("    tax_mode    = 'inclusive',")
    w("    updated_at  = now()")
    w("from _stage s")
    w("left join public.categories c")
    w("  on c.business_id = '%s'::uuid and c.name = s.dept" % BID)
    w("where mi.business_id = '%s'::uuid" % BID)
    w("  and mi.sku = s.codigo;")
    w("")

    # 4) Insertar los que no existen
    w("-- 4) Insertar productos nuevos (sku que aun no existe)")
    w("insert into public.menu_items")
    w("  (business_id, category_id, name, price, cost, tax_mode, sku, barcode, is_active)")
    w("select '%s'::uuid, c.id, s.name, s.price, s.cost, 'inclusive'," % BID)
    w("       s.codigo, s.barcode, true")
    w("from _stage s")
    w("left join public.categories c")
    w("  on c.business_id = '%s'::uuid and c.name = s.dept" % BID)
    w("where not exists (")
    w("  select 1 from public.menu_items mi")
    w("  where mi.business_id = '%s'::uuid and mi.sku = s.codigo" % BID)
    w(");")
    w("")

    # 5) Poner TODO el catalogo del negocio en inclusive
    w("-- 5) Asegurar que TODO el catalogo del negocio quede inclusive")
    w("--    (incluye productos que no venian en el archivo)")
    w("update public.menu_items")
    w("set tax_mode = 'inclusive', updated_at = now()")
    w("where business_id = '%s'::uuid" % BID)
    w("  and tax_mode is distinct from 'inclusive';")
    w("")

    # 6) Enlazar ambos impuestos a TODOS los productos del stage (idempotente)
    w("-- 6) Enlazar ITBIS + LEY (inclusivos) a cada producto del archivo")
    w("insert into public.menu_item_taxes (item_id, tax_id)")
    w("select mi.id, t.id")
    w("from public.menu_items mi")
    w("join _stage s on s.codigo = mi.sku")
    w("join public.taxes t")
    w("  on t.business_id = mi.business_id and t.name in ('ITBIS','LEY')")
    w("where mi.business_id = '%s'::uuid" % BID)
    w("on conflict do nothing;")
    w("")

    # 7) Menu "MENU PRINCIPAL" (crea si no existe)
    w("-- 7) Menu 'MENU PRINCIPAL' (crea si no existe)")
    w("insert into public.menus (id, business_id, name, is_active)")
    w("select gen_random_uuid(), '%s'::uuid, 'MENU PRINCIPAL', true" % BID)
    w("where not exists (")
    w("  select 1 from public.menus m")
    w("  where m.business_id = '%s'::uuid and m.name = 'MENU PRINCIPAL'" % BID)
    w(");")
    w("")

    # 8) Vincular TODOS los productos del negocio al MENU PRINCIPAL
    w("-- 8) Vincular TODO el catalogo del negocio al MENU PRINCIPAL")
    w("insert into public.menu_item_links (menu_id, item_id, position)")
    w("select m.id, mi.id,")
    w("       row_number() over (order by mi.category_id nulls last, mi.name)")
    w("from public.menu_items mi")
    w("join public.menus m")
    w("  on m.business_id = mi.business_id and m.name = 'MENU PRINCIPAL'")
    w("where mi.business_id = '%s'::uuid" % BID)
    w("on conflict do nothing;")
    w("")

    # 9) Resumen
    w("-- 9) Resumen de control")
    w("select")
    w("  (select count(*) from public.menu_items")
    w("     where business_id = '%s'::uuid) as total_items," % BID)
    w("  (select count(*) from public.menu_items")
    w("     where business_id = '%s'::uuid and tax_mode <> 'inclusive') as no_inclusive," % BID)
    w("  (select count(*) from public.menu_item_taxes mit")
    w("     join public.menu_items mi on mi.id = mit.item_id")
    w("     where mi.business_id = '%s'::uuid) as total_links_impuesto," % BID)
    w("  (select count(*) from public.categories")
    w("     where business_id = '%s'::uuid) as total_categorias," % BID)
    w("  (select count(*) from public.menu_item_links mil")
    w("     join public.menus m on m.id = mil.menu_id")
    w("     where m.business_id = '%s'::uuid" % BID)
    w("       and m.name = 'MENU PRINCIPAL') as items_en_menu_principal;")
    w("")
    w("commit;")

    sys.stdout.write("\n".join(out) + "\n")

if __name__ == "__main__":
    main()
