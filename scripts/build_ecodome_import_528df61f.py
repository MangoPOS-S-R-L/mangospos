#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Genera los SQL de carga de catalogo de ECODOME VILLAGE para el negocio 528df61f.

Entrada : export de Loyverse (`export_items.csv`), 42 productos.
          Columnas que usa: SKU, Name, Category, Cost, Price [EcoDome Village].
Salidas : scripts/IMPORT_ecodome_528df61f.sql
          scripts/AREAS_ecodome_528df61f.sql
          scripts/ROLLBACK_ecodome_528df61f.sql

Decisiones tomadas con el dueno (2026-09-05):
  - SIN IMPUESTOS. No se escribe nada en menu_item_taxes. Los precios del
    archivo son FINALES y redondos (50, 250, 1200), asi que el cliente paga
    exactamente lo que dice el menu.
  - Los 7 productos que Loyverse trae sin categoria: los 4 tragos van a una
    categoria nueva `Cocteles`, los 3 Smirnoff a `Cerveza`.
  - `Plato del dia - Nino` trae el precio literal "variable": entra en 0.00
    pero DESACTIVADO, para que nadie lo despache gratis.
  - Las existencias de Loyverse (11 productos) NO se suben. Inventario es otro
    modulo y va aparte, con conteo fisico.
  - cost = NULL: el archivo trae 0.00 en los 42, que no es "cuesta cero".

Uso:
  python3 scripts/build_ecodome_import_528df61f.py "~/Downloads/export_items (2).csv"
