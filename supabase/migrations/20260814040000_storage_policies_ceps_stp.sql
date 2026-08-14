-- =============================================================================
-- Policies de Storage para el bucket `ceps_stp`
-- =============================================================================
-- URGENTE: bloquea la carga de evidencia de pagos STP en producción.
--
-- Desde el commit cf2f558e el front manda la evidencia de pagos STP / STP-manual (y
-- transferencia con CEP) al bucket `ceps_stp` en lugar del viejo `ceps`. El bucket existe
-- desde el 2026-07-10 y ya tiene 15,401 CEPs, pero todos los escribió el bot con
-- `service_role`, que se salta RLS. Nunca se le crearon policies para usuarios, así que al
-- subir desde el panel sale `new row violates row-level security policy`.
--
-- ─── Verificado read-only el 2026-08-14 en prod (tzmhgfjmddkfyffkkmto) ───────
--
--   Bucket                INSERT  SELECT  UPDATE   public
--   ceps (deprecado)        sí      sí      sí       true
--   evidencias_efectivo     sí      sí      sí       true
--   ceps_stp                NO      NO      NO       true
--
-- Las policies existentes gatean solo por rol (`authenticated`) y `bucket_id`; no verifican
-- permiso de submenú. Se replica ese mismo patrón: divergir aquí dejaría dos criterios de
-- autorización para la misma acción del mismo modal.
--
-- Sin DELETE, porque tampoco lo tienen `ceps` ni `evidencias_efectivo`: el front no borra,
-- reemplaza con `upsert: true`, que necesita INSERT + UPDATE.
--
-- `service_role` no se toca: el bot de CEP sigue escribiendo por fuera de RLS.
-- El bucket sigue público, así que `getPublicUrl` no cambia.
--
-- ─── POR QUÉ VA ENVUELTO EN UN HANDLER ───────────────────────────────────────
-- `storage.objects` es de `supabase_storage_admin`, y el rol con el que corre el CI
-- (`postgres`) NO es miembro de ese rol — verificado en dev y prod, ni por USAGE ni por
-- MEMBER. `CREATE POLICY` exige ser dueño, así que un DROP/CREATE plano aborta con 42501 y
-- tumba el deploy completo.
--
-- Es el mismo precedente de `20260727000000_seguridad_fase0_contencion.sql`, que creó
-- `documentos_list_interno` con este patrón y dejó dicho: "si el rol de migración no es
-- owner se omite con NOTICE → aplicar manual en el dashboard". Esa policy existe hoy en
-- prod porque se aplicó a mano.
--
-- Entonces: si el rol resulta tener privilegio, esta migración crea las tres policies. Si
-- no, avisa con NOTICE y NO rompe el deploy — y hay que crearlas desde
-- Storage → Policies en el dashboard, con el SQL que queda al final de este archivo.
-- =============================================================================

BEGIN;

DO $storage$
BEGIN
  -- Idempotente: si ya existen de un intento previo, se recrean iguales.
  DROP POLICY IF EXISTS ceps_stp_insert_authenticated ON storage.objects;
  DROP POLICY IF EXISTS ceps_stp_select_authenticated ON storage.objects;
  DROP POLICY IF EXISTS ceps_stp_update_authenticated ON storage.objects;

  -- Subir evidencia nueva
  CREATE POLICY ceps_stp_insert_authenticated
    ON storage.objects FOR INSERT TO authenticated
    WITH CHECK (bucket_id = 'ceps_stp'::text);

  -- Leer / listar
  CREATE POLICY ceps_stp_select_authenticated
    ON storage.objects FOR SELECT TO authenticated
    USING (bucket_id = 'ceps_stp'::text);

  -- Reemplazar (el front sube con upsert: true)
  CREATE POLICY ceps_stp_update_authenticated
    ON storage.objects FOR UPDATE TO authenticated
    USING (bucket_id = 'ceps_stp'::text)
    WITH CHECK (bucket_id = 'ceps_stp'::text);

  RAISE NOTICE 'ceps_stp: las tres policies quedaron creadas por la migración.';

