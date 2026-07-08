-- Housekeeping Portal Cobranza: eliminar RPCs viejas ya sin uso.
--
-- El front migró a los RPCs nuevos (get_pcobranza_inmuebles, get_pcobranza_complementos,
-- get_pcobranza_cuentas_cobranza, get_relacion_pagos), desplegados y verificados
-- idénticos en dev y prod. Ningún componente del front invoca las viejas (búsqueda front)
-- y ninguna función/vista de la BD las referencia (verificado en pg_proc/pg_views).
--
-- Firmas confirmadas presentes en dev y prod:
--   get_dashboard_cobranza_kpis(integer)
--   get_dashboard_cobranza_kpis(integer, date, date)
--   get_dashboard_cobranza_kpis(integer, date, date, integer[])
--   get_pcobranza_dashboard(integer, date, date, integer[])   -- interina, reemplazada por get_pcobranza_inmuebles

DROP FUNCTION IF EXISTS public.get_dashboard_cobranza_kpis(integer);
DROP FUNCTION IF EXISTS public.get_dashboard_cobranza_kpis(integer, date, date);
DROP FUNCTION IF EXISTS public.get_dashboard_cobranza_kpis(integer, date, date, integer[]);
DROP FUNCTION IF EXISTS public.get_pcobranza_dashboard(integer, date, date, integer[]);
