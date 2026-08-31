**Asunto:** Acceso de solo lectura en vivo a su base de datos — Penda Express

---

Estimados,

Quedó habilitado el acceso que solicitaron. Es una **conexión permanente de solo lectura**,
en vivo, restringida exclusivamente a Penda Express. Corresponde a la Opción B de su
solicitud: Supabase/PostgREST con RLS.

**Un aviso sobre la herramienta:** su documento planteaba usar un conector MCP de PostgreSQL
para las opciones A y B. La Opción B no es una conexión PostgreSQL sino una **API REST sobre
HTTP**, así que necesitarán un conector HTTP/REST, no uno de Postgres. Si prefieren una
conexión PostgreSQL directa (su Opción A), podemos evaluarla; requiere abrir el puerto de la
base con restricción por IP y es una decisión aparte.

---

## Datos de conexión

```
URL              https://supabase.mangopos.do/rest/v1/

apikey           eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJzdXBhYmFzZSIsImlhdCI6MTc3MjgzOTUwMCwiZXhwIjo0OTI4NTEzMTAwLCJyb2xlIjoiYW5vbiJ9.LHw1pkCZ3DySAmly08hFoykgbG0CCC7k7Igh2izbCAg
Authorization    Bearer <SU API KEY>
Accept-Profile   analytics
```

**La API key va por separado**, en un mensaje aparte, para no dejarla junto al resto de la
información. Es la única credencial que deben resguardar: si se expone, avísennos y la
revocamos el mismo día.

Los tres encabezados son obligatorios. El `apikey` es la clave pública de la plataforma y por
sí sola no da acceso a nada; el `Authorization` es el que identifica su acceso. El
`Accept-Profile` selecciona el esquema de reportería.

Prueba rápida:

```bash
curl "https://supabase.mangopos.do/rest/v1/documentos?FECHA=gte.2026-08-01&limit=5" \
  -H "apikey: <apikey>" \
  -H "Authorization: Bearer <SU API KEY>" \
  -H "Accept-Profile: analytics"
```

---

## Qué incluye

**88 vistas de reportería** sobre sus datos: ventas, órdenes y tiempos de cocina, productos y
menú, caja, fiscal DGII, inventario, compras, clientes, y usuarios y auditoría. Pueden hacer
cualquier consulta analítica sobre ellas, con filtros por fecha y sucursal, orden, paginación,
y salida en JSON o CSV.

El diccionario completo está publicado como **OpenAPI** en la raíz de la API, así que su
herramienta puede descubrir las vistas y sus columnas por sí sola.

### El feed contable

`/documentos` entrega el formato que acordamos, **con una columna adicional: `LEY`**.

```
TIPO_DOC       NUMERO      FECHA       NOMBRE                  BRUTO    ITBIS     LEY    TOTAL
Venta Contado  100015466   2026-08-01  BIP COMPANY SERVICES  1875.72   337.63  187.57  2400.92
```

Nos permitimos agregarla porque su operación cobra **Ley 10%** además del ITBIS. Sin esa
columna, el 10% quedaba sumado dentro del `BRUTO`, que es justo el campo que la DGII pide como
base imponible en el 607. Con la columna se cumple `BRUTO + ITBIS + LEY = TOTAL` y el `ITBIS`
es exactamente el 18% del `BRUTO`. Si su herramienta necesita las 7 columnas originales, nos
dicen y ajustamos.

Los cinco tipos de documento: `Venta Contado`, `Venta Crédito`, `Recibo Pago`,
`Devolución Contado` y `Devolución Crédito`. Una venta anulada aparece **dos veces**: la venta
en su fecha y la devolución en la fecha de anulación; la venta nunca se borra.

**Un dato para que no los sorprenda:** su operación es casi toda de contado. En agosto hubo
5,860 ventas de contado, 2 a crédito y ningún recibo de pago. Los tipos de crédito van a venir
casi siempre vacíos, y eso refleja cómo opera el negocio, no una falta de datos.

`/documentos_detalle` trae las mismas filas con el desglose completo: NCF, tipo de NCF,
descuento, RNC y motivo de anulación.

---

## Parámetros técnicos que solicitaron confirmar

| | |
|---|---|
| **Solo lectura** | Confirmado a nivel del motor de base de datos. El acceso se resuelve contra un rol sin ningún permiso de escritura: un intento de modificar datos es rechazado por PostgreSQL, no por la aplicación. |
| **Alcance** | Restringido a Penda Express mediante doble filtro en la base de datos. No hay forma de alcanzar datos de otro negocio. |
| **Zona horaria** | El campo `FECHA` se calcula en `America/Santo_Domingo` (UTC−4). Las marcas de tiempo completas se devuelven en ISO 8601 UTC. |
| **Moneda** | Peso dominicano (DOP). Los importes son numéricos, sin símbolo. |
| **Diccionario** | OpenAPI en vivo en la raíz de la API, más la documentación que les enviamos aparte. |
| **Límite de tasa** | Sin límite configurado. Les avisaremos antes de introducir uno. |
| **Vigencia** | La credencial se emite por 365 días y se renueva sin cambios en su integración. |

Sobre **tratamiento de datos personales**: el acceso alcanza información de clientes (nombre,
teléfono, correo, dirección, RNC) y de empleados, por tratarse de sus propios registros. Quedamos
atentos a formalizar el acuerdo de tratamiento de datos que corresponda antes de que el acceso
entre en uso productivo.

---

## Lo que no se expone

Por seguridad quedan fuera los datos que no corresponden a su operación: medios de pago
tokenizados, credenciales de integraciones, tablas internas de respaldo y, por supuesto,
información de cualquier otro negocio.

---

Quedamos atentos a que confirmen la conexión. Cualquier consulta sobre las vistas disponibles o
el formato del feed, con gusto la atendemos.

Saludos cordiales,

MangoPOS
soporte@mangopos.do · +1 849-267-8985