EXCEPTION WHEN insufficient_privilege THEN
  RAISE WARNING
    'ceps_stp OMITIDO: % no es dueño de storage.objects (es de supabase_storage_admin). '
    'El SQL para el dashboard está al final de esta migración.',
    current_user;
END;
$storage$;

-- Verificación del estado final. No falla —tumbar el deploy no crearía las policies— pero
-- deja el resultado explícito en el log en vez de dar por hecho que quedaron.
DO $verificar$
DECLARE
  v_n int;
BEGIN
  SELECT count(*) INTO v_n
  FROM pg_policy
  WHERE polrelid = 'storage.objects'::regclass
    AND polname IN ('ceps_stp_insert_authenticated',
                    'ceps_stp_select_authenticated',
                    'ceps_stp_update_authenticated');

  IF v_n = 3 THEN
    RAISE NOTICE 'ceps_stp: las tres policies están en su lugar.';
  ELSE
    RAISE WARNING
      'ceps_stp: solo % de 3 policies existen. La carga de evidencia de pagos STP SIGUE ROTA '
      'en este entorno. Aplicar el SQL del final de esta migración en el SQL Editor del '
      'dashboard (Storage → Policies).', v_n;
  END IF;
END;
$verificar$;

COMMIT;

-- =============================================================================
-- Si la migración lo omitió: correr esto en el SQL Editor del dashboard
-- (ahí la sesión sí tiene privilegio sobre storage.objects)
-- =============================================================================
-- DROP POLICY IF EXISTS ceps_stp_insert_authenticated ON storage.objects;
-- DROP POLICY IF EXISTS ceps_stp_select_authenticated ON storage.objects;
-- DROP POLICY IF EXISTS ceps_stp_update_authenticated ON storage.objects;
--
-- CREATE POLICY ceps_stp_insert_authenticated
--   ON storage.objects FOR INSERT TO authenticated
--   WITH CHECK (bucket_id = 'ceps_stp'::text);
--
-- CREATE POLICY ceps_stp_select_authenticated
--   ON storage.objects FOR SELECT TO authenticated
--   USING (bucket_id = 'ceps_stp'::text);
--
-- CREATE POLICY ceps_stp_update_authenticated
--   ON storage.objects FOR UPDATE TO authenticated
--   USING (bucket_id = 'ceps_stp'::text)
--   WITH CHECK (bucket_id = 'ceps_stp'::text);

-- =============================================================================
-- Validación (read-only)
-- =============================================================================
-- -- Las tres policies, todas de authenticated (a=INSERT, r=SELECT, w=UPDATE)
-- SELECT polname, polcmd,
--        (SELECT array_agg(rolname) FROM pg_roles WHERE oid = ANY(p.polroles)) roles,
--        pg_get_expr(polqual, polrelid)      AS using_expr,
--        pg_get_expr(polwithcheck, polrelid) AS check_expr
-- FROM pg_policy p
-- WHERE p.polrelid = 'storage.objects'::regclass AND polname LIKE 'ceps_stp\_%'
-- ORDER BY polname;
--
-- -- El bucket sigue público (getPublicUrl no se rompe)
-- SELECT id, public FROM storage.buckets WHERE id = 'ceps_stp';
--
-- UAT (desde el panel, porque el INSERT lo hace Storage con el JWT del usuario):
--   1. Pago STP o STP-manual → "Cargar evidencia de pago" → subir un PDF.
--      Antes: new row violates row-level security policy. Después: "Evidencia cargada".
--   2. Subir otro archivo al MISMO pago (prueba el upsert → necesita la policy de UPDATE).
--   3. Repetir con un pago en efectivo: `evidencias_efectivo` no debe cambiar.
--   4. Abrir el archivo desde el ojo / descarga (SELECT + bucket público).
--
--   SELECT name, bucket_id, created_at, owner FROM storage.objects
--   WHERE bucket_id = 'ceps_stp' ORDER BY created_at DESC LIMIT 5;
--   -- el más reciente: ruta {cuentaId}/{pagoId}/{ts}.{ext} y owner = uid del usuario
-- =============================================================================
