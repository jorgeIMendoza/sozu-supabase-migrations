-- Backfill de telefono en destinatarios de avisos (avisos_roles_destinatarios.correos JSON)
-- Fecha: 2026-07-27
--
-- Los destinatarios se guardan como JSON {"destinatarios":[{nombre,email,telefono}]}. Antes del
-- fix de front, al elegir un rol se cargaban sin telefono → enviar-aviso-bulk los mandaba como
-- 'email' y nunca les llegaba WhatsApp. Este backfill rellena el telefono de una pasada.
--
-- Reglas: solo rellena destinatarios con telefono ausente/vacío (los manuales no se tocan). El
-- telefono se resuelve por email desde usuarios.telefono y, si vacío, personas.telefono; se
-- guarda solo dígitos con lada (paises.clave_pais_telefono, +52 default). Si no hay telefono en
-- ninguna tabla, queda cadena vacía (ese destinatario sigue recibiendo solo email).
--
-- Idempotente: solo escribe filas cuyo JSON cambia (IS DISTINCT FROM). Sin BEGIN/COMMIT
-- (CI/CD envuelve en tx). Backfill de datos por ambiente.

WITH tel_base AS (
  SELECT
    lower(trim(u.email)) AS email,
    COALESCE(NULLIF(trim(u.telefono), ''), NULLIF(trim(p.telefono), '')) AS telefono,
    COALESCE(
      NULLIF(trim(u.clave_pais_telefono), ''),
      NULLIF(trim(p.clave_pais_telefono), ''),
      'MX'
    ) AS clave_pais
  FROM public.usuarios u
  LEFT JOIN public.personas p ON p.id = u.id_persona
  WHERE u.email IS NOT NULL
),
tel_wa AS (
  SELECT
    t.email,
    CASE
      WHEN t.telefono IS NULL THEN ''
      WHEN length(regexp_replace(t.telefono, '\D', '', 'g')) = 0 THEN ''
      WHEN length(regexp_replace(t.telefono, '\D', '', 'g')) > 10
        THEN regexp_replace(t.telefono, '\D', '', 'g')
      ELSE regexp_replace(COALESCE(pa.clave_pais_telefono, '+52'), '\D', '', 'g')
           || regexp_replace(t.telefono, '\D', '', 'g')
    END AS telefono_wa
  FROM tel_base t
  LEFT JOIN public.paises pa ON pa.id = t.clave_pais
),
recalculados AS (
  SELECT
    ard.id,
    jsonb_build_object(
      'destinatarios',
      jsonb_agg(
        CASE
          WHEN COALESCE(NULLIF(trim(e.d ->> 'telefono'), ''), '') <> '' THEN e.d
          ELSE e.d || jsonb_build_object('telefono', COALESCE(tw.telefono_wa, ''))
        END
        ORDER BY e.ord
      )
    ) AS correos_nuevos
  FROM public.avisos_roles_destinatarios ard
  CROSS JOIN LATERAL jsonb_array_elements(ard.correos -> 'destinatarios')
    WITH ORDINALITY AS e(d, ord)
  LEFT JOIN tel_wa tw ON tw.email = lower(trim(e.d ->> 'email'))
  WHERE jsonb_typeof(ard.correos -> 'destinatarios') = 'array'
  GROUP BY ard.id
)
UPDATE public.avisos_roles_destinatarios ard
SET correos = r.correos_nuevos
FROM recalculados r
WHERE ard.id = r.id
  AND ard.correos IS DISTINCT FROM r.correos_nuevos;
