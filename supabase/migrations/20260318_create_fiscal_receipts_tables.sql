-- =============================================
-- Módulo de Comprobantes Fiscales - SQL Schema
-- Basado en guia_modulo_comprobantes.txt
-- Soporte: PostgreSQL (Supabase)
-- Fecha: 2026-03-18
-- =============================================

-- 1. Tabla para Tipos de Comprobantes Fiscales (DGII)
CREATE TABLE IF NOT EXISTS public.dgii_receipt_types (
    id SERIAL PRIMARY KEY,
    code VARCHAR(10) UNIQUE NOT NULL, -- Código DGII (ej. "01", "02")
    name VARCHAR(100) NOT NULL, -- Nombre legible (ej. "Factura de Crédito Fiscal")
    description TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Comentarios para la tabla
COMMENT ON TABLE public.dgii_receipt_types IS 'Tipos de comprobantes fiscales definidos por la DGII.';
COMMENT ON COLUMN public.dgii_receipt_types.code IS 'Código oficial DGII para el tipo de comprobante.';
COMMENT ON COLUMN public.dgii_receipt_types.name IS 'Nombre descriptivo del tipo de comprobante.';

-- Datos de ejemplo (adaptar según guía y requerimientos)
INSERT INTO public.dgii_receipt_types (code, name) VALUES
('01', 'Factura de Crédito Fiscal'),
('02', 'Factura de Consumo'),
('03', 'Comprobante de Registro Único Tributario (RUT)'),
('04', 'Nota de Crédito'),
('05', 'Nota de Débito'),
('06', 'Comprobante de Retención')
ON CONFLICT (code) DO NOTHING; -- Evita errores si los códigos ya existen

-- 2. Tabla para Comprobantes Fiscales Emitidos
--    Registra cada comprobante fiscal generado y enviado/validado por la DGII
CREATE TABLE IF NOT EXISTS public.fiscal_receipts (
    id BIGSERIAL PRIMARY KEY,
    internal_invoice_id BIGINT, -- FK a tu tabla de facturas/transacciones si existe
    receipt_type_id INT REFERENCES public.dgii_receipt_types(id), -- Tipo de comprobante (FK)
    dgii_uuid UUID, -- UUID asignado por la DGII
    dgii_sequence_number VARCHAR(50) UNIQUE, -- Número de secuencia DGII
    receipt_number VARCHAR(50) NOT NULL, -- Número de comprobante interno o público
    issue_date DATE NOT NULL, -- Fecha de emisión
    amount DECIMAL(18, 2) NOT NULL, -- Monto total del comprobante
    tax_amount DECIMAL(18, 2) DEFAULT 0.00, -- Monto de impuestos aplicado
    status VARCHAR(50) NOT NULL DEFAULT 'PENDING', -- Estado: PENDING, SENT, VALIDATED, REJECTED, CANCELLED
    format_type VARCHAR(10) NOT NULL, -- 'B' (Antiguo) o 'E' (e-CF / Nuevo)
    xml_content BYTEA, -- Contenido XML del comprobante si se genera localmente (formato B)
    json_content JSONB, -- Contenido JSON (para e-CF)
    dgii_response JSONB, -- Respuesta recibida de la DGII
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Comentarios para la tabla
COMMENT ON TABLE public.fiscal_receipts IS 'Registra los comprobantes fiscales generados y su interacción con la DGII.';
COMMENT ON COLUMN public.fiscal_receipts.internal_invoice_id IS 'Referencia a la factura o transacción interna que originó este comprobante.';
COMMENT ON COLUMN public.fiscal_receipts.receipt_type_id IS 'Tipo de comprobante fiscal según la DGII.';
COMMENT ON COLUMN public.fiscal_receipts.dgii_uuid IS 'Identificador único del comprobante asignado por la DGII.';
COMMENT ON COLUMN public.fiscal_receipts.dgii_sequence_number IS 'Número de secuencia fiscal asignado por la DGII.';
COMMENT ON COLUMN public.fiscal_receipts.receipt_number IS 'Número de comprobante utilizado internamente o el número fiscal asignado.';
COMMENT ON COLUMN public.fiscal_receipts.status IS 'Estado actual del comprobante fiscal (ej. PENDING, SENT, VALIDATED).';
COMMENT ON COLUMN public.fiscal_receipts.format_type IS 'Indica si el comprobante corresponde al formato antiguo (B) o nuevo (E).';
COMMENT ON COLUMN public.fiscal_receipts.xml_content IS 'Contenido XML del comprobante (para formato B o intermedio).';
COMMENT ON COLUMN public.fiscal_receipts.json_content IS 'Contenido JSON del comprobante (para formato E - e-CF).';
COMMENT ON COLUMN public.fiscal_receipts.dgii_response IS 'Detalle de la respuesta recibida de la API de la DGII.';

CREATE INDEX IF NOT EXISTS idx_fiscal_receipts_invoice_id ON public.fiscal_receipts(internal_invoice_id);
CREATE INDEX IF NOT EXISTS idx_fiscal_receipts_status ON public.fiscal_receipts(status);
CREATE INDEX IF NOT EXISTS idx_fiscal_receipts_issue_date ON public.fiscal_receipts(issue_date);
CREATE INDEX IF NOT EXISTS idx_fiscal_receipts_dgii_uuid ON public.fiscal_receipts(dgii_uuid);

-- 3. Tabla para registrar logs de comunicación con la DGII
--    Esencial para auditoría y debugging de interacciones con el ente fiscal.
CREATE TABLE IF NOT EXISTS public.dgii_logs (
    id BIGSERIAL PRIMARY KEY,
    fiscal_receipt_id BIGINT REFERENCES public.fiscal_receipts(id) ON DELETE SET NULL, -- FK al comprobante fiscal asociado
    log_type VARCHAR(50) NOT NULL, -- Ej: "REQUEST", "RESPONSE", "ERROR", "VALIDATION"
    message TEXT NOT NULL, -- Descripción del log
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    request_payload JSONB, -- Payload enviado a DGII (opcional)
    response_payload JSONB -- Payload recibido de DGII (opcional)
);

COMMENT ON TABLE public.dgii_logs IS 'Registra los intercambios de información y errores con la DGII.';
COMMENT ON COLUMN public.dgii_logs.fiscal_receipt_id IS 'Comprobante fiscal al que se relaciona este log.';
COMMENT ON COLUMN public.dgii_logs.log_type IS 'Indica si es una petición, respuesta, error, etc.';
COMMENT ON COLUMN public.dgii_logs.message IS 'Descripción del evento o error.';
COMMENT ON COLUMN public.dgii_logs.request_payload IS 'Datos enviados en la petición a la DGII.';
COMMENT ON COLUMN public.dgii_logs.response_payload IS 'Datos recibidos desde la DGII.';

CREATE INDEX IF NOT EXISTS idx_dgii_logs_receipt_id ON public.dgii_logs(fiscal_receipt_id);
CREATE INDEX IF NOT EXISTS idx_dgii_logs_type ON public.dgii_logs(log_type);
CREATE INDEX IF NOT EXISTS idx_dgii_logs_timestamp ON public.dgii_logs(timestamp);

-- 4. Tabla para configuraciones específicas del módulo
--    Almacena parámetros que controlan el comportamiento del módulo (activación, credenciales, etc.).
CREATE TABLE IF NOT EXISTS public.module_comprobantes_settings (
    setting_key VARCHAR(100) PRIMARY KEY, -- Ej: "DGII_API_URL", "DEFAULT_FORMAT", "ENABLE_MODULE"
    setting_value TEXT, -- Valor de la configuración
    description TEXT, -- Descripción clarificadora
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Comentarios para la tabla
COMMENT ON TABLE public.module_comprobantes_settings IS 'Configuraciones específicas para el módulo de comprobantes fiscales.';
COMMENT ON COLUMN public.module_comprobantes_settings.setting_key IS 'Nombre único de la configuración.';
COMMENT ON COLUMN public.module_comprobantes_settings.setting_value IS 'Valor de la configuración.';

-- Datos de ejemplo iniciales. Estos valores deberán ser actualizados en tu entorno de despliegue.
-- Por defecto, el módulo está inactivo ('false').
INSERT INTO public.module_comprobantes_settings (setting_key, setting_value, description) VALUES
('ENABLE_MODULE', 'false', 'Indica si el módulo de comprobantes fiscales está activo. Cambiar a "true" para habilitar.'),
('DEFAULT_FORMAT_TYPE', 'E', 'Formato por defecto para la generación de nuevos comprobantes (B: Antiguo, E: Nuevo e-CF).'),
('DGII_API_URL', 'https://api.ejemplo.dgii.gob.do/v1', 'URL de la API de la DGII para pruebas/producción. Ajustar según la documentación oficial.'),
('DGII_API_KEY', 'YOUR_DGII_API_KEY', 'Clave de API para autenticación con la DGII. ¡Manejar de forma segura!'),
('DGII_USERNAME', 'YOUR_DGII_USERNAME', 'Nombre de usuario para autenticación DGII.'),
('DGII_PASSWORD', 'YOUR_DGII_PASSWORD', 'Contraseña para autenticación DGII.'),
('TAX_RATE_PERCENT', '18.00', 'Porcentaje de impuesto aplicado (ej. 18% para ITBIS) por defecto.'),
('INVOICE_TABLE_NAME', 'public.invoices', 'Nombre de la tabla en tu base de datos que contiene las facturas principales (si aplica). Ajustar según tu esquema.');

-- Triggers para mantener actualizada la columna 'updated_at'
--    Funciones y triggers para actualizar automáticamente la marca de tiempo en modificaciones.
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Asociar trigers a tablas relevantes
CREATE TRIGGER update_dgii_receipt_types_modtime
BEFORE UPDATE ON public.dgii_receipt_types FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_fiscal_receipts_modtime
BEFORE UPDATE ON public.fiscal_receipts FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_module_settings_modtime
BEFORE UPDATE ON public.module_comprobantes_settings FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- Nota: No creamos trigger para dgii_logs ya que el timestamp se genera automáticamente al insertar.
