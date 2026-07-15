-- 1. Crear la tabla dedicada para el CRM
CREATE TABLE IF NOT EXISTS public.crm_leads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    
    -- Datos del Contacto (HubSpot format)
    full_name TEXT NOT NULL,
    email TEXT,
    phone TEXT,
    lead_status TEXT DEFAULT 'nuevo' NOT NULL, -- nuevo, en_curso, conectado, sin_calificar, etc.
    lifecycle_stage TEXT DEFAULT 'lead' NOT NULL, -- lead, mql, sql, opportunity, customer, evangelist
    contact_owner TEXT, -- ID del asesor asignado
    development_id TEXT, -- ID del proyecto asignado
    
    -- Atribución de Meta Ads y Tráfico
    original_traffic_source TEXT,
    regional_source_detail TEXT,
    first_touchpoint_desc TEXT,
    record_source TEXT,
    first_touchpoint_campaign TEXT,
    first_view_date TIMESTAMP WITH TIME ZONE,
    form_submissions JSONB DEFAULT '[]'::jsonb,
    meta_lead_id TEXT UNIQUE,
    meta_form_name TEXT,
    meta_platform TEXT, -- fb, ig, messenger
    
    activo BOOLEAN DEFAULT true NOT NULL
);

-- 2. Insertar registros seed de prueba
INSERT INTO public.crm_leads (
    full_name,
    email,
    phone,
    lead_status,
    lifecycle_stage,
    contact_owner,
    development_id,
    original_traffic_source,
    regional_source_detail,
    first_touchpoint_desc,
    record_source,
    first_touchpoint_campaign,
    first_view_date,
    form_submissions,
    meta_lead_id,
    meta_form_name,
    meta_platform
) VALUES 
(
    'Juan Pérez (Meta Ads)',
    'juan.perez@example.com',
    '5512345678',
    'nuevo',
    'lead',
    'Tomas Peterson',
    '1', -- ID Proyecto 1
    'Paid Social',
    'Facebook Ads - MX',
    'Hizo click en anuncio de preventa de Departamentos',
    'Meta Ads',
    'campana_preventa_q1_2026',
    NOW() - INTERVAL '3 days',
    '[{"form_name": "Registro Preventa", "submitted_at": "2026-07-11T18:30:00Z", "fields": {"email": "test@example.com", "phone": "5512345678"}}]'::jsonb,
    'meta_lead_111222333',
    'Formulario_Informacion_SOZU',
    'fb'
),
(
    'Ana María Gómez (Web Organic)',
    'ana.gomez@example.com',
    '5587654321',
    'en_curso',
    'mql',
    'Jorge Mendoza',
    '2', -- ID Proyecto 2
    'Organic Search',
    'Google Organic - MX',
    'Buscó departamentos en preventa CDMX',
    'Sitio Web',
    'SEO_Organico_2026',
    NOW() - INTERVAL '5 days',
    '[{"form_name": "Solicitud Informacion", "submitted_at": "2026-07-09T12:00:00Z", "fields": {"email": "ana.gomez@example.com"}}]'::jsonb,
    NULL,
    NULL,
    NULL
);

-- 3. Habilitar RLS
ALTER TABLE public.crm_leads ENABLE ROW LEVEL SECURITY;

-- 4. Definir políticas de seguridad
CREATE POLICY "Permitir lectura a admins, usuarios con permiso global o dueños del lead"
    ON public.crm_leads
    FOR SELECT
    TO authenticated
    USING (
        is_admin_user() 
        OR can_view_all_prospects() 
        OR contact_owner = (SELECT nombre FROM public.usuarios WHERE auth_user_id = auth.uid() AND activo = true LIMIT 1)
    );

CREATE POLICY "Permitir inserción a usuarios autenticados"
    ON public.crm_leads
    FOR INSERT
    TO authenticated
    WITH CHECK (true);

CREATE POLICY "Permitir modificación a admins, usuarios con permiso global o dueños del lead"
    ON public.crm_leads
    FOR UPDATE
    TO authenticated
    USING (
        is_admin_user() 
        OR can_view_all_prospects() 
        OR contact_owner = (SELECT nombre FROM public.usuarios WHERE auth_user_id = auth.uid() AND activo = true LIMIT 1)
    )
    WITH CHECK (
        is_admin_user() 
        OR can_view_all_prospects() 
        OR contact_owner = (SELECT nombre FROM public.usuarios WHERE auth_user_id = auth.uid() AND activo = true LIMIT 1)
    );

CREATE POLICY "Permitir eliminación solo a administradores"
    ON public.crm_leads
    FOR DELETE
    TO authenticated
    USING (is_admin_user());
