-- Rollback de 20260902_0014_analytics_cost_layers.sql
-- Solo quita la exposición al cliente; las capas de public quedan intactas.

begin;

drop view if exists analytics.inventario_faltantes;
drop view if exists analytics.costo_de_ventas;
drop view if exists analytics.inventario_valorado_capas;
drop view if exists analytics.capas_de_costo;
drop view if exists analytics.inventory_cost_consumptions;
drop view if exists analytics.inventory_cost_layers;

commit;