"""
import csv, sys, os, unicodedata

BID = "528df61f-7136-4591-9e87-ee19f5882037"
MENU_NAME = "MENU PRINCIPAL"
PRICE_COL = "Price [EcoDome Village]"

HERE = os.path.dirname(os.path.abspath(__file__))

# Categoria destino para los que Loyverse trae vacios (sku -> categoria).
NO_CAT = {
    "10003": "Cócteles",   # Margarita
    "10004": "Cócteles",   # Mojito
    "10001": "Cócteles",   # Pina Colada
    "10012": "Cócteles",   # Sangria Roja
    "10039": "Cerveza",    # Smirnoff Green Apple
    "10040": "Cerveza",    # Smirnoff Original
    "10010": "Cerveza",    # Smirnoff Raspberry
}

# Ruteo de area por categoria. 'K' = cocina, 'B' = barra.
KITCHEN_CATS = {"Comida"}

# El nombre normalizado para el match anti-duplicados. Mismo que el import
# anterior: mayusculas, sin acentos, espacios colapsados.
NORM = ("upper(btrim(regexp_replace("
        "translate(%s, 'ÁÉÍÓÚÜÑÀÈÌÒÙÂÊÎÔÛáéíóúüñàèìòùâêîôû', "
        "'AEIOUUNAEIOUAEIOUaeiouunaeiouaeiou'), '\\s+', ' ', 'g')))")


def q(s):
    if s is None or s == "":
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"


def num(x):
    return "NULL" if x is None else ("%.2f" % float(x))


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "~/Downloads/export_items (2).csv"
    src = os.path.expanduser(src)
    with open(src, encoding="utf-8-sig", newline="") as fh:
        rows = list(csv.DictReader(fh))

    items = []
    for r in rows:
        sku = (r["SKU"] or "").strip()
        # NFC: Loyverse exporta algunos nombres descompuestos (n + tilde
        # combinante). Sin normalizar, 'Pina Colada' y 'Pina Colada' son dos
        # cadenas distintas para Postgres y el match por nombre falla.
        name = unicodedata.normalize("NFC", (r["Name"] or "").strip())
        cat = unicodedata.normalize("NFC", (r["Category"] or "").strip())
        if not sku or not name:
            continue
        if not cat:
            cat = NO_CAT.get(sku)
            if not cat:
                raise SystemExit("sku %r (%s) sin categoria y sin destino" % (sku, name))

        raw_price = (r[PRICE_COL] or "").strip()
        try:
            price = float(raw_price)
            active = True
        except ValueError:
            # "variable" -> entra en 0 pero apagado.
            price = 0.0
            active = False

        cost = float(r["Cost"] or 0)
        items.append({
            "sku": sku,
            "name": name,
            "cat": cat,
            "price": price,
            "cost": cost if cost > 0 else None,
            "active": active,
            "area": "K" if cat in KITCHEN_CATS else "B",
        })

    if len({i["sku"] for i in items}) != len(items):
        raise SystemExit("hay SKUs duplicados en el archivo")

    cats = sorted({i["cat"] for i in items})
    n_kit = sum(1 for i in items if i["area"] == "K")
    n_bar = sum(1 for i in items if i["area"] == "B")

    _write_import(items, cats, src)
    _write_areas(items, n_kit, n_bar)
    _write_rollback(items)

    print("productos   : %d" % len(items), file=sys.stderr)
    print("categorias  : %d  (%s)" % (len(cats), ", ".join(cats)), file=sys.stderr)
    print("cocina %d | barra %d" % (n_kit, n_bar), file=sys.stderr)
    print("desactivados: %d" % sum(1 for i in items if not i["active"]), file=sys.stderr)


# ─────────────────────────────────────────────────────────────────────────────
def _stage_block(w, items):
    w("create temp table _stage (")
    w("  sku text primary key, name text, cat text,")
    w("  price numeric, cost numeric, active boolean")
    w(") on commit drop;")
    w("")
    w("insert into _stage (sku, name, cat, price, cost, active) values")
    w(",\n".join(
        "  (%s, %s, %s, %s, %s, %s)" % (
            q(i["sku"]), q(i["name"]), q(i["cat"]),
            num(i["price"]), num(i["cost"]),
            "true" if i["active"] else "false")
        for i in items) + ";")


def _write_import(items, cats, src):
    o = []
    w = o.append
    w("-- =============================================================================")
    w("-- Carga de catalogo ECODOME VILLAGE — Business %s" % BID)
    w("--")
    w("-- Origen : %s  (export de Loyverse)" % os.path.basename(src))
    w("-- Genera : scripts/build_ecodome_import_528df61f.py  (NO editar a mano)")
    w("--")
    w("--   %d productos | %d categorias" % (len(items), len(cats)))
    w("--")
    w("-- SIN IMPUESTOS: no se escribe una sola fila en menu_item_taxes. Esa tabla")
    w("-- es la UNICA fuente del impuesto por producto, asi que la factura sale con")
    w("-- ITBIS 0.00 — decision del dueno, no un descuido. Los precios del archivo")
    w("-- son FINALES y redondos (50, 250, 1200): el cliente paga lo que dice el")
    w("-- menu, no hay nada que sumar ni que sacar.")
    w("--")
    w("-- DECISIONES QUE NO SALEN DEL ARCHIVO:")
    w("--   * 7 productos venian SIN categoria en Loyverse. Los 4 tragos")
    w("--     (Margarita, Mojito, Pina Colada, Sangria Roja) van a `Cocteles`,")
    w("--     categoria NUEVA; los 3 Smirnoff van a la `Cerveza` que ya existe.")
    w("--   * `Plato del dia - Nino` (sku 10028) traia el precio literal")
    w("--     \"variable\". Entra en 0.00 pero con is_active = FALSE, para que nadie")
    w("--     lo despache gratis. Ponle precio en la app y actualo.")
    w("--   * Las existencias de Loyverse (11 productos) NO se cargan aqui.")
    w("--   * cost queda NULL: el archivo trae 0.00 en los 42, y 0 se leeria como")
    w("--     \"cuesta cero\" dando 100%% de margen en los reportes.")
    w("--")
    w("-- ANTI-DUPLICADOS: el match es por NOMBRE normalizado (mayusculas, sin")
    w("-- acentos, espacios colapsados), no por sku — un producto creado a mano en")
    w("-- la app no tiene sku y se duplicaria. Tres reglas:")
    w("--   A. Nombre unico en el archivo Y unico en el catalogo -> ACTUALIZA + sku.")
    w("--   B. Nombre que no existe en el catalogo               -> INSERTA.")
    w("--   C. Nombre ambiguo                                    -> NO SE TOCA.")
    w("-- Con el catalogo vacio todo cae en la regla B y entra limpio.")
    w("--")
    w("-- IDEMPOTENTE: re-ejecutarlo no duplica. Todo en UNA transaccion.")
    w("--")
    w("-- DESPUES corre scripts/AREAS_ecodome_528df61f.sql, si no los productos")
    w("-- quedan sin area y \"Enviar a cocina\" se bloquea sin decir por que.")
    w("--")
    w("-- Correr en Supabase Studio -> SQL Editor.")
    w("-- =============================================================================")
    w("")
    w("begin;")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 0) El negocio tiene que existir")
    w("-- ---------------------------------------------------------------------------")
    w("do $$")
    w("declare")
    w("  v_business uuid := '%s';" % BID)
    w("begin")
    w("  if not exists (select 1 from public.businesses b where b.id = v_business) then")
    w("    raise exception 'El negocio % no existe', v_business;")
    w("  end if;")
    w("end $$;")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 1) Categorias (crea solo las que falten; respeta las que ya esten)")
    w("-- ---------------------------------------------------------------------------")
    w("insert into public.categories (id, business_id, name, position, is_active)")
    w("select gen_random_uuid(), '%s'::uuid, v.name, v.pos, true" % BID)
    w("from (values")
    w(",\n".join("  (%s, %d)" % (q(c), i) for i, c in enumerate(cats, start=1)))
    w(") as v(name, pos)")
    w("where not exists (")
    w("  select 1 from public.categories c")
    w("  where c.business_id = '%s'::uuid and c.name = v.name" % BID)
    w(");")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 2) El archivo")
    w("-- ---------------------------------------------------------------------------")
    _stage_block(w, items)
    w("")
    w("create temp table _arch on commit drop as")
    w("select s.*, %s as k from _stage s;" % (NORM % "s.name"))
    w("create index on _arch (k);")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 3) El catalogo actual, con la misma clave")
    w("-- ---------------------------------------------------------------------------")
    w("create temp table _actual on commit drop as")
    w("select mi.id, mi.name, mi.sku, %s as k" % (NORM % "mi.name"))
    w("from public.menu_items mi")
    w("where mi.business_id = '%s'::uuid;" % BID)
    w("create index on _actual (k);")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 4) Regla A — emparejamiento 1:1 sin ambiguedad")
    w("-- ---------------------------------------------------------------------------")
    w("create temp table _match on commit drop as")
    w("select a.sku, x.id as item_id")
    w("from _arch a")
    w("join _actual x on x.k = a.k")
    w("where (select count(*) from _arch   a2 where a2.k = a.k) = 1")
    w("  and (select count(*) from _actual x2 where x2.k = a.k) = 1;")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 5) ACTUALIZA los emparejados y les graba el sku")
    w("-- ---------------------------------------------------------------------------")
    w("update public.menu_items mi")
    w("set sku         = s.sku,")
    w("    name        = s.name,")
    w("    price       = s.price,")
    w("    cost        = s.cost,")
    w("    category_id = c.id,")
    w("    tax_mode    = 'exclusive',")
    w("    is_active   = s.active,")
    w("    updated_at  = now()")
    w("from _match m")
    w("join _stage s on s.sku = m.sku")
    w("left join lateral (")
    w("  select c2.id from public.categories c2")
    w("  where c2.business_id = '%s'::uuid and c2.name = s.cat" % BID)
    w("  order by c2.created_at asc limit 1")
    w(") c on true")
    w("where mi.id = m.item_id;")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 6) Regla B — INSERTA solo los nombres que NO existen. Este `not exists`")
    w("--    es el candado anti-duplicados.")
    w("-- ---------------------------------------------------------------------------")
    w("insert into public.menu_items")
    w("  (business_id, category_id, name, price, cost, tax_mode, sku, is_active)")
    w("select '%s'::uuid, c.id, a.name, a.price, a.cost, 'exclusive', a.sku, a.active" % BID)
    w("from _arch a")
    w("left join lateral (")
    w("  select c2.id from public.categories c2")
    w("  where c2.business_id = '%s'::uuid and c2.name = a.cat" % BID)
    w("  order by c2.created_at asc limit 1")
    w(") c on true")
    w("where not exists (select 1 from _actual x where x.k = a.k);")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 7) Menu: reusa el activo que tenga el negocio; si no hay, crea uno.")
    w("--    Sin fila en menu_item_links el producto NO aparece en la caja.")
    w("-- ---------------------------------------------------------------------------")
    w("insert into public.menus (id, business_id, name, is_active)")
    w("select gen_random_uuid(), '%s'::uuid, %s, true" % (BID, q(MENU_NAME)))
    w("where not exists (")
    w("  select 1 from public.menus m")
    w("  where m.business_id = '%s'::uuid and coalesce(m.is_active, true)" % BID)
    w(");")
    w("")
    w("insert into public.menu_item_links (menu_id, item_id, position)")
    w("select m.id, mi.id,")
    w("       row_number() over (order by c.position nulls last, mi.name)")
    w("from public.menu_items mi")
    w("join _stage s on s.sku = mi.sku")
    w("left join public.categories c on c.id = mi.category_id")
    w("join lateral (")
    w("  select m2.id from public.menus m2")
    w("  where m2.business_id = mi.business_id and coalesce(m2.is_active, true)")
    w("  order by m2.created_at asc limit 1")
    w(") m on true")
    w("where mi.business_id = '%s'::uuid" % BID)
    w("  and not exists (")
    w("    select 1 from public.menu_item_links l")
    w("    where l.item_id = mi.id and l.menu_id = m.id")
    w("  );")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 8) Control.")
    w("--    en_archivo = %d. con_impuesto / sin_categoria / fuera_del_menu /" % len(items))
    w("--    no_exclusive deben dar 0. desactivados = 1 (el Plato del dia - Nino).")
    w("-- ---------------------------------------------------------------------------")
    w("select")
    w("  (select count(*) from _arch)  as en_archivo,")
    w("  (select count(*) from _match) as actualizados,")
    w("  (select count(*) from _arch a")
    w("    where not exists (select 1 from _actual x where x.k = a.k)) as insertados,")
    w("  (select count(*) from _arch a")
    w("    where not exists (select 1 from _match m where m.sku = a.sku)")
    w("      and exists (select 1 from _actual x where x.k = a.k)) as ambiguos_sin_tocar,")
    w("  (select count(*) from public.menu_items")
    w("    where business_id = '%s'::uuid) as total_catalogo," % BID)
    w("  (select count(*) from public.categories")
    w("    where business_id = '%s'::uuid) as categorias," % BID)
    w("  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku")
    w("    where mi.business_id = '%s'::uuid and mi.tax_mode <> 'exclusive') as no_exclusive," % BID)
    w("  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku")
    w("    where mi.business_id = '%s'::uuid" % BID)
    w("      and exists (select 1 from public.menu_item_taxes x where x.item_id = mi.id)")
    w("   ) as con_impuesto,")
    w("  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku")
    w("    where mi.business_id = '%s'::uuid and mi.category_id is null) as sin_categoria," % BID)
    w("  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku")
    w("    where mi.business_id = '%s'::uuid" % BID)
    w("      and not exists (select 1 from public.menu_item_links l where l.item_id = mi.id)")
    w("   ) as fuera_del_menu,")
    w("  (select count(*) from public.menu_items mi join _stage s on s.sku = mi.sku")
    w("    where mi.business_id = '%s'::uuid and not mi.is_active) as desactivados;" % BID)
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 9) El catalogo que queda, por categoria. Para leerlo de un vistazo.")
    w("-- ---------------------------------------------------------------------------")
    w("select coalesce(c.name, '(sin categoria)') as categoria,")
    w("       count(*) as productos,")
    w("       min(mi.price) as precio_min,")
    w("       max(mi.price) as precio_max,")
    w("       count(*) filter (where not mi.is_active) as inactivos")
    w("from public.menu_items mi")
    w("left join public.categories c on c.id = mi.category_id")
    w("where mi.business_id = '%s'::uuid" % BID)
    w("group by 1")
    w("order by 1;")
    w("")
    w("commit;")
    w("")
    _out("IMPORT_ecodome_528df61f.sql", o)


def _write_areas(items, n_kit, n_bar):
    o = []
    w = o.append
    w("-- =============================================================================")
    w("-- Areas de produccion ECODOME VILLAGE — Business %s" % BID)
    w("-- Correr DESPUES de scripts/IMPORT_ecodome_528df61f.sql")
    w("--")
    w("-- POR QUE HACE FALTA:")
    w("--   Un producto insertado por SQL queda con print_area_code = NULL. Sin")
    w("--   area, \"Enviar a cocina\" se bloquea y NO sale ninguna comanda — falla")
    w("--   callado hasta que alguien intenta imprimir.")
    w("--")
    w("-- >> ANTES DE CORRER: pon abajo los CODES reales de las areas del negocio.")
    w("--    Miralos con scripts/AREAS_diagnostico_528df61f.sql, o con:")
    w("--      select code, name, is_active from public.print_areas")
    w("--       where business_id = '%s';" % BID)
    w("--    Si un code no existe, el script aborta y te dice cuales hay.")
    w("--")
    w("-- REPARTO: cocina %d (todo lo de `Comida`) | barra %d (todo lo demas)." % (n_kit, n_bar))
    w("--   No hay combos de dos areas en este catalogo.")
    w("--")
    w("-- ESCRIBE LOS DOS MECANISMOS, A PROPOSITO:")
    w("--   1. menu_item_print_areas (N:M) — fuente de verdad.")
    w("--   2. menu_items.print_area_code (legacy) — NO es redundante:")
    w("--      fn_add_item_from_menu lo copia al order_item y se salta el lookup")
    w("--      N:M entero. Solo con N:M, un bache de red rutea mal.")
    w("--")
    w("-- CONVERGENTE: re-ejecutarlo deja el mismo estado.")
    w("-- =============================================================================")
    w("")
    w("begin;")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- >> 1) CODES DE LAS AREAS — AJUSTA ESTOS DOS VALORES")
    w("-- ---------------------------------------------------------------------------")
    w("create temp table _area_cfg (rol text primary key, code text) on commit drop;")
    w("insert into _area_cfg (rol, code) values")
    w("  ('K', 'cocina'),   -- area de COCINA")
    w("  ('B', 'bar');      -- area de BARRA")
    w("")
    w("do $$")
    w("declare")
    w("  v_business uuid := '%s';" % BID)
    w("  v_missing  text;")
    w("  v_have     text;")
    w("begin")
    w("  select string_agg(cfg.code, ', ')")
    w("    into v_missing")
    w("  from _area_cfg cfg")
    w("  where not exists (")
    w("    select 1 from public.print_areas a")
    w("    where a.business_id = v_business and a.code = cfg.code")
    w("      and coalesce(a.is_active, true)")
    w("  );")
    w("  if v_missing is not null then")
    w("    select string_agg(a.code || ' (' || a.name || ')', ', ' order by a.code)")
    w("      into v_have")
    w("    from public.print_areas a")
    w("    where a.business_id = v_business and coalesce(a.is_active, true);")
    w("    raise exception 'No existen estas areas: %. El negocio tiene: %', v_missing, coalesce(v_have, '(ninguna)');")
    w("  end if;")
    w("end $$;")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 2) Ruteo sku -> area")
    w("-- ---------------------------------------------------------------------------")
    w("create temp table _route (sku text primary key, areas text) on commit drop;")
    w("insert into _route (sku, areas) values")
    w(",\n".join("  (%s, '%s')" % (q(i["sku"]), i["area"]) for i in items) + ";")
    w("")
    w("create temp table _target on commit drop as")
    w("select mi.id as menu_item_id, a.id as print_area_id")
    w("from public.menu_items mi")
    w("join _route r on r.sku = mi.sku")
    w("join _area_cfg cfg on r.areas like '%' || cfg.rol || '%'")
    w("join lateral (")
    w("  select a2.id from public.print_areas a2")
    w("  where a2.business_id = mi.business_id and a2.code = cfg.code")
    w("    and coalesce(a2.is_active, true)")
    w("  order by a2.created_at asc limit 1")
    w(") a on true")
    w("where mi.business_id = '%s'::uuid;" % BID)
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 3) N:M — borra lo que sobra, inserta lo que falta")
    w("-- ---------------------------------------------------------------------------")
    w("delete from public.menu_item_print_areas mipa")
    w("using public.menu_items mi")
    w("join _route r on r.sku = mi.sku")
    w("where mipa.menu_item_id = mi.id")
    w("  and mi.business_id = '%s'::uuid" % BID)
    w("  and not exists (")
    w("    select 1 from _target t")
    w("    where t.menu_item_id = mipa.menu_item_id")
    w("      and t.print_area_id = mipa.print_area_id")
    w("  );")
    w("")
    w("insert into public.menu_item_print_areas (menu_item_id, print_area_id)")
    w("select t.menu_item_id, t.print_area_id from _target t")
    w("on conflict do nothing;")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 4) Legacy print_area_code + is_beverage (bebida = todo lo que va a barra)")
    w("-- ---------------------------------------------------------------------------")
    w("update public.menu_items mi")
    w("set print_area_code = cfg.code,")
    w("    is_beverage     = (r.areas = 'B'),")
    w("    updated_at      = now()")
    w("from _route r")
    w("join _area_cfg cfg")
    w("  on cfg.rol = case when r.areas like '%K%' then 'K' else 'B' end")
    w("where mi.sku = r.sku")
    w("  and mi.business_id = '%s'::uuid" % BID)
    w("  and (mi.print_area_code is distinct from cfg.code")
    w("       or mi.is_beverage is distinct from (r.areas = 'B'));")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- 5) Control. Esperado: sin_area_nm = 0, code_inexistente = 0,")
    w("--    catalogo_entero_sin_area = 0 (cuenta TODO el negocio, no solo el")
    w("--    archivo: si sale > 0 hay productos que no imprimen comanda).")
    w("-- ---------------------------------------------------------------------------")
    w("select")
    w("  (select count(*) from _route) as en_archivo,")
    w("  (select count(*) from public.menu_items mi join _route r on r.sku = mi.sku")
    w("    where mi.business_id = '%s'::uuid" % BID)
    w("      and not exists (select 1 from public.menu_item_print_areas p where p.menu_item_id = mi.id)")
    w("   ) as sin_area_nm,")
    w("  (select count(*) from public.menu_items mi")
    w("    where mi.business_id = '%s'::uuid" % BID)
    w("      and mi.print_area_code is not null")
    w("      and not exists (select 1 from public.print_areas a")
    w("                       where a.business_id = mi.business_id and a.code = mi.print_area_code)")
    w("   ) as code_inexistente,")
    w("  (select count(*) from public.menu_items mi")
    w("    where mi.business_id = '%s'::uuid" % BID)
    w("      and coalesce(mi.print_area_code, '') = ''")
    w("      and not exists (select 1 from public.menu_item_print_areas p where p.menu_item_id = mi.id)")
    w("   ) as catalogo_entero_sin_area;")
    w("")
    w("-- Reparto final, para leerlo de un vistazo.")
    w("select a.code as area, count(*) as productos")
    w("from public.menu_item_print_areas x")
    w("join public.print_areas a on a.id = x.print_area_id")
    w("join public.menu_items mi on mi.id = x.menu_item_id")
    w("where mi.business_id = '%s'::uuid" % BID)
    w("group by a.code order by a.code;")
    w("")
    w("commit;")
    w("")
    _out("AREAS_ecodome_528df61f.sql", o)


def _write_rollback(items):
    o = []
    w = o.append
    w("-- =============================================================================")
    w("-- ROLLBACK del import ECODOME — Business %s" % BID)
    w("--")
    w("-- Borra los %d productos que metio IMPORT_ecodome_528df61f.sql, y NADA mas:" % len(items))
    w("-- el filtro es la lista de sku del archivo.")
    w("--")
    w("-- Se van en cascada con el producto: menu_item_links, menu_item_print_areas,")
    w("-- menu_item_taxes, menu_item_groups, recipes.")
    w("--")
    w("-- LO QUE PUEDE BLOQUEAR — a proposito:")
    w("--   order_items.product_id -> ON DELETE RESTRICT. Si el producto YA SE")
    w("--   VENDIO, Postgres aborta todo. Un producto con historial no se borra, se")
    w("--   DESACTIVA. El paso 1 te avisa antes.")
    w("--")
    w("-- CORRER POR PARTES. El paso 1 no escribe nada.")
    w("-- =============================================================================")
    w("")
    w("")
    w("-- ###########################################################################")
    w("-- PASO 1 — QUE SE VA A BORRAR (no escribe nada)")
    w("-- ###########################################################################")
    w("begin;")
    w("create temp table _sku (sku text primary key) on commit drop;")
    w("insert into _sku (sku) values")
    w(",\n".join("  (%s)" % q(i["sku"]) for i in items) + ";")
    w("")
    w("select")
    w("  (select count(*) from public.menu_items mi")
    w("    where mi.business_id = '%s'::uuid) as productos_del_negocio," % BID)
    w("  (select count(*) from public.menu_items mi join _sku s on s.sku = mi.sku")
    w("    where mi.business_id = '%s'::uuid) as se_borrarian," % BID)
    w("  (select count(*) from public.order_items oi")
    w("     join public.menu_items mi on mi.id = oi.product_id")
    w("     join _sku s on s.sku = mi.sku")
    w("    where mi.business_id = '%s'::uuid) as lineas_de_venta_que_bloquean;" % BID)
    w("")
    w("select mi.sku, mi.name, count(*) as veces_vendido")
    w("from public.menu_items mi")
    w("join _sku s on s.sku = mi.sku")
    w("join public.order_items oi on oi.product_id = mi.id")
    w("where mi.business_id = '%s'::uuid" % BID)
    w("group by mi.sku, mi.name order by count(*) desc, mi.name;")
    w("commit;")
    w("")
    w("")
    w("-- ###########################################################################")
    w("-- PASO 2 — BORRAR. Solo si el paso 1 dio lineas_de_venta_que_bloquean = 0.")
    w("-- ###########################################################################")
    w("begin;")
    w("create temp table _sku (sku text primary key) on commit drop;")
    w("insert into _sku (sku) values")
    w(",\n".join("  (%s)" % q(i["sku"]) for i in items) + ";")
    w("")
    w("delete from public.menu_items mi")
    w("using _sku s")
    w("where mi.sku = s.sku")
    w("  and mi.business_id = '%s'::uuid;" % BID)
    w("")
    w("select count(*) as productos_restantes from public.menu_items")
    w(" where business_id = '%s'::uuid;" % BID)
    w("commit;")
    w("")
    _out("ROLLBACK_ecodome_528df61f.sql", o)


def _out(fname, lines):
    path = os.path.join(HERE, fname)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines))
    print("escrito: %s" % path, file=sys.stderr)


if __name__ == "__main__":
    main()
