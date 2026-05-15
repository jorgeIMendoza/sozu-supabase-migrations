-- ============================================================
-- BASELINE TRIGGERS — generado 2026-05-14
-- Extraído de producción (proyecto: tzmhgfjmddkfyffkkmto)
-- 49 triggers en 31 tablas
-- ============================================================

-- ── acuerdos_pago ──────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_actualizar_estatus_propiedad_apartada ON public.acuerdos_pago;
CREATE TRIGGER trg_actualizar_estatus_propiedad_apartada
  AFTER INSERT OR UPDATE ON public.acuerdos_pago
  FOR EACH ROW EXECUTE FUNCTION actualizar_estatus_propiedad_apartada();

DROP TRIGGER IF EXISTS trg_check_sold_status_on_payment ON public.acuerdos_pago;
CREATE TRIGGER trg_check_sold_status_on_payment
  AFTER UPDATE ON public.acuerdos_pago
  FOR EACH ROW EXECUTE FUNCTION trigger_check_property_sold_status();

DROP TRIGGER IF EXISTS trg_verificar_propiedad_vendida_pago ON public.acuerdos_pago;
CREATE TRIGGER trg_verificar_propiedad_vendida_pago
  AFTER UPDATE ON public.acuerdos_pago
  FOR EACH ROW EXECUTE FUNCTION verificar_propiedad_vendida();

DROP TRIGGER IF EXISTS trigger_ajustar_acuerdo_update ON public.acuerdos_pago;
CREATE TRIGGER trigger_ajustar_acuerdo_update
  AFTER UPDATE ON public.acuerdos_pago
  FOR EACH ROW EXECUTE FUNCTION ajustar_ultimo_acuerdo_pago();

DROP TRIGGER IF EXISTS trigger_verificar_venta_pago ON public.acuerdos_pago;
CREATE TRIGGER trigger_verificar_venta_pago
  AFTER INSERT OR UPDATE ON public.acuerdos_pago
  FOR EACH ROW EXECUTE FUNCTION verificar_propiedad_vendida();

DROP TRIGGER IF EXISTS update_acuerdos_pago_updated_at ON public.acuerdos_pago;
CREATE TRIGGER update_acuerdos_pago_updated_at
  BEFORE UPDATE ON public.acuerdos_pago
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── amenidades_proyectos ───────────────────────────────────

DROP TRIGGER IF EXISTS update_amenidades_proyectos_updated_at ON public.amenidades_proyectos;
CREATE TRIGGER update_amenidades_proyectos_updated_at
  BEFORE UPDATE ON public.amenidades_proyectos
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── aplicaciones_pago ──────────────────────────────────────

DROP TRIGGER IF EXISTS trigger_actualizar_estatus_propiedad_pagada ON public.aplicaciones_pago;
CREATE TRIGGER trigger_actualizar_estatus_propiedad_pagada
  AFTER INSERT OR UPDATE ON public.aplicaciones_pago
  FOR EACH ROW EXECUTE FUNCTION actualizar_estatus_propiedad_pagada();

DROP TRIGGER IF EXISTS trigger_verificar_multa_completada ON public.aplicaciones_pago;
CREATE TRIGGER trigger_verificar_multa_completada
  AFTER INSERT ON public.aplicaciones_pago
  FOR EACH ROW EXECUTE FUNCTION verificar_multa_completada();

DROP TRIGGER IF EXISTS update_aplicaciones_pago_updated_at ON public.aplicaciones_pago;
CREATE TRIGGER update_aplicaciones_pago_updated_at
  BEFORE UPDATE ON public.aplicaciones_pago
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── aviso_triggers_fuentes ─────────────────────────────────

DROP TRIGGER IF EXISTS trg_aviso_triggers_fuentes_updated ON public.aviso_triggers_fuentes;
CREATE TRIGGER trg_aviso_triggers_fuentes_updated
  BEFORE UPDATE ON public.aviso_triggers_fuentes
  FOR EACH ROW EXECUTE FUNCTION tg_set_aviso_evento_updated();

