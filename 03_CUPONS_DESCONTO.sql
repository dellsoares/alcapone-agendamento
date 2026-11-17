-- AL CAPONE | MÓDULO DE CUPONS DE DESCONTO
-- Execute UMA VEZ no SQL Editor do Supabase, depois dos scripts 01 e 02.
-- O painel administrativo gerencia campanhas; o site valida e consome cupons no banco.

create table if not exists public.alcapone_campanhas_cupom (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(trim(nome)) between 2 and 100),
  codigo text not null unique check (codigo ~ '^[A-Z0-9_-]{3,30}$'),
  tipo_desconto text not null check (tipo_desconto in ('percentual','fixo')),
  valor_desconto numeric(10,2) not null check (valor_desconto > 0),
  data_inicio date not null,
  data_fim date not null,
  max_utilizacoes integer not null check (max_utilizacoes > 0),
  max_por_cliente integer not null default 1 check (max_por_cliente > 0),
  ativo boolean not null default true,
  criado_por uuid default auth.uid(),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint alcapone_cupom_periodo_valido check (data_fim >= data_inicio),
  constraint alcapone_cupom_percentual_valido check (tipo_desconto <> 'percentual' or valor_desconto <= 100)
);

create table if not exists public.alcapone_cupons_utilizados (
  id uuid primary key default gen_random_uuid(),
  campanha_id uuid not null references public.alcapone_campanhas_cupom(id) on delete restrict,
  reserva_id uuid not null unique references public.reservas(id) on delete cascade,
  cliente_whatsapp_normalizado text not null,
  desconto numeric(10,2) not null default 0 check (desconto >= 0),
  utilizado_em timestamptz not null default now()
);

create index if not exists alcapone_cupons_utilizados_campanha_idx
  on public.alcapone_cupons_utilizados(campanha_id);
create index if not exists alcapone_cupons_utilizados_cliente_idx
  on public.alcapone_cupons_utilizados(campanha_id, cliente_whatsapp_normalizado);

alter table public.reservas
  add column if not exists cupom_campanha_id uuid references public.alcapone_campanhas_cupom(id) on delete set null,
  add column if not exists cupom_codigo text,
  add column if not exists desconto numeric(10,2) not null default 0,
  add column if not exists valor_final numeric(10,2);

alter table public.alcapone_campanhas_cupom enable row level security;
alter table public.alcapone_cupons_utilizados enable row level security;

revoke all on public.alcapone_campanhas_cupom, public.alcapone_cupons_utilizados from anon, authenticated;
grant select, insert, update on public.alcapone_campanhas_cupom to authenticated;
grant select on public.alcapone_cupons_utilizados to authenticated;

drop policy if exists "admin_gerenciar_campanhas_cupom" on public.alcapone_campanhas_cupom;
create policy "admin_gerenciar_campanhas_cupom"
on public.alcapone_campanhas_cupom
for all to authenticated
using (public.alcapone_eh_admin())
with check (public.alcapone_eh_admin());

drop policy if exists "admin_consultar_cupons_utilizados" on public.alcapone_cupons_utilizados;
create policy "admin_consultar_cupons_utilizados"
on public.alcapone_cupons_utilizados
for select to authenticated
using (public.alcapone_eh_admin());

-- Atualiza a data de alteração sempre que o administrador editar uma campanha.
create or replace function public.alcapone_atualizar_campanha_cupom()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.atualizado_em := now();
  new.codigo := upper(trim(new.codigo));
  return new;
end;
$$;

drop trigger if exists alcapone_campanha_cupom_atualizada on public.alcapone_campanhas_cupom;
create trigger alcapone_campanha_cupom_atualizada
before update on public.alcapone_campanhas_cupom
for each row execute function public.alcapone_atualizar_campanha_cupom();

