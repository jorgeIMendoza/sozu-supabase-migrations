-- FASE 0 de la contencion de la exposicion anonima de datos.
--
-- ─── El hallazgo ──────────────────────────────────────────────────────────────
-- El rol `anon` — el que usa CUALQUIER peticion hecha con la publishable key, que
-- viaja en el bundle publico del front — puede leer tablas enteras. Verificado
-- contra produccion por HTTP, sin autenticacion de ningun tipo:
--
--   GET /rest/v1/personas          -> 200, 5029 filas (3805 correos, 4866 telefonos, 803 RFC)
--   GET /rest/v1/cuentas_cobranza  -> 200, 1797 filas (1751 CLABE, 1797 precios)
--   GET /rest/v1/documentos        -> 200, 8291 filas
--   GET /rest/v1/propiedades       -> 200, 53941 filas
--   GET /rest/v1/ofertas           -> 200, 2889 filas
--   GET /rest/v1/compradores       -> 200, 1939 filas
--   GET /rest/v1/usuarios          -> 200, 623 filas
--   GET /rest/v1/comisionistas     -> 200, 356 filas
--
-- Dos causas se suman:
--   1. `anon` tiene GRANT de SELECT (y de INSERT/UPDATE/DELETE) sobre estas tablas.
--   2. Las policies no lo frenan. Trece tablas usan el patron
--      `qual: current_socio_bancario_id() IS NULL`, escrito para acotar a los socios
--      bancarios; pero para un anonimo esa funcion devuelve NULL, y `NULL IS NULL` es
--      TRUE, asi que la restriccion actua como pase libre. `personas` es peor: su qual
--      es literalmente `true`.
--
-- La ESCRITURA anonima si esta bloqueada por RLS (comprobado con un UPDATE como `anon`
-- en transaccion revertida: 0 filas). El problema es de lectura.
--
-- ─── Alcance de ESTA migracion ────────────────────────────────────────────────
-- Solo las cuatro tablas que NINGUN codigo publico necesita. Se verifico rastreando
-- los imports en profundidad desde las 27 paginas de `src/pages/public/` (125 archivos
-- alcanzables): ninguno consulta estas tablas.
--
-- Deliberadamente NO se tocan aqui `personas`, `usuarios`, `ofertas`, `cuentas_cobranza`
-- ni `acuerdos_pago`: el flujo publico de oferta/apartado SI las consulta (para resolver
-- el asesor de una oferta y su CLABE de pago) y revocarlas ahora romperia el sitio. Esas
-- van en la fase siguiente, cuando las RPC acotadas esten desplegadas y el front las use.
--
-- Se revoca TODO privilegio, no solo SELECT: `anon` tambien tenia INSERT, UPDATE, DELETE
-- y TRUNCATE concedidos. Hoy los frena RLS, pero no hay razon para dejarlos: si mañana
-- alguien añade una policy permisiva, el GRANT ya estaria puesto.
--
-- Idempotente (REVOKE sobre lo ya revocado no falla) y sin BEGIN/COMMIT.

REVOKE ALL PRIVILEGES ON TABLE public.compradores               FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.comisionistas             FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.documentos                FROM anon;
REVOKE ALL PRIVILEGES ON TABLE public.motivos_no_avance_oferta  FROM anon;

-- Las policies que las abrian dejan de tener efecto para `anon` al no haber GRANT, pero
-- se eliminan las que son EXCLUSIVAS de ese rol para que no queden como trampa. Las
-- policies dirigidas a {public} NO se tocan: ese rol incluye tambien a `authenticated`,
-- y eliminarlas cortaria el acceso legitimo del panel.
DROP POLICY IF EXISTS "Permitir lectura de comisionistas con anon" ON public.comisionistas;

COMMENT ON TABLE public.compradores IS
  'Sin acceso para el rol anon desde 20260806100000: contiene datos de compradores.';
COMMENT ON TABLE public.documentos IS
  'Sin acceso para el rol anon desde 20260806100000. OJO: el BUCKET de storage con el '
  'mismo nombre sigue siendo publico y es un problema aparte (fase 3).';

-- ─── Validacion (post-deploy) ─────────────────────────────────────────────────
-- 1) Desde SQL, estas cuatro deben devolver 0 filas o error de permisos:
--      BEGIN; SET LOCAL ROLE anon;
--      SELECT count(*) FROM public.compradores;   -- esperado: permission denied
--      ROLLBACK;
--
-- 2) Desde fuera, con la publishable key, se espera 401/403 en:
--      curl -s -o /dev/null -w '%{http_code}\n' \
--        -H "apikey: <publishable_key>" \
--        'https://<proyecto>.supabase.co/rest/v1/compradores?select=id&limit=1'
--
-- 3) El sitio publico debe seguir funcionando: abrir una oferta, la pagina de reserva y
--    el flujo de apartado. Ninguno de esos toca las tablas revocadas.