-- ── avisos ─────────────────────────────────────────────────

DROP TRIGGER IF EXISTS update_avisos_updated_at ON public.avisos;
CREATE TRIGGER update_avisos_updated_at
  BEFORE UPDATE ON public.avisos
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── avisos_legales ─────────────────────────────────────────

DROP TRIGGER IF EXISTS update_avisos_legales_updated_at ON public.avisos_legales;
CREATE TRIGGER update_avisos_legales_updated_at
  BEFORE UPDATE ON public.avisos_legales
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── avisos_proyectos ───────────────────────────────────────

DROP TRIGGER IF EXISTS update_avisos_proyectos_updated_at ON public.avisos_proyectos;
CREATE TRIGGER update_avisos_proyectos_updated_at
  BEFORE UPDATE ON public.avisos_proyectos
  FOR EACH ROW EXECUTE FUNCTION set_avisos_proyectos_updated_at();

-- ── avisos_triggers_evento ─────────────────────────────────

DROP TRIGGER IF EXISTS trg_avisos_triggers_evento_updated ON public.avisos_triggers_evento;
CREATE TRIGGER trg_avisos_triggers_evento_updated
  BEFORE UPDATE ON public.avisos_triggers_evento
  FOR EACH ROW EXECUTE FUNCTION tg_set_aviso_evento_updated();

-- ── bancos ─────────────────────────────────────────────────

DROP TRIGGER IF EXISTS update_bancos_updated_at ON public.bancos;
CREATE TRIGGER update_bancos_updated_at
  BEFORE UPDATE ON public.bancos
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── compradores ────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_agregar_conyuge_como_comprador ON public.compradores;
CREATE TRIGGER trg_agregar_conyuge_como_comprador
  AFTER INSERT ON public.compradores
  FOR EACH ROW EXECUTE FUNCTION agregar_conyuge_como_comprador();

DROP TRIGGER IF EXISTS trigger_agregar_conyuge_comprador ON public.compradores;
CREATE TRIGGER trigger_agregar_conyuge_comprador
  AFTER INSERT OR UPDATE ON public.compradores
  FOR EACH ROW EXECUTE FUNCTION agregar_conyuge_como_comprador();

DROP TRIGGER IF EXISTS trigger_create_client_user_on_comprador ON public.compradores;
CREATE TRIGGER trigger_create_client_user_on_comprador
  AFTER INSERT ON public.compradores
  FOR EACH ROW EXECUTE FUNCTION create_client_user_on_comprador_insert();

DROP TRIGGER IF EXISTS update_compradores_updated_at ON public.compradores;
CREATE TRIGGER update_compradores_updated_at
  BEFORE UPDATE ON public.compradores
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── configuracion_citas_horarios ───────────────────────────

DROP TRIGGER IF EXISTS update_configuracion_citas_horarios_updated_at ON public.configuracion_citas_horarios;
CREATE TRIGGER update_configuracion_citas_horarios_updated_at
  BEFORE UPDATE ON public.configuracion_citas_horarios
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── cuentas_cobranza ───────────────────────────────────────

DROP TRIGGER IF EXISTS trigger_actualizar_estatus_escrituracion ON public.cuentas_cobranza;
CREATE TRIGGER trigger_actualizar_estatus_escrituracion
  AFTER UPDATE ON public.cuentas_cobranza
  FOR EACH ROW EXECUTE FUNCTION actualizar_estatus_a_escrituracion();

DROP TRIGGER IF EXISTS update_cuentas_cobranza_updated_at ON public.cuentas_cobranza;
CREATE TRIGGER update_cuentas_cobranza_updated_at
  BEFORE UPDATE ON public.cuentas_cobranza
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── documentos ─────────────────────────────────────────────

DROP TRIGGER IF EXISTS after_documento_verificado ON public.documentos;
CREATE TRIGGER after_documento_verificado
  AFTER UPDATE ON public.documentos
  FOR EACH ROW EXECUTE FUNCTION trigger_check_escrituracion();

