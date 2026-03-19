-- 20260318_0031_comprobantes_dgii.sql
-- MODULO DE COMPROBANTE FISCAL (DGII RD)
-- Multi-tenancy listo con business_id

begin;

--- 1. TABLA: comprobantes ---
CREATE TABLE IF NOT EXISTS public.comprobantes (
    id                   UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    business_id          UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    ncf                  VARCHAR(20),               -- Asignado al emitir
    tipo                 VARCHAR(5) NOT NULL,       -- '31','32','33','34'... (e-CF)
    serie                VARCHAR(5) NOT NULL DEFAULT 'E',
    secuencial           BIGINT,

    -- Emisor (Copia de seguridad de los datos al momento de emisión)
    emisor_rnc           VARCHAR(11) NOT NULL,
    emisor_nombre        TEXT NOT NULL,

    -- Receptor
    receptor_rnc         VARCHAR(11),
    receptor_nombre      TEXT,
    receptor_tipo        VARCHAR(2),                -- '01' Fisica, '02' Juridica

    -- Montos
    subtotal             NUMERIC(15,2) NOT NULL DEFAULT 0,
    descuento            NUMERIC(15,2) NOT NULL DEFAULT 0,
    itbis                NUMERIC(15,2) NOT NULL DEFAULT 0,
    total                NUMERIC(15,2) NOT NULL DEFAULT 0,
    moneda               VARCHAR(3) NOT NULL DEFAULT 'DOP',
    tasa_cambio          NUMERIC(10,4) DEFAULT 1.0,

    -- Estado: borrador | emitido | enviado_dgii | aceptado | rechazado | anulado
    estado               VARCHAR(20) NOT NULL DEFAULT 'borrador',

    -- Referencias (para notas credito/debito)
    ncf_modificado       VARCHAR(20),
    fecha_ncf_modificado DATE,

    -- Metadatos
    fecha_emision        TIMESTAMPTZ,
    notas                TEXT,
    usuario_id           UUID REFERENCES auth.users(id),
    created_at           TIMESTAMPTZ DEFAULT NOW(),
    updated_at           TIMESTAMPTZ DEFAULT NOW()
);

-- Indices
CREATE INDEX IF NOT EXISTS idx_comprobantes_business ON public.comprobantes(business_id);
CREATE INDEX IF NOT EXISTS idx_comprobantes_ncf ON public.comprobantes(ncf);

--- 2. TABLA: comprobante_items ---
CREATE TABLE IF NOT EXISTS public.comprobante_items (
    id               UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    comprobante_id   UUID REFERENCES public.comprobantes(id) ON DELETE CASCADE,
    linea            INT NOT NULL,
    descripcion      TEXT NOT NULL,
    cantidad         NUMERIC(15,4) NOT NULL,
    precio_unitario  NUMERIC(15,4) NOT NULL,
    descuento        NUMERIC(15,2) DEFAULT 0,
    itbis_rate       NUMERIC(5,2) DEFAULT 18.00,       -- 0, 16, 18
    itbis_monto      NUMERIC(15,2) DEFAULT 0,
    subtotal         NUMERIC(15,2) NOT NULL,
    codigo_producto  VARCHAR(50),
    unidad_medida    VARCHAR(20)
);

CREATE INDEX IF NOT EXISTS idx_comprobante_items_parent ON public.comprobante_items(comprobante_id);

--- 3. TABLA: secuencias_ncf ---
CREATE TABLE IF NOT EXISTS public.secuencias_ncf (
    id           UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    business_id  UUID NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    tipo         VARCHAR(5) NOT NULL,               -- '31', '32', etc.
    serie        VARCHAR(5) NOT NULL DEFAULT 'E',
    ultimo_seq   BIGINT NOT NULL DEFAULT 0,
    maximo_seq   BIGINT NOT NULL DEFAULT 99999999,
    activo       BOOLEAN DEFAULT TRUE,
    updated_at   TIMESTAMPTZ DEFAULT NOW(),
    unique(business_id, tipo, serie)
);

--- 4. AUDITORIA: auditoria_comprobantes ---
CREATE TABLE IF NOT EXISTS public.auditoria_comprobantes (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    comprobante_id  UUID NOT NULL REFERENCES public.comprobantes(id) ON DELETE CASCADE,
    accion          VARCHAR(50) NOT NULL,
    estado_anterior VARCHAR(20),
    estado_nuevo    VARCHAR(20),
    usuario_id      UUID REFERENCES auth.users(id),
    detalles        JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

--- 5. FUNCION: siguiente_ncf (ATOMICA) ---
CREATE OR REPLACE FUNCTION public.siguiente_ncf(p_business_id UUID, p_tipo VARCHAR)
RETURNS VARCHAR AS $$
DECLARE
    v_serie  VARCHAR(5);
    v_seq    BIGINT;
BEGIN
    UPDATE public.secuencias_ncf
    SET ultimo_seq = ultimo_seq + 1, updated_at = NOW()
    WHERE business_id = p_business_id AND tipo = p_tipo AND activo = TRUE
    RETURNING serie, ultimo_seq INTO v_serie, v_seq;

    IF v_seq IS NULL THEN
      RAISE EXCEPTION 'Secuencia NCF para tipo % no encontrada o agotada para este negocio', p_tipo;
    END IF;

    -- Formato: Serie + Tipo + 8 digitos secuenciales
    RETURN v_serie || p_tipo || LPAD(v_seq::TEXT, 8, '0');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

--- 6. TRIGGER: Auditoria de Cambios ---
CREATE OR REPLACE FUNCTION public.fn_audit_comprobante()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'UPDATE') THEN
    IF OLD.estado IS DISTINCT FROM NEW.estado THEN
      INSERT INTO public.auditoria_comprobantes
        (comprobante_id, accion, estado_anterior, estado_nuevo, usuario_id)
      VALUES
        (NEW.id, 'cambio_estado', OLD.estado, NEW.estado, auth.uid());
    END IF;
  ELSIF (TG_OP = 'INSERT') THEN
      INSERT INTO public.auditoria_comprobantes
        (comprobante_id, accion, estado_nuevo, usuario_id)
      VALUES
        (NEW.id, 'creacion', NEW.estado, auth.uid());
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_audit_comprobante ON public.comprobantes;
CREATE TRIGGER trg_audit_comprobante
    AFTER INSERT OR UPDATE ON public.comprobantes
    FOR EACH ROW EXECUTE FUNCTION public.fn_audit_comprobante();

