-- RLS del bucket `facturas`: permitir a authenticated subir/actualizar/leer.
-- Fecha: 2026-06-22
--
-- Bug: "Error al subir la factura" en /admin/agent/comisiones para agentes externos
-- (CC 1769/1773, Daiku u504, Cristóbal Carroll / Vivalta). El bucket facturas tiene RLS
-- en storage.objects SIN policy de INSERT → el agente externo (authenticated) es
-- rechazado; las facturas previas se subieron con service_role (bypassa RLS).
--
-- Fix: policies INSERT/UPDATE/SELECT para authenticated sobre bucket_id='facturas'.
-- Verificado en dev: bucket existe, sin policies de facturas. Idempotente
-- (DROP POLICY IF EXISTS + CREATE).

DROP POLICY IF EXISTS "facturas_insert_authenticated" ON storage.objects;
CREATE POLICY "facturas_insert_authenticated"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (bucket_id = 'facturas');

DROP POLICY IF EXISTS "facturas_update_authenticated" ON storage.objects;
CREATE POLICY "facturas_update_authenticated"
ON storage.objects FOR UPDATE TO authenticated
USING (bucket_id = 'facturas')
WITH CHECK (bucket_id = 'facturas');

DROP POLICY IF EXISTS "facturas_select_authenticated" ON storage.objects;
CREATE POLICY "facturas_select_authenticated"
ON storage.objects FOR SELECT TO authenticated
USING (bucket_id = 'facturas');
