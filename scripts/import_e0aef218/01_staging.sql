-- ============================================================================
-- Import de catálogo — BARRA PAYÁN
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
-- Fuente: fotos del menú impreso (2026-09-07). Generado por
--         scripts/build_import_e0aef218.py — no editar a mano.
-- ============================================================================
--
-- PASO 1 — Tabla de staging con los 54 productos.
--   No toca nada del catálogo real. Se borra en el paso 05.
-- ============================================================================

begin;

drop table if exists public._import_e0aef218;

create table public._import_e0aef218 (
  categoria  text not null,
  name       text not null,
  price      numeric(12,2) not null,
  descr      text,
  is_bev     boolean not null,
  posicion   int not null,
  area       text not null
);

insert into public._import_e0aef218 (categoria, name, price, descr, is_bev, posicion, area) values
  ('Sándwiches', 'Club Sándwich', 450.00, 'Pollo o pierna de cerdo, jamón, queso derretido cheddar o gouda, tomate y salsas.', false, 0, 'SANDWICHERA'),
  ('Sándwiches', 'Payán Especial', 310.00, 'Pollo o pierna de cerdo, jamón, queso cheddar, queso danés, tomate y salsas.', false, 1, 'SANDWICHERA'),
  ('Sándwiches', 'Sándwich Completo', 295.00, 'Pollo, pierna de cerdo, jamón y queso, acompañados de rodajas de tomate fresco y salsas.', false, 2, 'SANDWICHERA'),
  ('Sándwiches', 'Sándwich de Pierna', 295.00, 'Pierna de cerdo asada, queso (cheddar, danés, gouda o mozzarella), tomate y salsas.', false, 3, 'SANDWICHERA'),
  ('Sándwiches', 'Sándwich de Pollo', 295.00, 'Pollo asado, queso (cheddar, danés, gouda o mozzarella), tomate y salsas.', false, 4, 'SANDWICHERA'),
  ('Sándwiches', 'Juancito Caminador', 250.00, 'Queso cheddar, huevo, lechuga, tomate, cebolla y salsas.', false, 5, 'SANDWICHERA'),
  ('Sándwiches', 'Sándwich de Jamón y Queso', 250.00, 'Jamón de pierna, queso danés o cheddar y salsas.', false, 6, 'SANDWICHERA'),
  ('Sándwiches', 'Sándwich de Huevo y Queso', 250.00, 'Huevo, queso derretido (cheddar, danés o mozzarella), cebolla, tomate y salsas.', false, 7, 'SANDWICHERA'),
  ('Sándwiches', 'Sándwich de Salami y Queso', 250.00, 'Salami, queso (cheddar, danés o mozzarella), cebolla, tomate y salsas.', false, 8, 'SANDWICHERA'),
  ('Sándwiches', 'Derretido de Queso', 250.00, '2 quesos, 3 quesos y 4 quesos.', false, 9, 'SANDWICHERA'),
  ('Otros', 'Tostada Especial', 200.00, null, false, 10, 'SANDWICHERA'),
  ('Otros', 'Tostada', 50.00, null, false, 11, 'SANDWICHERA'),
  ('Otros', 'Tostada de Ajo', 60.00, null, false, 12, 'SANDWICHERA'),
  ('Otros', 'Servicio de Papas', 120.00, null, false, 13, 'SANDWICHERA'),
  ('Jugos', 'Jugo de Limón (Natural)', 150.00, null, true, 14, 'JUGUERA'),
  ('Jugos', 'Jugo de Limón (Con Leche)', 175.00, null, true, 15, 'JUGUERA'),
  ('Jugos', 'Jugo de Chinola (Natural)', 175.00, null, true, 16, 'JUGUERA'),
  ('Jugos', 'Jugo de Chinola (Con Leche)', 225.00, null, true, 17, 'JUGUERA'),
  ('Jugos', 'Jugo de Tamarindo (Natural)', 125.00, null, true, 18, 'JUGUERA'),
  ('Jugos', 'Jugo de Tamarindo (Con Leche)', 175.00, null, true, 19, 'JUGUERA'),
  ('Jugos', 'Jugo de Cereza (Natural)', 125.00, null, true, 20, 'JUGUERA'),
  ('Jugos', 'Jugo de Cereza (Con Leche)', 175.00, null, true, 21, 'JUGUERA'),
  ('Jugos', 'Jugo de Piña (Natural)', 125.00, null, true, 22, 'JUGUERA'),
  ('Jugos', 'Jugo de Piña (Con Leche)', 175.00, null, true, 23, 'JUGUERA'),
  ('Jugos', 'Jugo de Melón (Natural)', 125.00, null, true, 24, 'JUGUERA'),
  ('Jugos', 'Jugo de Melón (Con Leche)', 175.00, null, true, 25, 'JUGUERA'),
  ('Jugos', 'Jugo de Guineo (Natural)', 125.00, null, true, 26, 'JUGUERA'),
  ('Jugos', 'Jugo de Guineo (Con Leche)', 175.00, null, true, 27, 'JUGUERA'),
  ('Jugos', 'Jugo de Fresa (Natural)', 175.00, null, true, 28, 'JUGUERA'),
  ('Jugos', 'Jugo de Fresa (Con Leche)', 225.00, null, true, 29, 'JUGUERA'),
  ('Jugos', 'Jugo de Granadillo (Natural)', 175.00, null, true, 30, 'JUGUERA'),
  ('Jugos', 'Jugo de Granadillo (Con Leche)', 225.00, null, true, 31, 'JUGUERA'),
  ('Jugos', 'Jugo de Lechoza (Natural)', 125.00, null, true, 32, 'JUGUERA'),
  ('Jugos', 'Jugo de Lechoza (Con Leche)', 175.00, null, true, 33, 'JUGUERA'),
  ('Jugos', 'Jugo de Zapote (Natural)', 125.00, null, true, 34, 'JUGUERA'),
  ('Jugos', 'Jugo de Zapote (Con Leche)', 175.00, null, true, 35, 'JUGUERA'),
  ('Jugos', 'Jugo de China (Natural)', 175.00, null, true, 36, 'JUGUERA'),
  ('Jugos', 'Jugo de China (Con Leche)', 225.00, null, true, 37, 'JUGUERA'),
  ('Jugos', 'Jugo de Mango (Natural)', 175.00, null, true, 38, 'JUGUERA'),
  ('Jugos', 'Jugo de Mango (Con Leche)', 225.00, null, true, 39, 'JUGUERA'),
  ('Jugos', 'Jugo de Pitahaya (Natural)', 175.00, null, true, 40, 'JUGUERA'),
  ('Jugos', 'Jugo de Pitahaya (Con Leche)', 225.00, null, true, 41, 'JUGUERA'),
  ('Bebidas', 'Agua', 175.00, null, true, 42, 'JUGUERA'),
  ('Bebidas', 'Refresco', 175.00, null, true, 43, 'JUGUERA'),
  ('Bebidas', 'Leche', 145.00, null, true, 44, 'JUGUERA'),
  ('Bebidas', 'Café con Leche', 175.00, null, true, 45, 'JUGUERA'),
  ('Bebidas', 'Capuccino Italiano', 175.00, null, true, 46, 'JUGUERA'),
  ('Bebidas', 'Capuccino Caramelo', 225.00, null, true, 47, 'JUGUERA'),
  ('Bebidas', 'Capuccino Suizo', 225.00, null, true, 48, 'JUGUERA'),
  ('Bebidas', 'Mocachino', 175.00, null, true, 49, 'JUGUERA'),
  ('Bebidas', 'Chocolate', 175.00, null, true, 50, 'JUGUERA'),
  ('Bebidas', 'Café Dominicano', 225.00, null, true, 51, 'JUGUERA'),
  ('Bebidas', 'Cortadito', 225.00, null, true, 52, 'JUGUERA'),
  ('Bebidas', 'Expreso', 225.00, null, true, 53, 'JUGUERA');

commit;

-- ============================================================================
-- VERIFICACIÓN — esperado: 54 filas, 0 nombres repetidos.
-- ============================================================================

select count(*) as filas from public._import_e0aef218;

select categoria, area, count(*) as productos
from public._import_e0aef218 group by categoria, area order by min(posicion);

-- Debe dar 0 filas.
select lower(name) as nombre, count(*)
from public._import_e0aef218 group by lower(name) having count(*) > 1;
