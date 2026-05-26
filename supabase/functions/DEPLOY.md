# Deploy de Edge Functions Azul — Supabase self-hosted (Coolify)

Este documento cubre los 3 patrones más comunes de despliegue. **Identifica el tuyo y sigue la sección correspondiente.**

---

## Paso previo (cualquier patrón) — Aplicar la migración DB

Las funciones leen/escriben tablas que aún no existen en tu Supabase. Aplica primero:

```bash
# Opción A — via Supabase SQL editor del dashboard (Coolify expone el Studio):
#   Abre Studio → SQL → pega el contenido de:
#     supabase/migrations/20260526_0002_azul_subscriptions_schema.sql
#   Ejecuta.

# Opción B — via psql directo contra el postgres del stack Coolify:
psql "postgresql://postgres:<password>@<host>:<port>/postgres" \
  -f supabase/migrations/20260526_0002_azul_subscriptions_schema.sql
```

**Verificación post-migración:**
```sql
-- Debe devolver 5 tablas: plans + azul_payment_*, azul_charges, azul_webhook_events
select tablename from pg_tables
where schemaname='public' and (tablename like 'azul_%' or tablename='plans')
order by tablename;

-- Debe devolver 3 planes seed.
select code, name, price_cents_monthly from public.plans order by display_order;

-- Memberships debe tener las nuevas columnas billing.
\d public.memberships
```

---

## Paso previo — Configurar secrets

Las 11 variables están en [`.env.example`](.env.example). Cópialo:

```bash
cp supabase/functions/.env.example supabase/functions/.env.local
# Edita .env.local con los valores reales — .env.local está en .gitignore.
```

Cómo cargar esos secrets al runtime depende del patrón de tu Coolify (ver abajo). Para PLACEHOLDERS iniciales (validar que el deploy funciona aunque las trxs reales no), puedes dejar los valores tal cual están en el example.

---

## Patrón A — Git push + Coolify auto-deploy

**Síntoma:** tu Coolify tiene configurado un repo git (este mismo o uno gemelo de infra) que al hacer `git push` dispara redeploy del stack Supabase.

**Pasos:**

1. **Verifica el path:** en tu Coolify, el container `functions` (imagen `supabase/edge-runtime`) tiene un volumen montado. Debe ser algo como `./volumes/functions:/home/deno/functions` o equivalente. Las carpetas `azul-*` deben terminar en ese path dentro del container.

2. **Push del código:**
   ```bash
   git add supabase/functions/ supabase/config.toml \
           supabase/migrations/20260526_0002_azul_subscriptions_schema.sql \
           supabase/migrations/20260526_0002_azul_subscriptions_schema_ROLLBACK.sql
   git commit -m "feat(azul): F0+F2+F3 — hash, esquema DB, edge functions de tokenización"
   git push
   ```

3. **Configura secrets en Coolify:** UI de Coolify → tu app/stack Supabase → Environment Variables → agrega las 11 vars del `.env.example` con valores reales. **No hagas commit del `.env.local`.**

4. **Redeploy:** Coolify lo hace solo o con un botón "Redeploy" en su UI.

5. **Verifica:**
   ```bash
   curl -i https://supabase.tudominio.com/functions/v1/azul-payment-form?session_id=00000000-0000-0000-0000-000000000000
   # Debe devolver 404 con HTML "Sesión no encontrada". Si devuelve 404 sin
   # HTML, el container no encontró la función — revisa logs del container.
   ```

---

## Patrón B — SSH al servidor + rsync manual

**Síntoma:** tu Coolify corre en un VPS y tienes acceso SSH. El stack Supabase no se redeploya solo desde git.

**Pasos:**

1. **Localiza el path** del volumen `functions` en tu VPS:
   ```bash
   ssh tu-vps
   # Dentro del VPS, busca el directorio del stack Supabase de Coolify:
   docker ps --filter "ancestor=supabase/edge-runtime" --format "{{.Names}}\t{{.Mounts}}"
   # Verás algo como: supabase-functions  /home/coolify/data/services/<id>/functions
   ```

2. **Desde tu máquina local**, sincroniza:
   ```bash
   rsync -avz --delete \
     supabase/functions/ \
     tu-vps:/home/coolify/data/services/<id>/functions/
   ```

