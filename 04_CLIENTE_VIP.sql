-- AL CAPONE | CLIENTES VIP, HORARIOS EXCLUSIVOS, FIDELIDADE E RESGATES
-- Execute UMA VEZ no SQL Editor do Supabase, DEPOIS de 01, 02 e 03.
-- O acesso VIP usa código individual + WhatsApp cadastrado. Não requer API do WhatsApp.

create or replace function public.alcapone_normalizar_whatsapp(p_whatsapp text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when char_length(regexp_replace(coalesce(p_whatsapp,''), '[^0-9]', '', 'g')) in (12,13)
      and left(regexp_replace(coalesce(p_whatsapp,''), '[^0-9]', '', 'g'),2)='55'
    then substr(regexp_replace(coalesce(p_whatsapp,''), '[^0-9]', '', 'g'),3)
    else regexp_replace(coalesce(p_whatsapp,''), '[^0-9]', '', 'g')
  end;
$$;

create table if not exists public.alcapone_clientes_vip (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(trim(nome)) between 2 and 100),
  whatsapp text not null,
  whatsapp_normalizado text not null unique check (whatsapp_normalizado ~ '^[0-9]{10,11}$'),
  codigo text not null unique check (codigo ~ '^[A-Z0-9_-]{6,30}$'),
  desconto_tipo text not null default 'nenhum' check (desconto_tipo in ('nenhum','percentual','fixo')),
  desconto_valor numeric(10,2) not null default 0 check (desconto_valor >= 0),
  ativo boolean not null default true,
  observacoes text,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint alcapone_vip_desconto_valido check (
    (desconto_tipo='nenhum' and desconto_valor=0)
    or (desconto_tipo='percentual' and desconto_valor between 0.01 and 100)
    or (desconto_tipo='fixo' and desconto_valor > 0)
  )
);

create table if not exists public.alcapone_vip_horarios (
  id uuid primary key default gen_random_uuid(),
  profissional_id uuid not null references public.profissionais(id) on delete cascade,
  data date not null,
  hora_inicio time not null,
  hora_fim time not null,
  descricao text,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  constraint alcapone_vip_horario_intervalo check (hora_fim > hora_inicio)
);
create index if not exists alcapone_vip_horarios_busca_idx
  on public.alcapone_vip_horarios(profissional_id,data,ativo);

create table if not exists public.alcapone_vip_ofertas (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (char_length(trim(titulo)) between 2 and 100),
  descricao text not null check (char_length(trim(descricao)) between 2 and 500),
  tipo text not null default 'promocao' check (tipo in ('promocao','combo')),
  servico_id uuid references public.servicos(id) on delete set null,
  desconto_tipo text not null default 'nenhum' check (desconto_tipo in ('nenhum','percentual','fixo')),
  desconto_valor numeric(10,2) not null default 0 check (desconto_valor >= 0),
  data_inicio date not null,
  data_fim date not null,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  constraint alcapone_vip_oferta_periodo check (data_fim >= data_inicio),
  constraint alcapone_vip_oferta_desconto check (
    (desconto_tipo='nenhum' and desconto_valor=0)
    or (desconto_tipo='percentual' and desconto_valor between 0.01 and 100)
    or (desconto_tipo='fixo' and desconto_valor > 0)
  )
);

create table if not exists public.alcapone_vip_pontos_config (
  id boolean primary key default true check (id=true),
  pontos_por_real numeric(8,2) not null default 1 check (pontos_por_real between 0.01 and 1000),
  atualizado_em timestamptz not null default now()
);
insert into public.alcapone_vip_pontos_config(id,pontos_por_real)
values (true,1)
on conflict (id) do nothing;

create table if not exists public.alcapone_vip_recompensas (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(trim(nome)) between 2 and 100),
  descricao text,
  pontos_necessarios integer not null check (pontos_necessarios > 0),
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);