-- Validação pública: não expõe dados de clientes nem a lista de campanhas.
create or replace function public.alcapone_validar_cupom(
  p_codigo text,
  p_servico_id uuid,
  p_whatsapp text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_campanha public.alcapone_campanhas_cupom%rowtype;
  v_whatsapp text;
  v_usos integer;
  v_usos_cliente integer;
  v_preco numeric(10,2);
  v_desconto numeric(10,2);
  v_final numeric(10,2);
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  v_whatsapp := regexp_replace(coalesce(p_whatsapp,''), '[^0-9]', '', 'g');
  if char_length(v_whatsapp) in (12,13) and left(v_whatsapp,2)='55' then
    v_whatsapp := substr(v_whatsapp,3);
  end if;
  if char_length(v_whatsapp) not between 10 and 11 then
    return jsonb_build_object('valid',false,'message','Informe um WhatsApp com DDD antes de aplicar o cupom.');
  end if;

  select * into v_campanha
  from public.alcapone_campanhas_cupom c
  where c.codigo = upper(trim(coalesce(p_codigo,'')))
    and c.ativo = true;

  if not found then
    return jsonb_build_object('valid',false,'message','Cupom não encontrado ou indisponível.');
  end if;
  if v_hoje < v_campanha.data_inicio or v_hoje > v_campanha.data_fim then
    return jsonb_build_object('valid',false,'message','Este cupom está fora do período da campanha.');
  end if;

  select count(*)::integer into v_usos
  from public.alcapone_cupons_utilizados u where u.campanha_id = v_campanha.id;
  if v_usos >= v_campanha.max_utilizacoes then
    return jsonb_build_object('valid',false,'message','Este cupom atingiu o limite de utilizações.');
  end if;

  select count(*)::integer into v_usos_cliente
  from public.alcapone_cupons_utilizados u
  where u.campanha_id = v_campanha.id
    and u.cliente_whatsapp_normalizado = v_whatsapp;
  if v_usos_cliente >= v_campanha.max_por_cliente then
    return jsonb_build_object('valid',false,'message','Este cupom já atingiu o limite de uso para seu WhatsApp.');
  end if;

  select s.preco into v_preco
  from public.servicos s where s.id = p_servico_id and s.ativo = true;
  if v_preco is null then
    return jsonb_build_object('valid',false,'message','Não foi possível validar o serviço selecionado.');
  end if;

  if v_campanha.tipo_desconto = 'percentual' then
    v_desconto := round(v_preco * v_campanha.valor_desconto / 100, 2);
  else
    v_desconto := least(v_preco, v_campanha.valor_desconto);
  end if;
  v_final := greatest(v_preco - v_desconto, 0);

  return jsonb_build_object(
    'valid',true,
    'code',v_campanha.codigo,
    'campaign_name',v_campanha.nome,
    'discount_type',v_campanha.tipo_desconto,
    'discount_value',v_campanha.valor_desconto,
    'discount_amount',v_desconto,
    'subtotal',v_preco,
    'final_price',v_final,
    'message','Cupom aplicado com sucesso.'
  );
end;
$$;

-- Reserva com cupom. A campanha é bloqueada durante a operação para impedir
-- que duas reservas consumam simultaneamente a última utilização disponível.
-- A função antiga, sem cupom, continua ativa para compatibilidade com reservas manuais.
create or replace function public.alcapone_agendar(
  p_profissional_id uuid,
  p_servico_id uuid,
  p_data date,
  p_hora text,
  p_nome text,
  p_whatsapp text,
  p_email text,
  p_observacoes text,
  p_cupom text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_campanha public.alcapone_campanhas_cupom%rowtype;
  v_whatsapp text;
  v_usos integer;
  v_usos_cliente integer;
  v_preco numeric(10,2);
  v_desconto numeric(10,2) := 0;
  v_final numeric(10,2);
  v_resultado jsonb;
  v_reserva_id uuid;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  select s.preco into v_preco
  from public.servicos s where s.id = p_servico_id and s.ativo = true;
  if v_preco is null then
    raise exception 'Serviço indisponível. Atualize a página e tente novamente.';
  end if;

  v_whatsapp := regexp_replace(coalesce(p_whatsapp,''), '[^0-9]', '', 'g');
  if char_length(v_whatsapp) in (12,13) and left(v_whatsapp,2)='55' then
    v_whatsapp := substr(v_whatsapp,3);
  end if;

  if nullif(trim(coalesce(p_cupom,'')), '') is not null then
    select * into v_campanha
    from public.alcapone_campanhas_cupom c
    where c.codigo = upper(trim(p_cupom))
    for update;

    if not found or not v_campanha.ativo then
      raise exception 'Cupom não encontrado ou indisponível.';
    end if;
    if v_hoje < v_campanha.data_inicio or v_hoje > v_campanha.data_fim then
      raise exception 'Este cupom está fora do período da campanha.';
    end if;

    select count(*)::integer into v_usos
    from public.alcapone_cupons_utilizados u where u.campanha_id = v_campanha.id;
    if v_usos >= v_campanha.max_utilizacoes then
      raise exception 'Este cupom atingiu o limite de utilizações.';
    end if;

    select count(*)::integer into v_usos_cliente
    from public.alcapone_cupons_utilizados u
    where u.campanha_id = v_campanha.id
      and u.cliente_whatsapp_normalizado = v_whatsapp;
    if v_usos_cliente >= v_campanha.max_por_cliente then
      raise exception 'Este cupom já atingiu o limite de uso para seu WhatsApp.';
    end if;

    if v_campanha.tipo_desconto = 'percentual' then
      v_desconto := round(v_preco * v_campanha.valor_desconto / 100, 2);
    else
      v_desconto := least(v_preco, v_campanha.valor_desconto);
    end if;
  end if;

  v_final := greatest(v_preco - v_desconto, 0);

  -- Chama a função atual de reserva; qualquer falha reverte também o consumo do cupom.
  v_resultado := public.alcapone_agendar(
    p_profissional_id,p_servico_id,p_data,p_hora,p_nome,p_whatsapp,p_email,p_observacoes
  );
  v_reserva_id := (v_resultado->>'id')::uuid;

  update public.reservas r
  set cupom_campanha_id = case when v_campanha.id is not null then v_campanha.id else null end,
      cupom_codigo = case when v_campanha.id is not null then v_campanha.codigo else null end,
      desconto = v_desconto,
      valor_final = v_final
  where r.id = v_reserva_id;

  if v_campanha.id is not null then
    insert into public.alcapone_cupons_utilizados(
      campanha_id,reserva_id,cliente_whatsapp_normalizado,desconto
    ) values (v_campanha.id,v_reserva_id,v_whatsapp,v_desconto);
  end if;

  return v_resultado || jsonb_build_object(
    'coupon_code',case when v_campanha.id is not null then v_campanha.codigo else null end,
    'original_price',v_preco,
    'discount_amount',v_desconto,
    'final_price',v_final
  );
end;
$$;

revoke all on function public.alcapone_atualizar_campanha_cupom() from public, anon, authenticated;
revoke all on function public.alcapone_validar_cupom(text,uuid,text) from public;
revoke all on function public.alcapone_agendar(uuid,uuid,date,text,text,text,text,text,text) from public;
grant execute on function public.alcapone_validar_cupom(text,uuid,text) to anon, authenticated;
grant execute on function public.alcapone_agendar(uuid,uuid,date,text,text,text,text,text,text) to anon, authenticated;

select 'Módulo de cupons Al Capone instalado com sucesso.' as resultado;
