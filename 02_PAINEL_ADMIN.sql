-- AL CAPONE | HABILITAR PAINEL ADMINISTRATIVO
-- Execute UMA VEZ no SQL Editor do projeto Supabase.
-- Autoriza somente usuários cadastrados em public.administradores.

create or replace function public.alcapone_eh_admin()
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
  );
$$;

revoke all on function public.alcapone_eh_admin() from public, anon;
grant execute on function public.alcapone_eh_admin() to authenticated;

grant usage on schema public to authenticated;

-- Administradores: cada usuário pode confirmar apenas o próprio cadastro.
grant select on public.administradores to authenticated;
drop policy if exists "admin_ler_proprio_cadastro" on public.administradores;
create policy "admin_ler_proprio_cadastro"
on public.administradores
for select
to authenticated
using (usuario_id = auth.uid());

-- Profissionais
grant select, update on public.profissionais to authenticated;
drop policy if exists "admin_ler_profissionais" on public.profissionais;
create policy "admin_ler_profissionais"
on public.profissionais for select to authenticated
using (public.alcapone_eh_admin());
drop policy if exists "admin_editar_profissionais" on public.profissionais;
create policy "admin_editar_profissionais"
on public.profissionais for update to authenticated
using (public.alcapone_eh_admin())
with check (public.alcapone_eh_admin());

-- Serviços
grant select, update on public.servicos to authenticated;
drop policy if exists "admin_ler_servicos" on public.servicos;
create policy "admin_ler_servicos"
on public.servicos for select to authenticated
using (public.alcapone_eh_admin());
drop policy if exists "admin_editar_servicos" on public.servicos;
create policy "admin_editar_servicos"
on public.servicos for update to authenticated
using (public.alcapone_eh_admin())
with check (public.alcapone_eh_admin());

-- Reservas: leitura e atualização somente por administradores.
grant select, update on public.reservas to authenticated;
drop policy if exists "admin_ler_reservas" on public.reservas;
create policy "admin_ler_reservas"
on public.reservas for select to authenticated
using (public.alcapone_eh_admin());
drop policy if exists "admin_atualizar_reservas" on public.reservas;
create policy "admin_atualizar_reservas"
on public.reservas for update to authenticated
using (public.alcapone_eh_admin())
with check (public.alcapone_eh_admin());

-- Bloqueios
grant select, insert, delete on public.bloqueios to authenticated;
drop policy if exists "admin_ler_bloqueios" on public.bloqueios;
create policy "admin_ler_bloqueios"
on public.bloqueios for select to authenticated
using (public.alcapone_eh_admin());
drop policy if exists "admin_criar_bloqueios" on public.bloqueios;
create policy "admin_criar_bloqueios"
on public.bloqueios for insert to authenticated
with check (public.alcapone_eh_admin());
drop policy if exists "admin_remover_bloqueios" on public.bloqueios;
create policy "admin_remover_bloqueios"
on public.bloqueios for delete to authenticated
using (public.alcapone_eh_admin());

-- Expediente semanal
grant select, insert, update, delete on public.horarios_semanais to authenticated;
drop policy if exists "admin_ler_horarios" on public.horarios_semanais;
create policy "admin_ler_horarios"
on public.horarios_semanais for select to authenticated
using (public.alcapone_eh_admin());
drop policy if exists "admin_criar_horarios" on public.horarios_semanais;
create policy "admin_criar_horarios"
on public.horarios_semanais for insert to authenticated
with check (public.alcapone_eh_admin());
drop policy if exists "admin_editar_horarios" on public.horarios_semanais;
create policy "admin_editar_horarios"
on public.horarios_semanais for update to authenticated
using (public.alcapone_eh_admin())
with check (public.alcapone_eh_admin());
drop policy if exists "admin_remover_horarios" on public.horarios_semanais;
create policy "admin_remover_horarios"
on public.horarios_semanais for delete to authenticated
using (public.alcapone_eh_admin());

select 'Painel administrativo liberado para os usuários cadastrados em public.administradores.' as resultado;
