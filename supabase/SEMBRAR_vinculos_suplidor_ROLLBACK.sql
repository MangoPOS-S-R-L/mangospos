-- =============================================================================
-- ROLLBACK de SEMBRAR_vinculos_suplidor.sql
--
-- Borra SOLO los vínculos sembrados que siguen igual a como se sembraron: si
-- alguien corrigió el precio, la presentación o el contenido desde la app, ese
-- vínculo se respeta.
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create temporary table tmp_params on commit drop as
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as business_id;   -- ← negocio

delete from public.supplier_items si
 using public.backup_supplier_items_seed b, tmp_params p
 where si.id = b.id
   and si.business_id = b.business_id
   and b.business_id = p.business_id
   and si.last_price    is not distinct from b.sembrado_price
   and si.purchase_unit is not distinct from b.sembrado_unit
   and si.pack_size     is not distinct from b.sembrado_pack;

delete from public.backup_supplier_items_seed b
 using tmp_params p
 where b.business_id = p.business_id
   and not exists (select 1 from public.supplier_items si where si.id = b.id);

commit;
