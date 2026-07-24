-- Pool de contactos del CRM.
-- ANTES: SELECT y UPDATE de crm_leads_atribucion restringidos a
--        admin / can_view_all_prospects() / dueño (id_propietario = auth.uid()).
-- AHORA (pedido por ventas, 2026-07-18):
--   * VER  → todos los autenticados ven el pool completo (SELECT abierto).
--   * EDITAR → solo el DUEÑO, un admin, o si el contacto AÚN no tiene dueño.
-- Idempotente: recrea las policies (DROP IF EXISTS + CREATE).

-- SELECT: pool completo para cualquier autenticado.
DROP POLICY IF EXISTS "crm_leads_atribucion_select" ON public.crm_leads_atribucion;
CREATE POLICY "crm_leads_atribucion_select"
    ON public.crm_leads_atribucion FOR SELECT
    TO authenticated
    USING (true);

-- UPDATE: solo el dueño del lead, un admin, o si el lead no tiene dueño asignado.
DROP POLICY IF EXISTS "crm_leads_atribucion_update" ON public.crm_leads_atribucion;
CREATE POLICY "crm_leads_atribucion_update"
    ON public.crm_leads_atribucion FOR UPDATE
    TO authenticated
    USING (
        is_admin_user()
        OR id_propietario IS NULL
        OR id_propietario = auth.uid()
    )
    WITH CHECK (true);
