-- FASE 1 de la contencion de la exposicion anonima: sustituir el acceso amplio del
-- flujo publico por funciones acotadas a UNA oferta.
--
-- ─── Por que ──────────────────────────────────────────────────────────────────
-- Las paginas publicas (OfferPage, ReservarPage, ApartarDirectoCapturePage y las de
-- apartado) necesitan dos cosas legitimas, y hoy las consiguen leyendo tablas enteras
-- porque `anon` tiene SELECT sobre ellas:
--
--   a) El asesor de la oferta, para mostrar su nombre y telefono de contacto:
--        ofertas  -> select(email_creador) where id = <oferta>
--        usuarios -> select(id_persona)    where email = <ese correo>
--        personas -> select(nombre_legal, telefono, clave_pais_telefono) where id = <id>
--
--   b) Si la oferta ya tiene cuenta de cobranza y su CLABE, para congelar el plan de
--      pagos y mostrarle al comprador a donde transferir:
--        cuentas_cobranza -> select(id, clabe_stp) where id_oferta = <oferta>
--        acuerdos_pago    -> select(id, monto, id_concepto) where id_cuenta_cobranza in (...)
--
-- El dato que se muestra es correcto; el problema es el camino: para leer el telefono de
-- UN asesor hay que poder leer las 5029 filas de `personas`, y para una CLABE, las 1797
-- cuentas de cobranza con todas las demas.
--
-- Estas funciones devuelven exactamente esos campos para la oferta pedida. Con ellas
-- desplegadas y el front migrado, la fase siguiente puede revocar el SELECT de `anon`
-- sobre personas, usuarios, ofertas, cuentas_cobranza y acuerdos_pago.
--
-- SECURITY DEFINER a proposito: leen por debajo de RLS, y por eso cada una filtra por el
-- id de oferta recibido. No aceptan filtros libres ni devuelven listados.
--
-- Idempotente y sin BEGIN/COMMIT.

-- ─── 1. Datos de contacto del asesor de una oferta ────────────────────────────
CREATE OR REPLACE FUNCTION public.get_asesor_publico_oferta(p_oferta_id integer)
RETURNS TABLE(nombre text, telefono text, clave_pais text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT p.nombre_legal::text,
         p.telefono::text,
         p.clave_pais_telefono::text
  FROM public.ofertas  o
  JOIN public.usuarios u ON lower(u.email) = lower(o.email_creador)
  JOIN public.personas p ON p.id = u.id_persona
  WHERE o.id = p_oferta_id
    AND o.activo = true
  LIMIT 1;
$function$;

COMMENT ON FUNCTION public.get_asesor_publico_oferta(integer) IS
  'Nombre y telefono del asesor de UNA oferta, para la pagina publica. Sustituye la '
  'cadena ofertas -> usuarios -> personas que obligaba a dar SELECT anonimo a esas tres '
  'tablas. No expone correo ni ningun otro dato del asesor.';

-- ─── 2. Cuenta de cobranza de una oferta (existencia + CLABE) ─────────────────
-- La CLABE es informacion que el comprador necesita para pagar, asi que se devuelve;
-- lo que se elimina es poder leer las CLABE de todas las demas cuentas.
CREATE OR REPLACE FUNCTION public.get_oferta_cuenta_publica(p_oferta_id integer)
RETURNS TABLE(cuenta_id bigint, clabe_stp text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT cc.id, cc.clabe_stp::text
  FROM public.cuentas_cobranza cc
  JOIN public.ofertas o ON o.id = cc.id_oferta
  WHERE cc.id_oferta = p_oferta_id
    AND cc.activo = true
    AND o.activo  = true
  ORDER BY cc.id
  LIMIT 1;
$function$;

COMMENT ON FUNCTION public.get_oferta_cuenta_publica(integer) IS
  'Primera cuenta de cobranza activa de UNA oferta y su CLABE, para la pagina publica. '
  'Devuelve cero filas si la oferta aun no esta formalizada.';

-- ─── 3. Acuerdos de pago de una oferta (esquema manual) ───────────────────────
CREATE OR REPLACE FUNCTION public.get_oferta_acuerdos_publicos(p_oferta_id integer)
RETURNS TABLE(id integer, monto numeric, id_concepto integer, concepto_nombre text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT ap.id, ap.monto, ap.id_concepto, cp.nombre::text
  FROM public.acuerdos_pago    ap
  JOIN public.cuentas_cobranza cc ON cc.id = ap.id_cuenta_cobranza
  JOIN public.ofertas          o  ON o.id  = cc.id_oferta
  LEFT JOIN public.conceptos_pago cp ON cp.id = ap.id_concepto
  WHERE cc.id_oferta = p_oferta_id
    AND ap.activo = true
    AND cc.activo = true
    AND o.activo  = true
  ORDER BY ap.id;
$function$;

COMMENT ON FUNCTION public.get_oferta_acuerdos_publicos(integer) IS
  'Acuerdos de pago de UNA oferta, con el nombre del concepto ya resuelto. Lo usa la '
  'pagina publica cuando el esquema seleccionado es manual.';

-- ─── Permisos ─────────────────────────────────────────────────────────────────
-- anon las necesita (paginas publicas sin sesion); authenticated tambien, porque las
-- mismas pantallas se abren desde el portal del agente.
REVOKE ALL ON FUNCTION public.get_asesor_publico_oferta(integer)     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_oferta_cuenta_publica(integer)     FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_oferta_acuerdos_publicos(integer)  FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_asesor_publico_oferta(integer)    TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_oferta_cuenta_publica(integer)    TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_oferta_acuerdos_publicos(integer) TO anon, authenticated, service_role;

-- ─── Validacion (post-deploy) ─────────────────────────────────────────────────
-- Con una oferta real y activa <ID>, como anon debe devolver lo mismo que hoy ve el
-- front, y nada mas:
--
--   BEGIN; SET LOCAL ROLE anon;
--   SELECT * FROM public.get_asesor_publico_oferta(<ID>);
--   SELECT * FROM public.get_oferta_cuenta_publica(<ID>);
--   SELECT * FROM public.get_oferta_acuerdos_publicos(<ID>);
--   ROLLBACK;
--
-- Y con un id inexistente deben devolver cero filas, nunca error.
--
-- OJO: esta migracion NO revoca nada todavia. El front sigue funcionando igual que hoy.
-- La revocacion va en la fase 2, y solo despues de que el front use estas funciones.