DROP TRIGGER IF EXISTS on_document_insert_or_update_sat ON public.documentos;
CREATE TRIGGER on_document_insert_or_update_sat
  AFTER INSERT OR UPDATE ON public.documentos
  FOR EACH ROW EXECUTE FUNCTION trigger_document_insert_sat();

DROP TRIGGER IF EXISTS trg_verificar_propiedad_vendida_documento ON public.documentos;
CREATE TRIGGER trg_verificar_propiedad_vendida_documento
  AFTER UPDATE ON public.documentos
  FOR EACH ROW EXECUTE FUNCTION verificar_propiedad_vendida();

-- ── estatus_persona ────────────────────────────────────────

DROP TRIGGER IF EXISTS update_estatus_persona_updated_at ON public.estatus_persona;
CREATE TRIGGER update_estatus_persona_updated_at
  BEFORE UPDATE ON public.estatus_persona
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── estatus_proyecto ───────────────────────────────────────

DROP TRIGGER IF EXISTS update_estatus_proyecto_updated_at ON public.estatus_proyecto;
CREATE TRIGGER update_estatus_proyecto_updated_at
  BEFORE UPDATE ON public.estatus_proyecto
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── firmas_digitales ───────────────────────────────────────

DROP TRIGGER IF EXISTS update_firmas_digitales_updated_at ON public.firmas_digitales;
CREATE TRIGGER update_firmas_digitales_updated_at
  BEFORE UPDATE ON public.firmas_digitales
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── modelos_planos_arquitectonicos ─────────────────────────

DROP TRIGGER IF EXISTS trg_modelos_planos_arquitectonicos_updated_at ON public.modelos_planos_arquitectonicos;
CREATE TRIGGER trg_modelos_planos_arquitectonicos_updated_at
  BEFORE UPDATE ON public.modelos_planos_arquitectonicos
  FOR EACH ROW EXECUTE FUNCTION update_modelos_planos_arquitectonicos_updated_at();

-- ── multimedias_modelo ─────────────────────────────────────

DROP TRIGGER IF EXISTS trigger_single_ubicacion_oferta ON public.multimedias_modelo;
CREATE TRIGGER trigger_single_ubicacion_oferta
  BEFORE INSERT OR UPDATE ON public.multimedias_modelo
  FOR EACH ROW EXECUTE FUNCTION enforce_single_ubicacion_oferta();

-- ── multimedias_propiedad ──────────────────────────────────

DROP TRIGGER IF EXISTS update_multimedias_propiedad_updated_at ON public.multimedias_propiedad;
CREATE TRIGGER update_multimedias_propiedad_updated_at
  BEFORE UPDATE ON public.multimedias_propiedad
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── multimedias_proyecto ───────────────────────────────────

DROP TRIGGER IF EXISTS update_multimedias_proyecto_updated_at ON public.multimedias_proyecto;
CREATE TRIGGER update_multimedias_proyecto_updated_at
  BEFORE UPDATE ON public.multimedias_proyecto
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── ofertas ────────────────────────────────────────────────

DROP TRIGGER IF EXISTS update_ofertas_updated_at ON public.ofertas;
CREATE TRIGGER update_ofertas_updated_at
  BEFORE UPDATE ON public.ofertas
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── pagos ──────────────────────────────────────────────────

DROP TRIGGER IF EXISTS update_pagos_updated_at ON public.pagos;
CREATE TRIGGER update_pagos_updated_at
  BEFORE UPDATE ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── pagos_stp_raw ──────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_insert_datos_cep ON public.pagos_stp_raw;
CREATE TRIGGER trg_insert_datos_cep
  AFTER UPDATE ON public.pagos_stp_raw
  FOR EACH ROW EXECUTE FUNCTION fn_insert_datos_cep();

