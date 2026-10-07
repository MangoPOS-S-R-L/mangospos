-- Réplica del estado de prod según 00_diagnostico.sql del 07-oct-2026.
-- LA COCINA MEXICANA AUTENTICA (b0bd6f20) + la sucursal de Ágora (6e18428f)
-- con su Ley, que la carga copia.
insert into public.businesses (id, business_name, status) values
  ('b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'LA COCINA MEXICANA AUTENTICA', 'active'),
  ('6e18428f-fdd6-4c58-af0e-dae2403fbf1d', 'LA COCINA MEXICANA AUTENTICA (Ágora)', 'active');
insert into public.business_settings (business_id, service_fee_enabled, kitchen_enabled,
  printerless_kitchen, auto_print_order, inventory_mode, delivery_fee_required, delivery_fee_presets)
values ('b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', false, true, false, true, 'none', true, '[]');
insert into public.taxes (business_id, name, rate) values
  ('b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'ITBIS', 18),
  ('6e18428f-fdd6-4c58-af0e-dae2403fbf1d', 'ITBIS', 18);
insert into public.taxes (business_id, name, rate, include_in_ecf, apply_on_takeout) values
  ('6e18428f-fdd6-4c58-af0e-dae2403fbf1d', 'Ley', 10, false, false);
insert into public.menus (id, business_id, name) values
  (gen_random_uuid(), 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'Menú Principal');
insert into public.categories (id, business_id, name, position) values
  (gen_random_uuid(), 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'BEBIDAS🥤', 40),
  (gen_random_uuid(), 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'DELIVERY', 60),
  (gen_random_uuid(), 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'ENTRADAS 🥨', 10),
  (gen_random_uuid(), 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'EXTRAS', 70),
  (gen_random_uuid(), 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'PLATOS MEXICANOS 🌯', 30),
  (gen_random_uuid(), 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'Postres', 50),
  (gen_random_uuid(), 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', 'TACOS 🌮', 20);
insert into public.menu_items (business_id, category_id, name, price, tax_mode, is_active, print_area_code)
select 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee', c.id, v.n, v.p, v.m, v.a, v.l
from (values
  ('AGUA', 50, 'inclusive', true, 'BEBIDAS🥤', 'kitchen_hot'),
  ('BURRITO', 650, 'inclusive', true, 'PLATOS MEXICANOS 🌯', 'kitchen_hot'),
  ('Carne Cocida Natural xlb', 600, 'exclusive', true, 'EXTRAS', 'kitchen_hot'),
  ('CHILAQUILES', 700, 'inclusive', true, 'PLATOS MEXICANOS 🌯', 'kitchen_hot'),
  ('CHIMICHANGA', 700, 'inclusive', true, 'PLATOS MEXICANOS 🌯', 'kitchen_hot'),
  ('CHORIQUESO', 600, 'inclusive', true, 'ENTRADAS 🥨', 'kitchen_hot'),
  ('DELIVERY 100', 100, 'inclusive', true, 'DELIVERY', 'kitchen_hot'),
  ('DELIVERY 150', 150, 'inclusive', true, 'DELIVERY', 'kitchen_hot'),
  ('DELIVERY 200', 200, 'inclusive', true, 'DELIVERY', 'kitchen_hot'),
  ('DELIVERY 250', 250, 'inclusive', true, 'DELIVERY', 'kitchen_hot'),
  ('DELIVERY 300', 300, 'inclusive', true, 'DELIVERY', 'kitchen_hot'),
  ('DELIVERY 350', 350, 'inclusive', true, 'DELIVERY', 'kitchen_hot'),
  ('DELIVERY 400', 400, 'inclusive', true, 'DELIVERY', 'kitchen_hot'),
  ('DELIVERY 450', 450, 'inclusive', true, 'DELIVERY', 'kitchen_hot'),
  ('ENCHILADA', 800, 'inclusive', true, 'PLATOS MEXICANOS 🌯', null),
  ('ENCHILADA SUIZA', 800, 'inclusive', false, 'PLATOS MEXICANOS 🌯', 'kitchen_hot'),
  ('EXTRA DE CARNE', 150, 'inclusive', true, 'EXTRAS', null),
  ('EXTRA GUACAMOLE', 100, 'inclusive', true, 'EXTRAS', 'kitchen_hot'),
  ('Extra Nachos', 100, 'inclusive', true, 'EXTRAS', null),
  ('Extra Queso', 150, 'inclusive', true, 'EXTRAS', null),
  ('FLAUTAS DE POLLO', 600, 'inclusive', true, 'PLATOS MEXICANOS 🌯', 'kitchen_hot'),
  ('GANSITO MARINELA GRANDE', 150, 'inclusive', true, 'Postres', 'kitchen_hot'),
  ('JARRITOS', 175, 'inclusive', true, 'BEBIDAS🥤', 'kitchen_hot'),
  ('JUGOS NATURALES', 0, 'inclusive', true, 'BEBIDAS🥤', 'kitchen_hot'),
  ('MINI FLAUTAS', 500, 'inclusive', true, 'ENTRADAS 🥨', 'kitchen_hot'),
  ('NACHOS CON GUACAMOLE', 250, 'inclusive', true, 'ENTRADAS 🥨', 'kitchen_hot'),
  ('QUESADILLA DE CHORIZO', 650, 'inclusive', true, 'PLATOS MEXICANOS 🌯', 'kitchen_hot'),
  ('QUESADILLA DE POLLO', 600, 'inclusive', true, 'PLATOS MEXICANOS 🌯', 'kitchen_hot'),
  ('REFRESCOS', 0, 'inclusive', true, 'BEBIDAS🥤', 'kitchen_hot'),
  ('SODA CAN', 0, 'inclusive', true, 'BEBIDAS🥤', 'kitchen_hot'),
  ('TACO DOBLE DECKERS', 700, 'inclusive', true, 'TACOS 🌮', 'kitchen_hot'),
  ('TACOS', 650, 'inclusive', true, 'TACOS 🌮', 'kitchen_hot'),
  ('TACOS AL PASTOR', 700, 'inclusive', true, 'TACOS 🌮', 'kitchen_hot'),
  ('TACOS CHILORIO', 700, 'inclusive', true, 'TACOS 🌮', 'kitchen_hot'),
  ('TACOS DE BIRRIA', 750, 'inclusive', true, 'TACOS 🌮', 'kitchen_hot'),
  ('TACOS DE CARNITA MICHOACAN', 650, 'inclusive', true, 'TACOS 🌮', 'kitchen_hot'),
  ('TACOS FIESTAS', 1600, 'inclusive', true, 'TACOS 🌮', 'kitchen_hot'),
  ('TOSTADAS', 650, 'inclusive', true, 'PLATOS MEXICANOS 🌯', 'kitchen_hot'),
  ('UNIDAD DE TACO', 250, 'inclusive', true, 'TACOS 🌮', 'kitchen_hot')
) v(n, p, m, a, c, l)
join public.categories c on c.name = v.c;
insert into public.menu_item_links (menu_id, item_id) select m.id, mi.id from public.menus m, public.menu_items mi;
