# Descartado — catálogo equivocado para 528df61f

Estos scripts cargaban `~/Desktop/productos.csv` (625 productos del catálogo de
ECO BAR / fc3065c8) en el negocio **528df61f**. Se corrió en producción el
2026-09-05 y el dueño avisó enseguida que ese no era el catálogo del negocio.

Se movieron aquí para que nadie los vuelva a correr por error. No se borran
porque `build_products_import_528df61f.py` los regenera tal cual si algún día
hicieran falta.

**Lo que sí se usa está un nivel arriba, en `scripts/`:**

- `ROLLBACK_import_528df61f.sql` — deshace esta carga (sigue afuera a propósito).
- `IMPORT_ecodome_528df61f.sql` + `AREAS_ecodome_528df61f.sql` — el catálogo
  bueno (EcoDome Village, 42 productos, export de Loyverse).
