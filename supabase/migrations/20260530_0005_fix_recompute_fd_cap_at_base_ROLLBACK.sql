-- Rollback de 20260530_0005: vuelve a 20260530_0001 (escala todos los
-- componentes por ratio = scope/base, sin cap). Síntoma de la versión
-- vieja: LEY > 10% del base cuando hay over-payment.
\i 20260530_0001_fix_fn_recompute_fd_for_scope.sql
