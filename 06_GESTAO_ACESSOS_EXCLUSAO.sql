-- AL CAPONE | GESTÃO DE COLABORADORES, PERMISSÕES E EXCLUSÃO DE DADOS
-- Execute UMA VEZ depois dos scripts 01 a 05.
-- Os administradores já cadastrados são promovidos a MASTER para preservar
-- o acesso igual dos dois responsáveis atuais da Al Capone.

-- 1) Perfil e permissões dos colaboradores.
alter table public.administradores
  add column if not exists nome text,
  add column if not exists email text,
  add column if not exists perfil text not null default 'MASTER',
  add column if not exists permissoes jsonb not null default '{}'::jsonb,
  add column if not exists ativo boolean not null default true,
  add column if not exists profissional_id uuid references public.profissionais(id) on delete set null,
  add column if not exists criado_em timestamptz not null default now(),
  add column if not exists atualizado_em timestamptz not null default now();

update public.administradores a
set email = coalesce(a.email, u.email),
    nome = coalesce(nullif(a.nome,''), nullif(u.raw_user_meta_data->>'name',''), split_part(coalesce(u.email,''),'@',1)),
    perfil = 'MASTER',
    permissoes = '{"agenda":true,"agendamento_manual":true,"bloqueios":true,"expediente":true,"servicos":true,"profissionais":true,"cupons":true,"vip":true,"clientes":true}'::jsonb,
    atualizado_em = now()
from auth.users u
where u.id = a.usuario_id
  and (a.perfil = 'MASTER' or (a.perfil = 'RECEPCAO' and a.permissoes = '{}'::jsonb));

-- Mantém uma constraint simples e previsível para os perfis suportados.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'administradores_perfil_check'
      and conrelid = 'public.administradores'::regclass
  ) then
    alter table public.administradores
      add constraint administradores_perfil_check
      check (perfil in ('MASTER','GERENTE','RECEPCAO','BARBEIRO','PERSONALIZADO'));
  end if;
end;
$$;

create index if not exists administradores_perfil_ativo_idx
  on public.administradores(perfil, ativo);

-- 2) Funções de autorização. São SECURITY DEFINER para consultar a tabela
-- administrativa sem recursão de RLS.
create or replace function public.alcapone_tem_permissao(p_chave text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.administradores a
    where a.usuario_id = auth.uid()
      and a.ativo = true
      and (
        a.perfil = 'MASTER'
        or coalesce((a.permissoes ->> p_chave)::boolean, false)
      )
  );
$$;

-- Compatibilidade: operações críticas antigas que chamam alcapone_eh_admin()
-- passam a ser exclusivas dos responsáveis MASTER.
create or replace function public.alcapone_eh_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.administradores a
    where a.usuario_id = auth.uid() and a.ativo = true and a.perfil = 'MASTER'
  );
$$;

create or replace function public.alcapone_pode_acessar_profissional(p_profissional_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.administradores a
    where a.usuario_id = auth.uid()
      and a.ativo = true
      and (
        a.perfil <> 'BARBEIRO'
        or a.profissional_id = p_profissional_id
      )
  );
$$;

revoke all on function public.alcapone_tem_permissao(text) from public, anon;
revoke all on function public.alcapone_eh_admin() from public, anon;
revoke all on function public.alcapone_pode_acessar_profissional(uuid) from public, anon;
grant execute on function public.alcapone_tem_permissao(text) to authenticated;
grant execute on function public.alcapone_eh_admin() to authenticated;
grant execute on function public.alcapone_pode_acessar_profissional(uuid) to authenticated;

-- 3) RLS: políticas antigas amplas são substituídas por permissões por módulo.
alter table public.administradores enable row level security;
alter table public.profissionais enable row level security;
alter table public.servicos enable row level security;
alter table public.reservas enable row level security;
alter table public.bloqueios enable row level security;
alter table public.horarios_semanais enable row level security;

-- Administradores: cada colaborador lê o próprio perfil; MASTER lê a equipe.
revoke all on public.administradores from anon, authenticated;
grant select on public.administradores to authenticated;
drop policy if exists "admin_ler_proprio_cadastro" on public.administradores;
drop policy if exists "colaborador_ler_proprio_perfil" on public.administradores;
drop policy if exists "master_ler_equipe" on public.administradores;
create policy "colaborador_ler_proprio_perfil"
on public.administradores for select to authenticated
using (usuario_id = auth.uid() and ativo = true);
create policy "master_ler_equipe"
on public.administradores for select to authenticated
using (public.alcapone_eh_admin());