3. **Configura secrets** en el archivo `.env` del stack o como variables del container (vía Coolify UI):
   ```bash
   ssh tu-vps
   cd /home/coolify/data/services/<id>
   # Edita .env con los valores de AZUL_*, PUBLIC_*, SUPABASE_*
   ```

4. **Reinicia el container `functions`:**
   ```bash
   docker restart <nombre-container-functions>
   ```

5. **Verifica logs:**
   ```bash
   docker logs --tail 50 -f <nombre-container-functions>
   # Deberías ver: "serving azul-create-tokenization-session at /azul-create-tokenization-session"
   #              "serving azul-payment-form at /azul-payment-form"
   #              ... etc
   ```

---

## Patrón C — Acceso via API admin de Coolify (raro)

**Síntoma:** Coolify expone una API de management y tienes un token.

```bash
# No es el flujo estándar; te paso la idea por completitud.
# Subir un tar.gz con las funciones a través de la API de Coolify,
# que internamente descomprime al volumen del container.
curl -X POST https://coolify.tudominio.com/api/v1/services/<id>/files \
  -H "Authorization: Bearer $COOLIFY_TOKEN" \
  -F "path=/functions" \
  -F "file=@functions.tar.gz"
```

Si tu Coolify es esto, dame el endpoint y el token y armamos el script exacto.

---

## Después del deploy — Smoke test

```bash
# 1. payment-form sin session_id válido debe devolver 400.
curl -i https://supabase.tudominio.com/functions/v1/azul-payment-form

# 2. callback sin params debe loguear en azul_webhook_events.
curl -i "https://supabase.tudominio.com/functions/v1/azul-callback?status=cancelled"

# 3. create-tokenization-session sin JWT debe devolver 401.
curl -i -X POST https://supabase.tudominio.com/functions/v1/azul-create-tokenization-session \
  -H "Content-Type: application/json" -d '{"business_id":"x"}'
# Esperado: {"error":{"code":"unauthorized","message":"Missing Bearer token"}}

# 4. Confirma que azul_webhook_events recibió logs reales:
psql "$DB_URL" -c "select event_type, raw_url, received_at from azul_webhook_events order by received_at desc limit 5;"
```

---

## Después del smoke test — Test real contra Azul pruebas

Con las 6 tarjetas de prueba del PRD §12.2:

```
4035 8740 0042 4977   Exp 202812   CVV 977  (Visa)
5426 0640 0042 4979   Exp 202812   CVV 979  (Mastercard)
4012 0000 3333 0026   Exp 202812   CVV 123  (Visa)
5424 1802 7979 1732   Exp 202812   CVV 732  (Mastercard)
6011 0009 9009 9818   Exp 202812   CVV 818  (Discover)
4260 5500 6184 5872   Exp 202812   CVV 872  (Visa)
```

Flujo manual (porque la UI del checkout web aún no existe — F5.1 pendiente):

```bash
# Asumiendo que tienes un business_id real con tu user_id como owner/admin:
BIZ=<tu_business_id>
JWT=<tu_jwt_supabase>

curl -X POST https://supabase.tudominio.com/functions/v1/azul-create-tokenization-session \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d "{\"business_id\":\"$BIZ\"}"

# Response: { "payment_page_url": "https://..." }
# Abre esa URL en un browser → te lleva a Azul.
# Digita una tarjeta de prueba.
# Al aprobar, te redirige a /onboarding/payment-result?result=approved
# (esa URL aún no existe en mangopos.do — F5.1 — pero el backend ya creó
# el azul_payment_methods row y disparó el void-hold).
#
# Verifica en DB:
#   select * from azul_payment_methods where business_id = '$BIZ' order by created_at desc limit 1;
#   select event_type, processed, processing_error, received_at
#     from azul_webhook_events order by received_at desc limit 10;
```

---

## Si algo falla, en este orden mira

1. **Logs del container `functions`** — startup errors (env vars faltantes) y stack traces.
2. **Tabla `azul_webhook_events`** — todo lo que llegó de Azul, válido o no, queda ahí. `processed=false` con `processing_error` no nulo es la pista.
3. **Tabla `azul_payment_sessions`** — `status='tampered'` significa AuthKey mal configurada (server ≠ Azul).
4. **Smoke tests del psql** arriba para confirmar que la migración aplicó.