-- ── personas ───────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_agregar_conyuge_en_todas_cuentas ON public.personas;
CREATE TRIGGER trg_agregar_conyuge_en_todas_cuentas
  AFTER UPDATE ON public.personas
  FOR EACH ROW EXECUTE FUNCTION agregar_conyuge_en_todas_cuentas();

DROP TRIGGER IF EXISTS trigger_deactivate_user_on_agent_delete ON public.personas;
CREATE TRIGGER trigger_deactivate_user_on_agent_delete
  AFTER UPDATE ON public.personas
  FOR EACH ROW EXECUTE FUNCTION deactivate_user_on_agent_delete();

DROP TRIGGER IF EXISTS trigger_personas_agregar_conyuge ON public.personas;
CREATE TRIGGER trigger_personas_agregar_conyuge
  AFTER UPDATE ON public.personas
  FOR EACH ROW EXECUTE FUNCTION agregar_conyuge_en_todas_cuentas();

-- ── productos_servicios ────────────────────────────────────

DROP TRIGGER IF EXISTS update_productos_servicios_updated_at ON public.productos_servicios;
CREATE TRIGGER update_productos_servicios_updated_at
  BEFORE UPDATE ON public.productos_servicios
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── propiedades ────────────────────────────────────────────

DROP TRIGGER IF EXISTS on_property_pagada_completamente ON public.propiedades;
CREATE TRIGGER on_property_pagada_completamente
  AFTER UPDATE ON public.propiedades
  FOR EACH ROW EXECUTE FUNCTION trigger_property_status_sat();

DROP TRIGGER IF EXISTS trigger_actualizar_precio_m2_proyecto ON public.propiedades;
CREATE TRIGGER trigger_actualizar_precio_m2_proyecto
  AFTER UPDATE ON public.propiedades
  FOR EACH ROW EXECUTE FUNCTION actualizar_precio_m2_proyecto();

DROP TRIGGER IF EXISTS update_propiedades_updated_at ON public.propiedades;
CREATE TRIGGER update_propiedades_updated_at
  BEFORE UPDATE ON public.propiedades
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── propiedades_caracteristicas ────────────────────────────

DROP TRIGGER IF EXISTS update_propiedades_caracteristicas_updated_at ON public.propiedades_caracteristicas;
CREATE TRIGGER update_propiedades_caracteristicas_updated_at
  BEFORE UPDATE ON public.propiedades_caracteristicas
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── proyectos_acceso ───────────────────────────────────────

DROP TRIGGER IF EXISTS sync_inmobiliaria_project_access ON public.proyectos_acceso;
CREATE TRIGGER sync_inmobiliaria_project_access
  AFTER INSERT OR UPDATE OR DELETE ON public.proyectos_acceso
  FOR EACH ROW EXECUTE FUNCTION sync_inmobiliaria_project_access();

DROP TRIGGER IF EXISTS trigger_sync_inmobiliaria_project_access ON public.proyectos_acceso;
CREATE TRIGGER trigger_sync_inmobiliaria_project_access
  AFTER INSERT OR UPDATE OR DELETE ON public.proyectos_acceso
  FOR EACH ROW EXECUTE FUNCTION sync_inmobiliaria_project_access();

-- ── reportes ───────────────────────────────────────────────

DROP TRIGGER IF EXISTS update_reportes_updated_at ON public.reportes;
CREATE TRIGGER update_reportes_updated_at
  BEFORE UPDATE ON public.reportes
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── reservas_citas ─────────────────────────────────────────

DROP TRIGGER IF EXISTS update_reservas_citas_updated_at ON public.reservas_citas;
CREATE TRIGGER update_reservas_citas_updated_at
  BEFORE UPDATE ON public.reservas_citas
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- ── user_roles ─────────────────────────────────────────────

DROP TRIGGER IF EXISTS trg_user_roles_normalize ON public.user_roles;
CREATE TRIGGER trg_user_roles_normalize
  BEFORE INSERT OR UPDATE ON public.user_roles
  FOR EACH ROW EXECUTE FUNCTION user_roles_normalize_email();