-- Profissionais: leitura conforme acesso ao profissional; gestão separada.
grant select, insert, update, delete on public.profissionais to authenticated;
drop policy if exists "admin_ler_profissionais" on public.profissionais;
drop policy if exists "equipe_ler_profissionais" on public.profissionais;
drop policy if exists "equipe_gerenciar_profissionais" on public.profissionais;
create policy "equipe_ler_profissionais"
on public.profissionais for select to authenticated
using ((exists(select 1 from public.administradores a where a.usuario_id=auth.uid() and a.ativo=true)) and public.alcapone_pode_acessar_profissional(id));
create policy "equipe_gerenciar_profissionais"
on public.profissionais for all to authenticated
using (public.alcapone_tem_permissao('profissionais') and public.alcapone_pode_acessar_profissional(id))
with check (public.alcapone_tem_permissao('profissionais') and public.alcapone_pode_acessar_profissional(id));

-- Serviços: qualquer usuário autenticado e ativo pode consultar o catálogo;
-- somente quem recebeu a permissão SERVIÇOS pode alterar.
grant select, insert, update, delete on public.servicos to authenticated;
drop policy if exists "admin_ler_servicos" on public.servicos;
drop policy if exists "admin_editar_servicos" on public.servicos;
drop policy if exists "equipe_ler_servicos" on public.servicos;
drop policy if exists "equipe_gerenciar_servicos" on public.servicos;
create policy "equipe_ler_servicos"
on public.servicos for select to authenticated
using (exists(select 1 from public.administradores a where a.usuario_id=auth.uid() and a.ativo=true));
create policy "equipe_gerenciar_servicos"
on public.servicos for all to authenticated
using (public.alcapone_tem_permissao('servicos'))
with check (public.alcapone_tem_permissao('servicos'));

-- Agenda: barbeiros só acessam reservas do profissional associado ao seu login.
grant select, update, delete on public.reservas to authenticated;
drop policy if exists "admin_ler_reservas" on public.reservas;
drop policy if exists "admin_atualizar_reservas" on public.reservas;
drop policy if exists "equipe_ler_reservas" on public.reservas;
drop policy if exists "equipe_atualizar_reservas" on public.reservas;
drop policy if exists "equipe_excluir_reservas" on public.reservas;
create policy "equipe_ler_reservas"
on public.reservas for select to authenticated
using (public.alcapone_tem_permissao('agenda') and public.alcapone_pode_acessar_profissional(profissional_id));
create policy "equipe_atualizar_reservas"
on public.reservas for update to authenticated
using (public.alcapone_tem_permissao('agenda') and public.alcapone_pode_acessar_profissional(profissional_id))
with check (public.alcapone_tem_permissao('agenda') and public.alcapone_pode_acessar_profissional(profissional_id));
create policy "equipe_excluir_reservas"
on public.reservas for delete to authenticated
using (public.alcapone_tem_permissao('agenda') and public.alcapone_pode_acessar_profissional(profissional_id));

-- Bloqueios.
grant select, insert, delete on public.bloqueios to authenticated;
drop policy if exists "admin_ler_bloqueios" on public.bloqueios;
drop policy if exists "admin_criar_bloqueios" on public.bloqueios;
drop policy if exists "admin_remover_bloqueios" on public.bloqueios;
drop policy if exists "equipe_gerenciar_bloqueios" on public.bloqueios;
create policy "equipe_gerenciar_bloqueios"
on public.bloqueios for all to authenticated
using (public.alcapone_tem_permissao('bloqueios') and public.alcapone_pode_acessar_profissional(profissional_id))
with check (public.alcapone_tem_permissao('bloqueios') and public.alcapone_pode_acessar_profissional(profissional_id));

-- Expediente.
grant select, insert, update, delete on public.horarios_semanais to authenticated;
drop policy if exists "admin_ler_horarios" on public.horarios_semanais;
drop policy if exists "admin_criar_horarios" on public.horarios_semanais;
drop policy if exists "admin_editar_horarios" on public.horarios_semanais;
drop policy if exists "admin_remover_horarios" on public.horarios_semanais;
drop policy if exists "equipe_gerenciar_horarios" on public.horarios_semanais;
create policy "equipe_gerenciar_horarios"
on public.horarios_semanais for all to authenticated
using (public.alcapone_tem_permissao('expediente') and public.alcapone_pode_acessar_profissional(profissional_id))
with check (public.alcapone_tem_permissao('expediente') and public.alcapone_pode_acessar_profissional(profissional_id));