create table if not exists public.alcapone_vip_resgates (
  id uuid primary key default gen_random_uuid(),
  cliente_vip_id uuid not null references public.alcapone_clientes_vip(id) on delete restrict,
  recompensa_id uuid not null references public.alcapone_vip_recompensas(id) on delete restrict,
  pontos_necessarios integer not null check (pontos_necessarios > 0),
  status text not null default 'solicitado' check (status in ('solicitado','aprovado','entregue','cancelado')),
  solicitado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists alcapone_vip_resgates_cliente_idx
  on public.alcapone_vip_resgates(cliente_vip_id,status);

create table if not exists public.alcapone_vip_pontos (
  id uuid primary key default gen_random_uuid(),
  cliente_vip_id uuid not null references public.alcapone_clientes_vip(id) on delete restrict,
  reserva_id uuid references public.reservas(id) on delete cascade,
  resgate_id uuid references public.alcapone_vip_resgates(id) on delete restrict,
  tipo text not null check (tipo in ('credito_atendimento','debito_resgate','ajuste')),
  pontos integer not null check (pontos <> 0),
  descricao text,
  criado_em timestamptz not null default now(),
  constraint alcapone_vip_pontos_origem check (
    (tipo='credito_atendimento' and reserva_id is not null and resgate_id is null and pontos > 0)
    or (tipo='debito_resgate' and resgate_id is not null and reserva_id is null and pontos < 0)
    or (tipo='ajuste' and reserva_id is null and resgate_id is null)
  )
);
create unique index if not exists alcapone_vip_pontos_reserva_unico
  on public.alcapone_vip_pontos(reserva_id,tipo) where reserva_id is not null;
create unique index if not exists alcapone_vip_pontos_resgate_unico
  on public.alcapone_vip_pontos(resgate_id,tipo) where resgate_id is not null;

alter table public.reservas
  add column if not exists cliente_vip_id uuid references public.alcapone_clientes_vip(id) on delete set null,
  add column if not exists vip_codigo text,
  add column if not exists vip_desconto numeric(10,2) not null default 0;

-- Atualização de datas e normalização de cadastro VIP.
create or replace function public.alcapone_atualizar_cliente_vip()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.nome := trim(new.nome);
  new.whatsapp_normalizado := public.alcapone_normalizar_whatsapp(new.whatsapp);
  new.codigo := upper(trim(new.codigo));
  new.atualizado_em := now();
  if char_length(new.whatsapp_normalizado) not between 10 and 11 then
    raise exception 'Informe um WhatsApp com DDD válido.';
  end if;
  return new;
end;
$$;
drop trigger if exists alcapone_vip_cliente_atualizado on public.alcapone_clientes_vip;
create trigger alcapone_vip_cliente_atualizado
before insert or update on public.alcapone_clientes_vip
for each row execute function public.alcapone_atualizar_cliente_vip();

create or replace function public.alcapone_atualizar_resgate_vip()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status in ('entregue','cancelado') and new.status is distinct from old.status then
    raise exception 'Este resgate já foi finalizado e não pode ser alterado.';
  end if;
  new.atualizado_em := now();
  if new.status='entregue' and old.status is distinct from 'entregue' then
    insert into public.alcapone_vip_pontos(cliente_vip_id,resgate_id,tipo,pontos,descricao)
    values (new.cliente_vip_id,new.id,'debito_resgate',-new.pontos_necessarios,'Resgate de recompensa concluído')
    on conflict (resgate_id,tipo) where resgate_id is not null do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists alcapone_vip_resgate_atualizado on public.alcapone_vip_resgates;
create trigger alcapone_vip_resgate_atualizado
before update on public.alcapone_vip_resgates
for each row execute function public.alcapone_atualizar_resgate_vip();

-- Pontos são creditados uma única vez, somente quando o atendimento vira CONCLUÍDO.
create or replace function public.alcapone_creditar_pontos_atendimento_vip()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_valor numeric(10,2);
  v_taxa numeric(8,2);
  v_pontos integer;
begin
  if new.status='concluido' and old.status is distinct from 'concluido' and new.cliente_vip_id is not null then
    select coalesce(new.valor_final,s.preco) into v_valor
    from public.servicos s where s.id=new.servico_id;
    select c.pontos_por_real into v_taxa from public.alcapone_vip_pontos_config c where c.id=true;
    v_pontos := greatest(0,round(coalesce(v_valor,0)*coalesce(v_taxa,1))::integer);
    if v_pontos > 0 then
      insert into public.alcapone_vip_pontos(cliente_vip_id,reserva_id,tipo,pontos,descricao)
      values (new.cliente_vip_id,new.id,'credito_atendimento',v_pontos,'Pontos pelo atendimento concluído')
      on conflict (reserva_id,tipo) where reserva_id is not null do nothing;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists alcapone_vip_pontos_apos_atendimento on public.reservas;
create trigger alcapone_vip_pontos_apos_atendimento
after update of status on public.reservas
for each row execute function public.alcapone_creditar_pontos_atendimento_vip();

-- Segurança: todas as tabelas ficam privadas; o painel consulta via sessão de administrador.
-- O cliente final só utiliza as funções públicas abaixo.
do $$
declare t text;
begin
  foreach t in array array[
    'alcapone_clientes_vip','alcapone_vip_horarios','alcapone_vip_ofertas',
    'alcapone_vip_pontos_config','alcapone_vip_recompensas',
    'alcapone_vip_resgates','alcapone_vip_pontos'
  ] loop
    execute format('alter table public.%I enable row level security',t);
    execute format('revoke all on public.%I from anon, authenticated',t);
  end loop;
end $$;

grant select,insert,update,delete on public.alcapone_clientes_vip to authenticated;
grant select,insert,update,delete on public.alcapone_vip_horarios to authenticated;
grant select,insert,update,delete on public.alcapone_vip_ofertas to authenticated;
grant select,insert,update on public.alcapone_vip_pontos_config to authenticated;
grant select,insert,update,delete on public.alcapone_vip_recompensas to authenticated;
grant select,update on public.alcapone_vip_resgates to authenticated;
grant select on public.alcapone_vip_pontos to authenticated;

drop policy if exists "admin_gerenciar_clientes_vip" on public.alcapone_clientes_vip;
create policy "admin_gerenciar_clientes_vip" on public.alcapone_clientes_vip
for all to authenticated using (public.alcapone_eh_admin()) with check (public.alcapone_eh_admin());
drop policy if exists "admin_gerenciar_horarios_vip" on public.alcapone_vip_horarios;
create policy "admin_gerenciar_horarios_vip" on public.alcapone_vip_horarios
for all to authenticated using (public.alcapone_eh_admin()) with check (public.alcapone_eh_admin());
drop policy if exists "admin_gerenciar_ofertas_vip" on public.alcapone_vip_ofertas;
create policy "admin_gerenciar_ofertas_vip" on public.alcapone_vip_ofertas
for all to authenticated using (public.alcapone_eh_admin()) with check (public.alcapone_eh_admin());
drop policy if exists "admin_gerenciar_config_pontos_vip" on public.alcapone_vip_pontos_config;
create policy "admin_gerenciar_config_pontos_vip" on public.alcapone_vip_pontos_config
for all to authenticated using (public.alcapone_eh_admin()) with check (public.alcapone_eh_admin());
drop policy if exists "admin_gerenciar_recompensas_vip" on public.alcapone_vip_recompensas;
create policy "admin_gerenciar_recompensas_vip" on public.alcapone_vip_recompensas
for all to authenticated using (public.alcapone_eh_admin()) with check (public.alcapone_eh_admin());
drop policy if exists "admin_consultar_resgates_vip" on public.alcapone_vip_resgates;
create policy "admin_consultar_resgates_vip" on public.alcapone_vip_resgates
for select to authenticated using (public.alcapone_eh_admin());
drop policy if exists "admin_atualizar_resgates_vip" on public.alcapone_vip_resgates;
create policy "admin_atualizar_resgates_vip" on public.alcapone_vip_resgates
for update to authenticated using (public.alcapone_eh_admin()) with check (public.alcapone_eh_admin());
drop policy if exists "admin_consultar_pontos_vip" on public.alcapone_vip_pontos;
create policy "admin_consultar_pontos_vip" on public.alcapone_vip_pontos
for select to authenticated using (public.alcapone_eh_admin());

-- Validação do código VIP + WhatsApp. Não expõe a lista de clientes.
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
    'valid',true,'client_name',v_cliente.nome,
    'code',v_cliente.codigo,'discount_type',v_cliente.desconto_tipo,
    'discount_value',v_cliente.desconto_valor,
    'points_balance',v_saldo,'points_reserved',v_reservado,
    'points_available',greatest(v_saldo-v_reservado,0),
    'offers',v_ofertas,'rewards',v_recompensas,
    'message','Acesso VIP liberado.'
  );
