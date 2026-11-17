-- AL CAPONE | NÍVEIS VIP, ANIVERSÁRIO E RELACIONAMENTO
-- Execute UMA VEZ no SQL Editor do Supabase, depois de 04_CLIENTE_VIP.sql.
-- A migração é idempotente: pode ser executada novamente sem duplicar colunas ou constraints.

alter table public.alcapone_clientes_vip
  add column if not exists nivel_vip text not null default 'Bronze',
  add column if not exists data_aniversario date;

-- Garante que os níveis cadastrados sejam sempre uma das cinco categorias oficiais.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'alcapone_clientes_vip_nivel_check'
      and conrelid = 'public.alcapone_clientes_vip'::regclass
  ) then
    alter table public.alcapone_clientes_vip
      add constraint alcapone_clientes_vip_nivel_check
      check (nivel_vip in ('Bronze','Prata','Ouro','Platina','Black'));
  end if;
end;
$$;

update public.alcapone_clientes_vip
set nivel_vip = 'Bronze'
where nivel_vip is null or nivel_vip not in ('Bronze','Prata','Ouro','Platina','Black');

alter table public.alcapone_clientes_vip
  alter column nivel_vip set default 'Bronze',
  alter column nivel_vip set not null;

create index if not exists alcapone_clientes_vip_aniversario_idx
  on public.alcapone_clientes_vip (data_aniversario)
  where data_aniversario is not null;

-- Retorna o nível do cliente na validação pública do acesso VIP.
-- Não expõe aniversário, observações internas ou a lista de clientes.
create or replace function public.alcapone_validar_vip(p_codigo text,p_whatsapp text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cliente public.alcapone_clientes_vip%rowtype;
  v_saldo integer;
  v_reservado integer;
  v_ofertas jsonb;
  v_recompensas jsonb;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select * into v_cliente
  from public.alcapone_clientes_vip c
  where c.codigo=upper(trim(coalesce(p_codigo,'')))
    and c.whatsapp_normalizado=public.alcapone_normalizar_whatsapp(p_whatsapp)
    and c.ativo=true;
  if not found then
    return jsonb_build_object('valid',false,'message','Código VIP ou WhatsApp inválido. Confira os dados ou fale com a Al Capone.');
  end if;

  select coalesce(sum(p.pontos),0)::integer into v_saldo
  from public.alcapone_vip_pontos p where p.cliente_vip_id=v_cliente.id;
  select coalesce(sum(r.pontos_necessarios),0)::integer into v_reservado
  from public.alcapone_vip_resgates r
  where r.cliente_vip_id=v_cliente.id and r.status in ('solicitado','aprovado');

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',o.id,'title',o.titulo,'description',o.descricao,'type',o.tipo,'service_id',o.servico_id,
    'discount_type',o.desconto_tipo,'discount_value',o.desconto_valor,
    'start_date',o.data_inicio,'end_date',o.data_fim
  ) order by o.data_inicio,o.titulo),'[]'::jsonb)
  into v_ofertas
  from public.alcapone_vip_ofertas o
  where o.ativo=true and v_hoje between o.data_inicio and o.data_fim;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',rw.id,'name',rw.nome,'description',rw.descricao,
    'points',rw.pontos_necessarios,'can_redeem',(v_saldo-v_reservado)>=rw.pontos_necessarios
  ) order by rw.pontos_necessarios,rw.nome),'[]'::jsonb)
  into v_recompensas
  from public.alcapone_vip_recompensas rw where rw.ativo=true;

  return jsonb_build_object(
    'valid',true,
    'client_name',v_cliente.nome,
    'vip_level',v_cliente.nivel_vip,
    'code',v_cliente.codigo,
    'discount_type',v_cliente.desconto_tipo,
    'discount_value',v_cliente.desconto_valor,
    'points_balance',v_saldo,
    'points_reserved',v_reservado,
    'points_available',greatest(v_saldo-v_reservado,0),
    'offers',v_ofertas,
    'rewards',v_recompensas,
    'message','Acesso VIP liberado.'
  );
end;
$$;

-- A função já possui EXECUTE para anon/authenticated desde a instalação do módulo VIP.
-- CREATE OR REPLACE preserva os privilégios existentes.
notify pgrst, 'reload schema';

select 'Níveis VIP, aniversário e relacionamento instalados com sucesso.' as resultado;
