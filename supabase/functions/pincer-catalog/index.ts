// pincer-catalog — el menu del restaurante, para que el canal case sus platos.
//
//   GET /pincer-catalog[?updated_since=<iso8601>]
//
// Ver docs/PRD_INTEGRACION_PINCER.md §5.3 y §6.
//
// Dos garantias que el canal necesita poder asumir:
//
//   1. El `id` es un UUID que NO cambia nunca: ni al editar nombre, ni precio,
//      ni categoria.
//   2. Un producto dado de baja NO desaparece del listado: sale con
//      `is_active: false`, para siempre. Si desapareciera de golpe, el canal se
//      quedaria con lineas apuntando a un id muerto y el pedido rebotaria con
//      422 en plena hora pico.
//   3. `price` es el precio de MENU. Cuando `price_includes_tax` es true (el
//      caso de Tropella: todo el menu es `inclusive`), ese precio YA trae el
//      ITBIS y la Ley adentro y el canal debe cobrar exactamente eso. Sumarle
//      impuestos encima serian 28% de mas al cliente.
//
// `updated_since` filtra el delta. Con menus de restaurante, consultar cada 15
// minutos alcanza de sobra y no necesita webhooks ni estado de nuestro lado.

import {
  corsPreflight,
  errorResponse,
  jsonResponse,
} from "../_shared/responses.ts";
import {
  authenticateChannel,
  serviceClient,
} from "../_shared/external-channel-auth.ts";

interface ModifierRow {
  id: string;
  name: string;
  price_delta: number;
  is_active: boolean;
  group_id: string | null;
}

Deno.serve(async (req) => {
  const preflight = corsPreflight(req);
  if (preflight) return preflight;

  if (req.method !== "GET") {
    return errorResponse(405, "method_not_allowed", "Solo GET");
  }

  // En GET no hay cuerpo: la firma va sobre la cadena vacia.
  const auth = await authenticateChannel(req, "", "catalog:read");
  if (!auth.ok) {
    return errorResponse(auth.failure.status, auth.failure.code, auth.message);
  }

  const businessId = auth.credential.businessId;
  const updatedSince = new URL(req.url).searchParams.get("updated_since");

  if (updatedSince && Number.isNaN(Date.parse(updatedSince))) {
    return errorResponse(
      422,
      "invalid_payload",
      "updated_since tiene que ser una fecha ISO 8601",
    );
  }

  const db = serviceClient();

  try {
    const [businessRes, categoriesRes] = await Promise.all([
      db.from("businesses")
        .select("id, business_name, country")
        .eq("id", businessId)
        .maybeSingle(),
      db.from("categories")
        .select("id, name, position")
        .eq("business_id", businessId)
        .order("position", { ascending: true }),
    ]);

    let itemsQuery = db.from("menu_items")
      .select("id, name, category_id, price, is_active, image_url, updated_at, tax_mode")
      .eq("business_id", businessId)
      .order("name", { ascending: true });

    if (updatedSince) {
      itemsQuery = itemsQuery.gte("updated_at", updatedSince);
    }

    const { data: items, error: itemsError } = await itemsQuery;
    if (itemsError) throw itemsError;

    const itemIds = (items ?? []).map((i) => i.id as string);

    // Modificadores por producto: menu_item_groups (N:M) → modifier_groups → modifiers.
    const groupsByItem = new Map<string, string[]>();
    const groupMeta = new Map<string, Record<string, unknown>>();
    const modifiersByGroup = new Map<string, ModifierRow[]>();

    if (itemIds.length > 0) {
      // Lotes de 150: PostgREST manda el filtro en la URL y un `in` largo
      // revienta con 414 ([[project_postgrest_414_infilter_batching]]).
      for (let i = 0; i < itemIds.length; i += 150) {
        const slice = itemIds.slice(i, i + 150);
        // Sin `position`: la app la usa, pero no existe en las migraciones del
        // repo y no hay como garantizarla. El orden de los grupos no le importa
        // al canal — ellos arman su propia vista.
        const { data: links, error } = await db
          .from("menu_item_groups")
          .select("menu_item_id, group_id")
          .in("menu_item_id", slice);
        if (error) throw error;
        for (const link of links ?? []) {
          const key = link.menu_item_id as string;
          if (!groupsByItem.has(key)) groupsByItem.set(key, []);
          groupsByItem.get(key)!.push(link.group_id as string);
        }
      }
    }

    const groupIds = [...new Set([...groupsByItem.values()].flat())];

    if (groupIds.length > 0) {
      const { data: groups, error: gErr } = await db
        .from("modifier_groups")
        .select("id, name, min_select, max_select, is_active")
        .eq("business_id", businessId)
        .in("id", groupIds);
      if (gErr) throw gErr;
      for (const g of groups ?? []) groupMeta.set(g.id as string, g);

      const { data: mods, error: mErr } = await db
        .from("modifiers")
        .select("id, name, price_delta, is_active, group_id")
        .eq("business_id", businessId)
        .in("group_id", groupIds);
      if (mErr) throw mErr;
      for (const m of (mods ?? []) as ModifierRow[]) {
        const key = m.group_id ?? "";
        if (!modifiersByGroup.has(key)) modifiersByGroup.set(key, []);
        modifiersByGroup.get(key)!.push(m);
      }
    }

    const business = businessRes.data as Record<string, unknown> | null;

    const payload = {
      business: {
        id: businessId,
        name: business?.business_name ?? null,
        // Moneda del pais; hoy todos los negocios operan en DOP.
        currency: "DOP",
      },
      catalog_version: new Date().toISOString(),
      // Un delta no trae categorias completas: se mandan siempre, son pocas.
      categories: (categoriesRes.data ?? []).map((c) => ({
        id: c.id,
        name: c.name,
        position: c.position,
      })),
      items: (items ?? []).map((item) => {
        const groups = (groupsByItem.get(item.id as string) ?? [])
          .map((gid) => {
            const meta = groupMeta.get(gid);
            if (!meta || meta.is_active === false) return null;
            return {
              id: gid,
              name: meta.name,
              min_select: meta.min_select ?? 0,
              max_select: meta.max_select ?? 0,
              modifiers: (modifiersByGroup.get(gid) ?? [])
                .filter((m) => m.is_active !== false)
                .map((m) => ({
                  id: m.id,
                  name: m.name,
                  price_delta: Number(m.price_delta ?? 0),
                })),
            };
          })
          .filter((g) => g !== null);

        return {
          id: item.id,
          name: item.name,
          category_id: item.category_id,
          price: Number(item.price ?? 0),
          // true = el precio ya trae los impuestos adentro; cobrar tal cual.
          price_includes_tax: item.tax_mode === "inclusive",
          // Un producto de baja sale con false; NUNCA se lo quitamos del feed.
          is_active: item.is_active !== false,
          image_url: item.image_url,
          updated_at: item.updated_at,
          modifier_groups: groups,
        };
      }),
    };

    return jsonResponse(payload);
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    console.error("pincer-catalog fallo:", message);
    return errorResponse(500, "internal_error", "No se pudo leer el catalogo");
  }
});