--- 7. VISTA: v_comprobantes ---
CREATE OR REPLACE VIEW public.v_comprobantes AS
SELECT c.*,
    CASE
      WHEN c.serie = 'E' AND c.tipo = '31' THEN 'Factura Credito Fiscal (e-CF)'
      WHEN c.serie = 'E' AND c.tipo = '32' THEN 'Factura Consumidor Final (e-CF)'
      WHEN c.serie = 'E' AND c.tipo = '33' THEN 'Nota de Debito (e-CF)'
      WHEN c.serie = 'E' AND c.tipo = '34' THEN 'Nota de Credito (e-CF)'
      WHEN c.serie = 'E' AND c.tipo = '41' THEN 'Comprobante de Compras (e-CF)'
      WHEN c.serie = 'E' AND c.tipo = '43' THEN 'Gastos Menores (e-CF)'
      WHEN c.serie = 'E' AND c.tipo = '44' THEN 'Regimenes Especiales (e-CF)'
      WHEN c.serie = 'E' AND c.tipo = '45' THEN 'Gubernamental (e-CF)'
      WHEN c.serie = 'E' AND c.tipo = '46' THEN 'Exportaciones (e-CF)'
      WHEN c.serie = 'B' AND c.tipo = '01' THEN 'Factura Credito Fiscal (NCF)'
      WHEN c.serie = 'B' AND c.tipo = '02' THEN 'Factura Consumidor Final (NCF)'
      WHEN c.serie = 'B' AND c.tipo = '03' THEN 'Nota de Debito (NCF)'
      WHEN c.serie = 'B' AND c.tipo = '04' THEN 'Nota de Credito (NCF)'
      ELSE 'Otro (' || c.serie || c.tipo || ')'
    END AS nombre_tipo
FROM public.comprobantes c;

--- 8. SEGURIDAD (RLS) ---
ALTER TABLE public.comprobantes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.comprobante_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.secuencias_ncf ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auditoria_comprobantes ENABLE ROW LEVEL SECURITY;

-- comprobantes
DROP POLICY IF EXISTS "comprobantes_select" ON public.comprobantes;
CREATE POLICY "comprobantes_select" ON public.comprobantes
FOR SELECT USING (public.fn_user_in_business(business_id));

DROP POLICY IF EXISTS "comprobantes_insert" ON public.comprobantes;
CREATE POLICY "comprobantes_insert" ON public.comprobantes
FOR INSERT WITH CHECK (public.fn_user_in_business(business_id));

DROP POLICY IF EXISTS "comprobantes_update" ON public.comprobantes;
CREATE POLICY "comprobantes_update" ON public.comprobantes
FOR UPDATE USING (public.fn_user_in_business(business_id) AND estado = 'borrador');

-- comprobante_items
DROP POLICY IF EXISTS "comprobante_items_all" ON public.comprobante_items;
CREATE POLICY "comprobante_items_all" ON public.comprobante_items
FOR ALL USING (
  EXISTS (
    SELECT 1 FROM public.comprobantes c
    WHERE c.id = comprobante_items.comprobante_id
    AND public.fn_user_in_business(c.business_id)
  )
);

-- secuencias_ncf
DROP POLICY IF EXISTS "secuencias_ncf_select" ON public.secuencias_ncf;
CREATE POLICY "secuencias_ncf_select" ON public.secuencias_ncf
FOR SELECT USING (public.fn_user_in_business(business_id));

--- 9. NUEVA PERMISION ---
INSERT INTO public.permissions (code, name, module, description)
VALUES ('settings.comprobantes.gestionar', 'Gestionar Comprobantes Fiscales', 'settings', 'Configurar secuencias NCF y tipos de comprobantes.')
ON CONFLICT (code) DO NOTHING;

-- Asignar a owner y admin por defecto para negocios existentes (opcional)
INSERT INTO public.role_permissions (role_id, permission_id, allow)
SELECT r.id, p.id, true
FROM public.roles r, public.permissions p
WHERE p.code = 'settings.comprobantes.gestionar'
AND lower(r.name) IN ('owner', 'admin')
ON CONFLICT DO NOTHING;

commit;
