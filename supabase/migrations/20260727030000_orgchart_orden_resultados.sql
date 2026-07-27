-- Portal Operación Comercial e Incentivos (menu 35) · mover "Organigrama" a Resultados
-- Fecha: 2026-07-27
--
-- El sidebar (PortalEstructuraComisionesLayout) arma secciones por el centenar de submenus.orden
-- (100=Configuración, 200=Estructura, 300=Simulación, 400=Resultados, 500=Análisis). "Organigrama"
-- (/admin/portal-estructura-comisiones/org-chart) es solo lectura → sección Resultados (orden 405,
-- antes de Financieros=410). En dev ya se movió a mano; en prod seguía en Estructura (200).
-- Esta migración lo formaliza para que llegue a prod por CI/CD.
--
-- El submenu "Directorio de Personal" NO se incluye: ya está migrado en 20260714010000.
-- Idempotente (AND orden <> 405). Sin BEGIN/COMMIT (CI/CD envuelve en tx).

UPDATE public.submenus
SET orden = 405
WHERE menu_id = 35
  AND vista_front_end = '/admin/portal-estructura-comisiones/org-chart'
  AND orden <> 405;
