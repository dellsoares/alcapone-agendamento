import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const permissionKeys = [
  'agenda', 'agendamento_manual', 'bloqueios', 'expediente', 'servicos',
  'profissionais', 'cupons', 'vip', 'clientes',
] as const;
const validRoles = ['MASTER', 'GERENTE', 'RECEPCAO', 'BARBEIRO', 'PERSONALIZADO'];

type Json = Record<string, unknown>;

function response(body: Json, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function cleanPermissions(value: unknown) {
  const source = value && typeof value === 'object' ? value as Record<string, unknown> : {};
  return Object.fromEntries(permissionKeys.map((key) => [key, source[key] === true]));
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return response({ error: 'Método não permitido.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) {
    return response({ error: 'A função não está configurada. Verifique SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY nos secrets.' }, 500);
  }

  const authHeader = req.headers.get('Authorization') || '';
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!token) return response({ error: 'Sessão não identificada. Entre novamente no painel.' }, 401);

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const actor = authData?.user;
  if (authError || !actor) return response({ error: 'Sessão inválida ou expirada.' }, 401);

  const { data: actorProfile, error: actorError } = await admin
    .from('administradores')
    .select('usuario_id,perfil,ativo')
    .eq('usuario_id', actor.id)
    .maybeSingle();

  if (actorError || !actorProfile || actorProfile.ativo !== true || actorProfile.perfil !== 'MASTER') {
    return response({ error: 'Somente um usuário MASTER ativo pode administrar colaboradores.' }, 403);
  }

  let body: Json;
  try {
    body = await req.json();
  } catch {
    return response({ error: 'Corpo da solicitação inválido.' }, 400);
  }

  const action = String(body.action || '');
  const targetId = String(body.id || '');

  try {
    if (action === 'create') {
      const nome = String(body.nome || '').trim();
      const email = String(body.email || '').trim().toLowerCase();
      const password = String(body.password || '');
      const perfil = String(body.perfil || 'RECEPCAO');
      const permissoes = cleanPermissions(body.permissoes);
      const profissionalId = body.profissional_id ? String(body.profissional_id) : null;

      if (nome.length < 2 || nome.length > 100) return response({ error: 'Informe um nome válido.' }, 400);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return response({ error: 'Informe um e-mail válido.' }, 400);
      if (password.length < 8) return response({ error: 'A senha inicial precisa ter pelo menos 8 caracteres.' }, 400);
      if (!validRoles.includes(perfil)) return response({ error: 'Perfil de acesso inválido.' }, 400);
      if (perfil === 'BARBEIRO' && !profissionalId) return response({ error: 'Selecione o profissional vinculado ao acesso.' }, 400);
      if (perfil === 'MASTER') {
        for (const key of permissionKeys) permissoes[key] = true;
      } else if (!Object.values(permissoes).some((enabled) => enabled === true)) {
        return response({ error: 'Marque pelo menos uma permissão para este colaborador.' }, 400);
      }

      const { data: created, error: createError } = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        user_metadata: { name: nome, full_name: nome },
      });
      if (createError || !created.user) return response({ error: createError?.message || 'Não foi possível criar a conta.' }, 400);

      const { error: profileError } = await admin.from('administradores').insert({
        usuario_id: created.user.id,
        nome,
        email,
        perfil,
        permissoes,
        ativo: true,
        profissional_id: profissionalId,
      });

      if (profileError) {
        await admin.auth.admin.deleteUser(created.user.id);
        return response({ error: profileError.message }, 400);
      }
      return response({ ok: true, id: created.user.id, message: 'Colaborador criado.' });
    }

    if (action === 'update') {
      if (!targetId) return response({ error: 'Colaborador não identificado.' }, 400);
      const { data: target, error: targetError } = await admin
        .from('administradores')
        .select('usuario_id,nome,email,perfil,permissoes,ativo,profissional_id')
        .eq('usuario_id', targetId)
        .maybeSingle();
      if (targetError || !target) return response({ error: 'Colaborador não encontrado.' }, 404);

      const nome = body.nome === undefined ? target.nome : String(body.nome).trim();
      const email = body.email === undefined ? target.email : String(body.email).trim().toLowerCase();
      const perfil = body.perfil === undefined ? target.perfil : String(body.perfil);
      const ativo = body.ativo === undefined ? target.ativo : body.ativo === true;
      const permissoes = body.permissoes === undefined ? target.permissoes : cleanPermissions(body.permissoes);
      const profissionalId = body.profissional_id === undefined ? target.profissional_id : (body.profissional_id ? String(body.profissional_id) : null);
      const password = body.password === undefined ? '' : String(body.password);

      if (nome.length < 2 || nome.length > 100) return response({ error: 'Informe um nome válido.' }, 400);
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return response({ error: 'Informe um e-mail válido.' }, 400);
      if (!validRoles.includes(perfil)) return response({ error: 'Perfil de acesso inválido.' }, 400);
      if (password && password.length < 8) return response({ error: 'A nova senha precisa ter pelo menos 8 caracteres.' }, 400);
      if (perfil === 'BARBEIRO' && !profissionalId) return response({ error: 'Selecione o profissional vinculado ao acesso.' }, 400);
      if (perfil === 'MASTER') {
        for (const key of permissionKeys) permissoes[key] = true;
      } else if (!Object.values(permissoes).some((enabled) => enabled === true)) {
        return response({ error: 'Marque pelo menos uma permissão para este colaborador.' }, 400);
      }

      const removingMaster = target.perfil === 'MASTER' && (perfil !== 'MASTER' || !ativo);
      if (removingMaster) {
        const { count, error: countError } = await admin.from('administradores').select('usuario_id', { count: 'exact', head: true }).eq('perfil', 'MASTER').eq('ativo', true);
        if (countError) return response({ error: countError.message }, 500);
        if ((count || 0) <= 1) return response({ error: 'O sistema precisa manter pelo menos um MASTER ativo.' }, 400);
      }
      if (targetId === actor.id && (!ativo || perfil !== 'MASTER')) {
        return response({ error: 'Por segurança, não é permitido bloquear ou retirar o perfil MASTER do próprio acesso.' }, 400);
      }

      const authUpdate: { email?: string; email_confirm?: boolean; password?: string; user_metadata: Record<string, string> } = { user_metadata: { name: nome, full_name: nome } };
      if (email !== target.email) {
        authUpdate.email = email;
        authUpdate.email_confirm = true;
      }
      if (password) authUpdate.password = password;
      const { error: authUpdateError } = await admin.auth.admin.updateUserById(targetId, authUpdate);
      if (authUpdateError) return response({ error: authUpdateError.message }, 400);

      const { error: profileUpdateError } = await admin.from('administradores').update({
        nome, email, perfil, permissoes, ativo, profissional_id: profissionalId, atualizado_em: new Date().toISOString(),
      }).eq('usuario_id', targetId);
      if (profileUpdateError) return response({ error: profileUpdateError.message }, 400);
      return response({ ok: true, message: 'Colaborador atualizado.' });
    }

    if (action === 'delete') {
      if (!targetId) return response({ error: 'Colaborador não identificado.' }, 400);
      if (targetId === actor.id) return response({ error: 'Você não pode excluir o próprio acesso enquanto está conectado.' }, 400);
      const { data: target, error: targetError } = await admin
        .from('administradores')
        .select('usuario_id,nome,email,perfil,permissoes,ativo,profissional_id')
        .eq('usuario_id', targetId)
        .maybeSingle();
      if (targetError || !target) return response({ error: 'Colaborador não encontrado.' }, 404);
      if (target.perfil === 'MASTER' && target.ativo) {
        const { count, error: countError } = await admin.from('administradores').select('usuario_id', { count: 'exact', head: true }).eq('perfil', 'MASTER').eq('ativo', true);
        if (countError) return response({ error: countError.message }, 500);
        if ((count || 0) <= 1) return response({ error: 'Não é possível excluir o último MASTER ativo.' }, 400);
      }

      const { error: profileDeleteError } = await admin.from('administradores').delete().eq('usuario_id', targetId);
      if (profileDeleteError) return response({ error: profileDeleteError.message }, 400);
      const { error: authDeleteError } = await admin.auth.admin.deleteUser(targetId);
      if (authDeleteError) {
        await admin.from('administradores').insert(target);
        return response({ error: authDeleteError.message }, 400);
      }
      return response({ ok: true, message: 'Conta e perfil do colaborador excluídos.' });
    }

    return response({ error: 'Ação não reconhecida.' }, 400);
  } catch (error) {
    return response({ error: error instanceof Error ? error.message : 'Erro inesperado.' }, 500);
  }
});