-- Cupons.
grant select, insert, update, delete on public.alcapone_campanhas_cupom to authenticated;
grant select on public.alcapone_cupons_utilizados to authenticated;
drop policy if exists "admin_gerenciar_campanhas_cupom" on public.alcapone_campanhas_cupom;
drop policy if exists "admin_consultar_cupons_utilizados" on public.alcapone_cupons_utilizados;
drop policy if exists "equipe_gerenciar_campanhas_cupom" on public.alcapone_campanhas_cupom;
drop policy if exists "equipe_consultar_cupons_utilizados" on public.alcapone_cupons_utilizados;
create policy "equipe_gerenciar_campanhas_cupom"
on public.alcapone_campanhas_cupom for all to authenticated
using (public.alcapone_tem_permissao('cupons'))
with check (public.alcapone_tem_permissao('cupons'));
create policy "equipe_consultar_cupons_utilizados"
on public.alcapone_cupons_utilizados for select to authenticated
using (public.alcapone_tem_permissao('cupons'));

-- VIP e fidelidade.
do $$
declare t text;
begin
  foreach t in array array[
    'alcapone_clientes_vip','alcapone_vip_horarios','alcapone_vip_ofertas',
    'alcapone_vip_pontos_config','alcapone_vip_recompensas',
    'alcapone_vip_resgates','alcapone_vip_pontos'
  ] loop
    execute format('alter table public.%I enable row level security',t);
  end loop;
end;
$$;

grant select, insert, update, delete on public.alcapone_clientes_vip to authenticated;
grant select, insert, update, delete on public.alcapone_vip_horarios to authenticated;
grant select, insert, update, delete on public.alcapone_vip_ofertas to authenticated;
grant select, insert, update, delete on public.alcapone_vip_pontos_config to authenticated;
grant select, insert, update, delete on public.alcapone_vip_recompensas to authenticated;
grant select, update, delete on public.alcapone_vip_resgates to authenticated;
grant select, delete on public.alcapone_vip_pontos to authenticated;

drop policy if exists "admin_gerenciar_clientes_vip" on public.alcapone_clientes_vip;
drop policy if exists "admin_gerenciar_horarios_vip" on public.alcapone_vip_horarios;
drop policy if exists "admin_gerenciar_ofertas_vip" on public.alcapone_vip_ofertas;
drop policy if exists "admin_gerenciar_config_pontos_vip" on public.alcapone_vip_pontos_config;
drop policy if exists "admin_gerenciar_recompensas_vip" on public.alcapone_vip_recompensas;
drop policy if exists "admin_consultar_resgates_vip" on public.alcapone_vip_resgates;
drop policy if exists "admin_atualizar_resgates_vip" on public.alcapone_vip_resgates;
drop policy if exists "admin_consultar_pontos_vip" on public.alcapone_vip_pontos;

drop policy if exists "equipe_gerenciar_clientes_vip" on public.alcapone_clientes_vip;
drop policy if exists "equipe_gerenciar_horarios_vip" on public.alcapone_vip_horarios;
drop policy if exists "equipe_gerenciar_ofertas_vip" on public.alcapone_vip_ofertas;
drop policy if exists "equipe_gerenciar_config_pontos_vip" on public.alcapone_vip_pontos_config;
drop policy if exists "equipe_gerenciar_recompensas_vip" on public.alcapone_vip_recompensas;
drop policy if exists "equipe_gerenciar_resgates_vip" on public.alcapone_vip_resgates;
drop policy if exists "equipe_gerenciar_pontos_vip" on public.alcapone_vip_pontos;

create policy "equipe_gerenciar_clientes_vip" on public.alcapone_clientes_vip
for all to authenticated using (public.alcapone_tem_permissao('vip')) with check (public.alcapone_tem_permissao('vip'));
create policy "equipe_gerenciar_horarios_vip" on public.alcapone_vip_horarios
for all to authenticated using (public.alcapone_tem_permissao('vip') and public.alcapone_pode_acessar_profissional(profissional_id)) with check (public.alcapone_tem_permissao('vip') and public.alcapone_pode_acessar_profissional(profissional_id));
create policy "equipe_gerenciar_ofertas_vip" on public.alcapone_vip_ofertas
for all to authenticated using (public.alcapone_tem_permissao('vip')) with check (public.alcapone_tem_permissao('vip'));
create policy "equipe_gerenciar_config_pontos_vip" on public.alcapone_vip_pontos_config
for all to authenticated using (public.alcapone_tem_permissao('vip')) with check (public.alcapone_tem_permissao('vip'));
create policy "equipe_gerenciar_recompensas_vip" on public.alcapone_vip_recompensas
for all to authenticated using (public.alcapone_tem_permissao('vip')) with check (public.alcapone_tem_permissao('vip'));
create policy "equipe_gerenciar_resgates_vip" on public.alcapone_vip_resgates
for all to authenticated using (public.alcapone_tem_permissao('vip')) with check (public.alcapone_tem_permissao('vip'));
create policy "equipe_gerenciar_pontos_vip" on public.alcapone_vip_pontos
for select to authenticated using (public.alcapone_tem_permissao('vip'));

