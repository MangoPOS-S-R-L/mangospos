-- =============================================================================
-- Los productos YA CARGADOS que el archivo NO trae (los 198 de la fila 6).
-- Solo LEE. Devuelve UNA tabla; pegala de vuelta para cruzarla por similitud
-- contra los 625 del archivo y detectar los que son el MISMO producto escrito
-- distinto (esos serian duplicados que el match por nombre no atrapa).
-- =============================================================================

select mi.name,
       coalesce(c.name, '(sin categoria)') as categoria,
       mi.price,
       mi.is_active as activo
from public.menu_items mi
left join public.categories c on c.id = mi.category_id
where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'::uuid
order by coalesce(c.name, 'zzz'), mi.name;
