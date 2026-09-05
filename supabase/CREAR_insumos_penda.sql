-- =============================================================================
-- Alta de los insumos que la hoja de Penda trajo y el sistema no tiene.
--
-- Verificado antes de escribir esto:
--   · ninguno existe por CÓDIGO en `inventory_items`
--   · ninguno tiene un producto PARECIDO en el menú (salvo dos, excluidos:
--     `COCOA AMARGA` y `MALAGUETA`, que ya están en el menú SIN inventario —
--     a esos hay que prenderles el switch «Inventariable», no crearlos acá)
--
-- EL CÓDIGO VA EN `sku`, no en `barcode`: es donde lo tiene TODO el resto del
-- catálogo de este negocio. Mezclar las dos columnas complica cualquier
-- consulta futura. El escáner resuelve por las dos, así que funciona igual.
--
-- NO CARGA EXISTENCIA. Los insumos nacen en cero y las cantidades entran por
-- el conteo físico, que es lo que deja rastro y valuación. La columna
-- `cantidad_contada` del CSV es la referencia para teclearlas ahí.
--
-- IDEMPOTENTE: el `where not exists` por nombre evita duplicar si se corre
-- dos veces.
-- =============================================================================

begin;

insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Aceituna Gourmet con hueso', '8413080006145', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Aceituna Gourmet con hueso'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Anís Estrella', '2050001115645', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Anís Estrella'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Sazón completo Baldom 8 lb', '787545193793', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Sazón completo Baldom 8 lb'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Jengibre molido', '8411070033867', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Jengibre molido'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Alcaparra', '41331013703', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Alcaparra'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Paprika', '607766553346', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Paprika'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Trident Menta Fuerte', '7622202375774', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Trident Menta Fuerte'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Pasta Penne Bravo', '2050001119407', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Pasta Penne Bravo'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Pasta de coditos Bravo', '2050001119414', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Pasta de coditos Bravo'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Crema de leche Bravo pequeña', '2050001132840', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Crema de leche Bravo pequeña'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Mostaza French’s', '41500819389', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Mostaza French’s'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Nuez moscada Bravo', '8411070032268', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Nuez moscada Bravo'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Azúcar líquida blue agave', '607766046411', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Azúcar líquida blue agave'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Lata de maíz dulce 70 oz Linda', '751685110002', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Lata de maíz dulce 70 oz Linda'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Sesame Oil 6.28 oz', '41224871229', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Sesame Oil 6.28 oz'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Chispas de chocolate NTD 5 lb', '7468622644454', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Chispas de chocolate NTD 5 lb'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Pasta Penne', '8076802085738', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Pasta Penne'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Pasta Linguine', '8076800195132', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Pasta Linguine'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Leche condensada Nestlé', '7460123450718', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Leche condensada Nestlé'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Tajín', '633148100013', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Tajín'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Vinagre balsámico 1 L', '607766705059', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Vinagre balsámico 1 L'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Cebolla granulada', '33844005351', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Cebolla granulada'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Vainilla blanca 16 oz', '2050001107213', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Vainilla blanca 16 oz'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Lata de tomates triturados 6.6 lb', '751685002925', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Lata de tomates triturados 6.6 lb'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Bicarbonato Bravo', '2050001106186', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Bicarbonato Bravo'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Espaguetis Primavera', '2050001366528', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Espaguetis Primavera'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Azúcar pulverizada', '2050001398321', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Azúcar pulverizada'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Leche Parmalat sin lactosa 1 L', '7466774656202', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Leche Parmalat sin lactosa 1 L'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Cocoa dulce', '2050001277725', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Cocoa dulce'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Gatorade Fresa Sandía', '7460548002660', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Gatorade Fresa Sandía'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Leche condensada Condesa', '2050001222282', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Leche condensada Condesa'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Huevos Sorpresa', '6921101250368', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Huevos Sorpresa'));
insert into public.inventory_items
  (business_id, name, sku, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Caja de sopita Doña Gallina', '7702354501891', 'unidad', 0, 0, true
 where not exists (select 1 from public.inventory_items
                    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and lower(name) = lower('Caja de sopita Doña Gallina'));

-- ── LOS TRES QUE NO SE CARGAN AUTOMÁTICO ──────────────────────────────────
--
-- `Ajo granulado` y `Pote de cinamon` comparten el código 33844005115 en la
-- hoja. Dos productos no pueden tener el mismo EAN: uno está mal. Cargarlos
-- así dejaría al escáner encontrando dos insumos y negándose a elegir.
-- Escaneá los dos envases y descomentá con el código correcto:
--
-- insert into public.inventory_items
--   (business_id, name, sku, unit, cost, min_stock, is_active)
-- values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Ajo granulado',   '<CODIGO REAL>', 'unidad', 0, 0, true),
--        ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Pote de cinamon', '<CODIGO REAL>', 'unidad', 0, 0, true);
--
-- `Sazón azafrán Ranchero` vino sin código en la hoja:
--
-- insert into public.inventory_items
--   (business_id, name, sku, unit, cost, min_stock, is_active)
-- values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'Sazón azafrán Ranchero', '<CODIGO REAL>', 'unidad', 0, 0, true);

commit;