-- 4) Agendamento manual: RPC separada, para exigir a permissão apropriada.
create or replace function public.alcapone_agendar_manual(
  p_profissional_id uuid,
  p_servico_id uuid,
  p_data date,
  p_hora text,
  p_nome text,
  p_whatsapp text,
  p_email text,
  p_observacoes text,
  p_cupom text,
  p_codigo_vip text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not public.alcapone_tem_permissao('agendamento_manual') then
    raise exception 'Seu usuário não tem permissão para criar agendamentos manuais.';
  end if;
  if not public.alcapone_pode_acessar_profissional(p_profissional_id) then
    raise exception 'Você só pode agendar para o profissional vinculado ao seu acesso.';
  end if;
  return public.alcapone_agendar(
    p_profissional_id,p_servico_id,p_data,p_hora,p_nome,p_whatsapp,
    p_email,p_observacoes,p_cupom,p_codigo_vip
  );
end;
$$;

-- 5) Lista de clientes construída a partir das reservas e dos cadastros VIP.
create or replace function public.alcapone_listar_clientes()
returns table(
  nome text,
  whatsapp text,
  total_reservas bigint,
  ultima_visita timestamptz,
  nivel_vip text,
  cliente_vip boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.alcapone_tem_permissao('clientes') then
    raise exception 'Seu usuário não tem permissão para consultar clientes.';
  end if;
  return query
  with reservas_agg as (
    select public.alcapone_normalizar_whatsapp(r.cliente_whatsapp) as telefone,
           max(r.cliente_nome)::text as nome,
           count(*)::bigint as total,
           max(r.inicio) as ultima
    from public.reservas r
    where r.cliente_whatsapp is not null
      and public.alcapone_normalizar_whatsapp(r.cliente_whatsapp) <> '00000000000'
    group by public.alcapone_normalizar_whatsapp(r.cliente_whatsapp)
  ), vip as (
    select c.whatsapp_normalizado as telefone,c.nome,c.nivel_vip
    from public.alcapone_clientes_vip c
  )
  select coalesce(v.nome,ra.nome), coalesce(v.telefone,ra.telefone),
         coalesce(ra.total,0)::bigint, ra.ultima, v.nivel_vip, (v.telefone is not null)
  from reservas_agg ra
  full outer join vip v on v.telefone=ra.telefone
  order by coalesce(v.nome,ra.nome);
end;
$$;

-- 6) Exclusões protegidas. Dados históricos de reservas são preservados,
-- mas os dados pessoais do cliente são anonimizados quando o cadastro é excluído.
create or replace function public.alcapone_excluir_cliente(p_whatsapp text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_tel text;
  v_vip_id uuid;
  v_reservas integer := 0;
  v_usos integer := 0;
begin
  if not (public.alcapone_tem_permissao('clientes') or public.alcapone_tem_permissao('vip')) then
    raise exception 'Seu usuário não tem permissão para excluir clientes.';
  end if;
  v_tel := public.alcapone_normalizar_whatsapp(p_whatsapp);
  if char_length(v_tel) not between 10 and 11 then
    raise exception 'WhatsApp inválido.';
  end if;

  select c.id into v_vip_id from public.alcapone_clientes_vip c
  where c.whatsapp_normalizado=v_tel limit 1;

  delete from public.alcapone_cupons_utilizados u
  where u.cliente_whatsapp_normalizado=v_tel;
  get diagnostics v_usos = row_count;

  if v_vip_id is not null then
    delete from public.alcapone_vip_pontos p where p.cliente_vip_id=v_vip_id;
    delete from public.alcapone_vip_resgates r where r.cliente_vip_id=v_vip_id;
  end if;

  update public.reservas r
  set cliente_nome='Cliente excluído',
      cliente_whatsapp='00000000000',
      cliente_email=null,
      observacoes=null,
      cliente_vip_id=null,
      vip_codigo=null,
      vip_desconto=0
  where public.alcapone_normalizar_whatsapp(r.cliente_whatsapp)=v_tel;
  get diagnostics v_reservas = row_count;

  if v_vip_id is not null then
    delete from public.alcapone_clientes_vip c where c.id=v_vip_id;
  end if;

  return jsonb_build_object('ok',true,'reservas_anonimizadas',v_reservas,'usos_cupom_removidos',v_usos,'cadastro_vip_excluido',v_vip_id is not null);
end;
$$;

create or replace function public.alcapone_excluir_profissional(p_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not public.alcapone_tem_permissao('profissionais') then raise exception 'Sem permissão para excluir profissionais.'; end if;
  if not public.alcapone_pode_acessar_profissional(p_id) then raise exception 'Você só pode administrar o profissional vinculado ao seu acesso.'; end if;
  if exists(select 1 from public.reservas where profissional_id=p_id)
     or exists(select 1 from public.bloqueios where profissional_id=p_id)
     or exists(select 1 from public.horarios_semanais where profissional_id=p_id)
     or exists(select 1 from public.alcapone_vip_horarios where profissional_id=p_id)
     or exists(select 1 from public.administradores where profissional_id=p_id) then
    raise exception 'Este profissional possui reservas ou horários vinculados. Desative o cadastro para preservar o histórico.';
  end if;
  delete from public.profissionais where id=p_id;
  if not found then raise exception 'Profissional não encontrado.'; end if;
end;
$$;

create or replace function public.alcapone_excluir_servico(p_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not public.alcapone_tem_permissao('servicos') then raise exception 'Sem permissão para excluir serviços.'; end if;
  if exists(select 1 from public.reservas where servico_id=p_id) then
    raise exception 'Este serviço possui reservas vinculadas. Desative-o para preservar o histórico.';
  end if;
  delete from public.servicos where id=p_id;
  if not found then raise exception 'Serviço não encontrado.'; end if;
end;
$$;

create or replace function public.alcapone_excluir_campanha_cupom(p_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not public.alcapone_tem_permissao('cupons') then raise exception 'Sem permissão para excluir campanhas.'; end if;
  if exists(select 1 from public.alcapone_cupons_utilizados where campanha_id=p_id) then
    raise exception 'Esta campanha já possui utilizações. Pause-a para preservar o histórico.';
  end if;
  delete from public.alcapone_campanhas_cupom where id=p_id;
  if not found then raise exception 'Campanha não encontrada.'; end if;
end;
$$;

create or replace function public.alcapone_excluir_recompensa_vip(p_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not public.alcapone_tem_permissao('vip') then raise exception 'Sem permissão para excluir recompensas.'; end if;
  if exists(select 1 from public.alcapone_vip_resgates where recompensa_id=p_id) then
    raise exception 'Esta recompensa possui resgates vinculados. Pause-a para preservar o histórico.';
  end if;
  delete from public.alcapone_vip_recompensas where id=p_id;
  if not found then raise exception 'Recompensa não encontrada.'; end if;
end;
$$;

-- 7) Privilégios das RPCs administrativas.
revoke all on function public.alcapone_agendar_manual(uuid,uuid,date,text,text,text,text,text,text,text) from public, anon;
revoke all on function public.alcapone_listar_clientes() from public, anon;
revoke all on function public.alcapone_excluir_cliente(text) from public, anon;
revoke all on function public.alcapone_excluir_profissional(uuid) from public, anon;
revoke all on function public.alcapone_excluir_servico(uuid) from public, anon;
revoke all on function public.alcapone_excluir_campanha_cupom(uuid) from public, anon;
revoke all on function public.alcapone_excluir_recompensa_vip(uuid) from public, anon;
grant execute on function public.alcapone_agendar_manual(uuid,uuid,date,text,text,text,text,text,text,text) to authenticated;
grant execute on function public.alcapone_listar_clientes() to authenticated;
grant execute on function public.alcapone_excluir_cliente(text) to authenticated;
grant execute on function public.alcapone_excluir_profissional(uuid) to authenticated;
grant execute on function public.alcapone_excluir_servico(uuid) to authenticated;
grant execute on function public.alcapone_excluir_campanha_cupom(uuid) to authenticated;
grant execute on function public.alcapone_excluir_recompensa_vip(uuid) to authenticated;

notify pgrst, 'reload schema';
select 'Gestão de colaboradores, permissões e exclusões instalada.' as resultado;
