ALTER TABLE public.cuentas_cobranza
  ADD COLUMN IF NOT EXISTS url_factura_xml_comision TEXT NULL;
