#!/usr/bin/env python3
"""Genera un seed SQL de catálogo (categorías + menu_items) a partir de la
plantilla_importador_productos_lleno.json para un business dado.

Mapeo:
  name                 <- PRODUCTO
  price                <- PRECIO
  cost                 <- NULL  (COSTO viene 0 en toda la plantilla)
  sku                  <- CODIGO INTERNO
  barcode              <- "CODIGO DE BARRAS " (NULL si vacío)
  category_id          <- SUB CATEGORIA #1  (categorías planas)
  print_area_code      <- AREA DE PRODUCCIÓN: Bar->bar, Cocina->cocina
  is_inventory_tracked <- (TIENE CONTROL DE STOCK == SI)
  sold_by              <- 'unit'  (SE VENDE AL PESO == NO en toda la plantilla)
  tax_mode             <- 'exclusive'  (PRECIO es base sin ITBIS)
  is_beverage          <- CATEGORIA MADRE in (BEBIDAS, BAR)

NO mapeado (sin lugar en el modelo actual): SUB CATEGORIA #2, PROVEEDOR,
USAR PARA DELIVERY, marca/color/talla, código tributario.
"""
import json, sys, uuid

# Uso: gen_import_af2ec2e7.py [BUSINESS_ID] [SRC.json] [OUT.sql]
BUSINESS_ID = sys.argv[1] if len(sys.argv) > 1 else "af2ec2e7-2cdd-4583-bf5a-7e7476173b72"
NS = uuid.UUID(BUSINESS_ID)  # namespace estable = business (UUIDs deterministas por business)

SRC = sys.argv[2] if len(sys.argv) > 2 else "/Users/cristiangomez/Downloads/plantilla_importador_productos_lleno.json"
OUT = sys.argv[3] if len(sys.argv) > 3 else f"/Users/cristiangomez/dev/mangospos/supabase/import_{BUSINESS_ID[:8]}_products.sql"

K_AREA = "AREA DE PRODUCCIÓN"
K_BAR  = "CODIGO DE BARRAS "
K_STOCK = " TIENE CONTROL DE STOCK"

def q(s):  # string SQL o NULL
    if s is None:
        return "NULL"
    return "'" + str(s).replace("'", "''") + "'"

def num(x):
    return f"{float(x):.2f}"

data = json.load(open(SRC))

# --- categorías (SUB CATEGORIA #1) en orden de aparición ---
cats = {}          # nombre -> (uuid, position)
for r in data:
    name = (r.get("SUB CATEGORIA #1") or "").strip()
    if name and name not in cats:
        cid = str(uuid.uuid5(NS, "cat|" + name))
        cats[name] = (cid, len(cats))

# --- filas de menu_items ---
rows = []
pos_by_cat = {}
for i, r in enumerate(data):
    name = (r.get("PRODUCTO") or "").strip()
    if not name:
        continue
    sub = (r.get("SUB CATEGORIA #1") or "").strip()
    cid = cats[sub][0] if sub in cats else None
    madre = (r.get("CATEGORIA MADRE") or "").strip().upper()
    sku = (r.get("CODIGO INTERNO") or "").strip() or None
    bar = (r.get(K_BAR) or "").strip() or None
    price = r.get("PRECIO") or 0
    area = (r.get(K_AREA) or "").strip().lower()
    print_area = "bar" if area == "bar" else ("cocina" if area == "cocina" else None)
    tracked = (r.get(K_STOCK) or "").strip().upper() == "SI"
    beverage = madre in ("BEBIDAS", "BAR")
    pos = pos_by_cat.get(sub, 0); pos_by_cat[sub] = pos + 1
    pid = str(uuid.uuid5(NS, f"item|{i}|{sku}|{name}"))
    rows.append(
        f"  ({q(pid)}, '{BUSINESS_ID}', {q(cid) if cid else 'NULL'}, {q(name)}, {num(price)}, "
        f"{q(sku)}, true, NULL, 0, false, false, false, {str(beverage).lower()}, 'unspecified', "
        f"'unit', NULL, 'exclusive', 'standard', {q(print_area)}, {str(tracked).lower()}, "
        f"false, false, {q(bar)}, {pos}, NOW(), NOW())"
    )

with open(OUT, "w") as f:
    w = f.write
    w("-- =====================================================================\n")
    w(f"-- Importacion de catalogo (plantilla importador de productos)\n")
    w(f"-- Business ID: {BUSINESS_ID}\n")
    w(f"-- Productos: {len(rows)}  |  Categorias: {len(cats)}\n")
    w("-- tax_mode = 'exclusive' (PRECIO es base sin ITBIS)\n")
    w("-- cost NULL (COSTO 0 en la plantilla); sold_by 'unit'; area Bar->bar / Cocina->cocina\n")
    w("-- NO incluye: subcategoria #2, proveedor, delivery, marca/color/talla, codigo tributario\n")
    w("-- =====================================================================\n\n")
    w("BEGIN;\n\n")
    w("-- ============== 1. CATEGORIAS ==============\n")
    w("INSERT INTO categories (id, business_id, name, position, is_active, created_at) VALUES\n")
    cat_vals = [
        f"  ('{cid}', '{BUSINESS_ID}', {q(nm)}, {pos}, true, NOW())"
        for nm, (cid, pos) in cats.items()
    ]
    w(",\n".join(cat_vals) + ";\n\n")
    w("-- ============== 2. PRODUCTOS ==============\n")
    w("INSERT INTO menu_items (\n")
    w("  id, business_id, category_id, name, price, sku, is_active, description,\n")
    w("  prep_minutes, has_variants, has_prep, contains_egg, is_beverage, dietary,\n")
    w("  sold_by, cost, tax_mode, item_type, print_area_code, is_inventory_tracked,\n")
    w("  auto_disabled, allow_negative_sale, barcode, position, created_at, updated_at\n")
    w(") VALUES\n")
    w(",\n".join(rows) + ";\n\n")
    w("COMMIT;\n\n")
    w("-- Verificacion:\n")
    w(f"-- SELECT COUNT(*) FROM categories WHERE business_id = '{BUSINESS_ID}';  -- esperado: {len(cats)}\n")
    w(f"-- SELECT COUNT(*) FROM menu_items WHERE business_id = '{BUSINESS_ID}';  -- esperado: {len(rows)}\n")

print(f"OK -> {OUT}")
print(f"categorias: {len(cats)} | productos: {len(rows)}")