end;
$$;

-- Solicitação de resgate: reserva os pontos até a administração concluir ou cancelar.
create or replace function public.alcapone_vip_solicitar_resgate(
  p_codigo text,p_whatsapp text,p_recompensa_id uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_cliente public.alcapone_clientes_vip%rowtype;
  v_recompensa public.alcapone_vip_recompensas%rowtype;
  v_saldo integer;
  v_reservado integer;
  v_resgate_id uuid;
begin
  select * into v_cliente from public.alcapone_clientes_vip c
  where c.codigo=upper(trim(coalesce(p_codigo,'')))
    and c.whatsapp_normalizado=public.alcapone_normalizar_whatsapp(p_whatsapp)
    and c.ativo=true;
  if not found then raise exception 'Código VIP ou WhatsApp inválido.'; end if;

  perform pg_advisory_xact_lock(hashtext(v_cliente.id::text));
  select * into v_recompensa from public.alcapone_vip_recompensas rw
  where rw.id=p_recompensa_id and rw.ativo=true;
  if not found then raise exception 'Esta recompensa não está disponível.'; end if;

  select coalesce(sum(p.pontos),0)::integer into v_saldo
  from public.alcapone_vip_pontos p where p.cliente_vip_id=v_cliente.id;
  select coalesce(sum(r.pontos_necessarios),0)::integer into v_reservado
  from public.alcapone_vip_resgates r
  where r.cliente_vip_id=v_cliente.id and r.status in ('solicitado','aprovado');
  if v_saldo-v_reservado < v_recompensa.pontos_necessarios then
    raise exception 'Você ainda não tem pontos disponíveis para esta recompensa.';
  end if;

  insert into public.alcapone_vip_resgates(cliente_vip_id,recompensa_id,pontos_necessarios)
  values (v_cliente.id,v_recompensa.id,v_recompensa.pontos_necessarios)
  returning id into v_resgate_id;
  return jsonb_build_object('success',true,'id',v_resgate_id,'message','Solicitação enviada. A equipe da Al Capone confirmará o resgate.');
end;
$$;

-- Disponibilidade padrão + horários extras reservados aos clientes VIP.
drop function if exists public.alcapone_disponibilidade(uuid,uuid,date);
create or replace function public.alcapone_disponibilidade(
  p_profissional_id uuid,
  p_servico_id uuid,
  p_data date,
  p_codigo_vip text default null,
  p_whatsapp text default null
)
returns table(hora text,vip_exclusivo boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_duracao integer;
  v_cliente_vip_id uuid;
begin
  if p_data is null
     or p_data < (now() at time zone 'America/Sao_Paulo')::date
     or p_data > (now() at time zone 'America/Sao_Paulo')::date + 60 then
    return;
  end if;
  if not exists (select 1 from public.profissionais p where p.id=p_profissional_id and p.ativo) then return; end if;
  select s.duracao_minutos into v_duracao
  from public.servicos s where s.id=p_servico_id and s.ativo;
  if v_duracao is null then return; end if;

  if nullif(trim(coalesce(p_codigo_vip,'')),'') is not null then
    select c.id into v_cliente_vip_id from public.alcapone_clientes_vip c
    where c.codigo=upper(trim(p_codigo_vip))
      and c.whatsapp_normalizado=public.alcapone_normalizar_whatsapp(p_whatsapp)
      and c.ativo=true;
  end if;

  return query
  with candidatos as (
    select g.hora_local,false as vip_exclusivo
    from public.horarios_semanais hs
    cross join lateral generate_series(
      p_data + hs.inicio,
      p_data + hs.fim - make_interval(mins=>v_duracao),
      interval '15 minutes'
    ) g(hora_local)
    where hs.profissional_id=p_profissional_id
      and hs.dia_semana=extract(dow from p_data)::integer

    union all

    select g.hora_local,true as vip_exclusivo
    from public.alcapone_vip_horarios vh
    cross join lateral generate_series(
      p_data + vh.hora_inicio,
      p_data + vh.hora_fim - make_interval(mins=>v_duracao),
      interval '15 minutes'
    ) g(hora_local)
    where v_cliente_vip_id is not null
      and vh.profissional_id=p_profissional_id
      and vh.data=p_data
      and vh.ativo=true
  ), livres as (
    select c.hora_local,bool_and(c.vip_exclusivo) as vip_exclusivo
    from candidatos c
    where (c.hora_local at time zone 'America/Sao_Paulo') >= now() + interval '30 minutes'
      and not exists (
        select 1 from public.reservas r
        where r.profissional_id=p_profissional_id and r.status='confirmado'
          and tstzrange(r.inicio,r.fim,'[)') && tstzrange(
            c.hora_local at time zone 'America/Sao_Paulo',
            (c.hora_local at time zone 'America/Sao_Paulo') + make_interval(mins=>v_duracao),'[)')
      )
      and not exists (
        select 1 from public.bloqueios b
        where b.profissional_id=p_profissional_id
          and tstzrange(b.inicio,b.fim,'[)') && tstzrange(
            c.hora_local at time zone 'America/Sao_Paulo',
            (c.hora_local at time zone 'America/Sao_Paulo') + make_interval(mins=>v_duracao),'[)')
      )
    group by c.hora_local
  )
  select to_char(l.hora_local,'HH24:MI'),l.vip_exclusivo
  from livres l
  order by 1;
end;
$$;

-- Substitui a função com cupom por uma versão que também valida VIP e registra a origem do desconto.
-- O parâmetro VIP é opcional; agendamentos manuais antigos continuam funcionando com 9 argumentos.
drop function if exists public.alcapone_agendar(uuid,uuid,date,text,text,text,text,text,text);
create or replace function public.alcapone_agendar(
  p_profissional_id uuid,
  p_servico_id uuid,
  p_data date,
  p_hora text,
  p_nome text,
  p_whatsapp text,
  p_email text,
  p_observacoes text,
  p_cupom text,
  p_codigo_vip text default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_campanha public.alcapone_campanhas_cupom%rowtype;
  v_cliente public.alcapone_clientes_vip%rowtype;
  v_whatsapp text;
  v_usos integer;
  v_usos_cliente integer;
  v_duracao integer;
  v_nome_servico text;
  v_nome_profissional text;
  v_preco numeric(10,2);
  v_cupom_desconto numeric(10,2) := 0;
  v_vip_desconto numeric(10,2) := 0;
  v_desconto numeric(10,2) := 0;
  v_final numeric(10,2);
  v_fonte text := 'nenhum';
  v_inicio timestamptz;
  v_id uuid;
  v_token uuid;
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  if p_nome is null or char_length(trim(p_nome)) < 3 or char_length(trim(p_nome)) > 100 then
    raise exception 'Informe seu nome completo.';
  end if;
  v_whatsapp := public.alcapone_normalizar_whatsapp(p_whatsapp);
  if char_length(v_whatsapp) not between 10 and 11 then raise exception 'Informe seu WhatsApp com DDD.'; end if;
  if p_hora is null or p_hora !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Horário inválido.'; end if;
  if char_length(coalesce(p_email,'')) > 150 or char_length(coalesce(p_observacoes,'')) > 400 then raise exception 'Texto muito longo.'; end if;

  perform pg_advisory_xact_lock(hashtext(p_profissional_id::text));
  select s.preco,s.duracao_minutos,s.nome into v_preco,v_duracao,v_nome_servico
  from public.servicos s where s.id=p_servico_id and s.ativo=true;
  if v_preco is null then raise exception 'Serviço indisponível. Atualize a página e tente novamente.'; end if;
  select p.nome into v_nome_profissional from public.profissionais p where p.id=p_profissional_id and p.ativo=true;
  if v_nome_profissional is null then raise exception 'Profissional indisponível.'; end if;

  if nullif(trim(coalesce(p_codigo_vip,'')),'') is not null then
    select * into v_cliente from public.alcapone_clientes_vip c
    where c.codigo=upper(trim(p_codigo_vip)) and c.whatsapp_normalizado=v_whatsapp and c.ativo=true;
    if not found then raise exception 'Código VIP ou WhatsApp inválido. Confira seus dados.'; end if;
    if v_cliente.desconto_tipo='percentual' then
      v_vip_desconto := round(v_preco*v_cliente.desconto_valor/100,2);
    elsif v_cliente.desconto_tipo='fixo' then
      v_vip_desconto := least(v_preco,v_cliente.desconto_valor);
    end if;
    select greatest(v_vip_desconto,coalesce(max(
      case when o.desconto_tipo='percentual' then round(v_preco*o.desconto_valor/100,2)
           when o.desconto_tipo='fixo' then least(v_preco,o.desconto_valor)
           else 0 end
    ),0)) into v_vip_desconto
    from public.alcapone_vip_ofertas o
    where o.ativo=true and o.tipo='promocao' and v_hoje between o.data_inicio and o.data_fim
      and (o.servico_id is null or o.servico_id=p_servico_id);
  end if;

  if nullif(trim(coalesce(p_cupom,'')),'') is not null then
    select * into v_campanha from public.alcapone_campanhas_cupom c
    where c.codigo=upper(trim(p_cupom)) for update;
    if not found or not v_campanha.ativo then raise exception 'Cupom não encontrado ou indisponível.'; end if;
    if v_hoje < v_campanha.data_inicio or v_hoje > v_campanha.data_fim then raise exception 'Este cupom está fora do período da campanha.'; end if;
    select count(*)::integer into v_usos from public.alcapone_cupons_utilizados u where u.campanha_id=v_campanha.id;
    if v_usos >= v_campanha.max_utilizacoes then raise exception 'Este cupom atingiu o limite de utilizações.'; end if;
    select count(*)::integer into v_usos_cliente from public.alcapone_cupons_utilizados u
    where u.campanha_id=v_campanha.id and u.cliente_whatsapp_normalizado=v_whatsapp;
    if v_usos_cliente >= v_campanha.max_por_cliente then raise exception 'Este cupom já atingiu o limite de uso para seu WhatsApp.'; end if;
    if v_campanha.tipo_desconto='percentual' then v_cupom_desconto:=round(v_preco*v_campanha.valor_desconto/100,2);
    else v_cupom_desconto:=least(v_preco,v_campanha.valor_desconto); end if;
  end if;

  -- Não acumula descontos: aplica o maior benefício entre cupom e VIP.
  if v_vip_desconto >= v_cupom_desconto and v_vip_desconto > 0 then
    v_desconto:=v_vip_desconto;v_fonte:='vip';
  elsif v_cupom_desconto > 0 then
    v_desconto:=v_cupom_desconto;v_fonte:='cupom';
  end if;

  if not exists (
    select 1 from public.alcapone_disponibilidade(p_profissional_id,p_servico_id,p_data,p_codigo_vip,p_whatsapp) d
    where d.hora=p_hora
  ) then raise exception 'Esse horário não está mais disponível. Escolha outro.'; end if;

  v_inicio := (p_data + p_hora::time) at time zone 'America/Sao_Paulo';
  insert into public.reservas(
    profissional_id,servico_id,inicio,fim,cliente_nome,cliente_whatsapp,cliente_email,observacoes,
    cupom_campanha_id,cupom_codigo,desconto,valor_final,cliente_vip_id,vip_codigo,vip_desconto
  ) values (
    p_profissional_id,p_servico_id,v_inicio,v_inicio+make_interval(mins=>v_duracao),trim(p_nome),trim(p_whatsapp),
    nullif(trim(coalesce(p_email,'')),''),nullif(trim(coalesce(p_observacoes,'')),''),
    case when v_fonte='cupom' then v_campanha.id else null end,
    case when v_fonte='cupom' then v_campanha.codigo else null end,
    v_desconto,greatest(v_preco-v_desconto,0),
    case when v_cliente.id is not null then v_cliente.id else null end,
    case when v_cliente.id is not null then v_cliente.codigo else null end,
    case when v_fonte='vip' then v_vip_desconto else 0 end
  ) returning id,token_cliente into v_id,v_token;

  if v_fonte='cupom' then
    insert into public.alcapone_cupons_utilizados(campanha_id,reserva_id,cliente_whatsapp_normalizado,desconto)
    values (v_campanha.id,v_id,v_whatsapp,v_desconto);
  end if;

  return jsonb_build_object(
    'id',v_id,'token',v_token,'code',upper(left(replace(v_id::text,'-',''),8)),
    'service',v_nome_servico,'professional',v_nome_profissional,
    'coupon_code',case when v_fonte='cupom' then v_campanha.codigo else null end,
    'vip_code',case when v_cliente.id is not null then v_cliente.codigo else null end,
    'discount_source',v_fonte,'original_price',v_preco,
    'discount_amount',v_desconto,'vip_discount',case when v_fonte='vip' then v_vip_desconto else 0 end,
    'final_price',greatest(v_preco-v_desconto,0)
  );
exception
  when exclusion_violation then raise exception 'Esse horário acabou de ser reservado. Escolha outro.';
end;
$$;

-- RLS e permissões das funções públicas.
revoke all on function public.alcapone_normalizar_whatsapp(text) from public,anon,authenticated;
revoke all on function public.alcapone_atualizar_cliente_vip() from public,anon,authenticated;
revoke all on function public.alcapone_atualizar_resgate_vip() from public,anon,authenticated;
revoke all on function public.alcapone_creditar_pontos_atendimento_vip() from public,anon,authenticated;
revoke all on function public.alcapone_validar_vip(text,text) from public;
revoke all on function public.alcapone_vip_solicitar_resgate(text,text,uuid) from public;
revoke all on function public.alcapone_disponibilidade(uuid,uuid,date,text,text) from public;
revoke all on function public.alcapone_agendar(uuid,uuid,date,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.alcapone_agendar(uuid,uuid,date,text,text,text,text,text,text,text) from public;
grant execute on function public.alcapone_validar_vip(text,text) to anon,authenticated;
grant execute on function public.alcapone_vip_solicitar_resgate(text,text,uuid) to anon,authenticated;
grant execute on function public.alcapone_disponibilidade(uuid,uuid,date,text,text) to anon,authenticated;
grant execute on function public.alcapone_agendar(uuid,uuid,date,text,text,text,text,text,text,text) to anon,authenticated;

notify pgrst, 'reload schema';
select 'Módulo de Clientes VIP Al Capone instalado com sucesso.' as resultado;
