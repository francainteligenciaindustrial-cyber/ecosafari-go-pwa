-- =====================================================================
-- ECOSAFARI GO — MIGRAÇÃO "NÍVEL ENTERPRISE"
-- =====================================================================
-- Rode UMA vez no SQL Editor do Supabase, depois de todas as migrações
-- anteriores. Pode ser rodada de novo sem quebrar nada (idempotente).
--
-- O que este arquivo faz:
--   0) CORREÇÃO DE SEGURANÇA: views que vazavam dados para qualquer um
--   1) LGPD: consentimento registrado, exportação de dados, retenção
--   2) Log de auditoria (quem mudou o quê, quando)
--   3) Verificação em duas etapas (2FA) obrigatória para a equipe
--   4) Equipe por pousada (convites para guias/recepção/admins)
--   5) Grupos/redes de pousadas
--   6) Notificações push no app instalado (Web Push)
--   7) Verificação automática do vídeo (transcrição + checagem)
--   8) Relatório mensal para o dono da pousada
-- =====================================================================


-- =====================================================================
-- 0) CORREÇÃO DE SEGURANÇA — VIEWS
-- ---------------------------------------------------------------------
-- No Postgres, uma view criada sem "security_invoker" roda com as
-- permissões de quem a criou (o dono do banco), ignorando o RLS. Na
-- prática, qualquer pessoa com a chave pública do app conseguia ler,
-- por exemplo, os e-mails em platform_returning_guests e os contatos de
-- todas as pousadas em platform_lodge_overview. Isto faz as views
-- respeitarem as mesmas regras das tabelas por baixo delas.
--
-- Exceção proposital: lodge_leaderboard continua pública porque o
-- ranking precisa mostrar o nome e os pontos dos outros hóspedes — e
-- ela só expõe nome e pontos, nada sensível.
-- =====================================================================
do $$
declare v text;
begin
  foreach v in array array[
    'user_coin_summary','lodge_species_popularity','lodge_activity_summary','lodge_top_guests',
    'lodge_plan_features','lodge_coin_audit_log','lodge_coin_economy',
    'platform_lodge_overview','platform_top_lodges_by_posts','platform_top_lodges_by_guests',
    'platform_returning_guests','platform_guests_by_country','platform_species_by_region',
    'platform_coin_circulation','platform_subscribers_summary','platform_cashflow_projection',
    'platform_subscription_revenue','platform_lodges_timeline','platform_churn_risk',
    'platform_conversion_funnel','site_analytics_summary','site_analytics_top_pages','site_analytics_daily'
  ] loop
    if exists (select 1 from pg_views where schemaname = 'public' and viewname = v) then
      execute format('alter view public.%I set (security_invoker = true)', v);
    end if;
  end loop;
end $$;

-- O admin da plataforma precisa ler planos e configurações por baixo das views
-- (plans já é pública). Leitura de site_analytics_events e das demais
-- tabelas pelo admin da plataforma já existe nas migrações anteriores.


-- =====================================================================
-- CONFIGURAÇÕES GERAIS DA PLATAFORMA (chave/valor)
-- =====================================================================
create table if not exists platform_settings (
  key         text primary key,
  value       text not null,
  is_public   boolean not null default false,
  updated_at  timestamptz not null default now()
);
alter table platform_settings enable row level security;
drop policy if exists "platform_settings_public_read" on platform_settings;
create policy "platform_settings_public_read" on platform_settings
  for select using (is_public);

insert into platform_settings (key, value, is_public) values
  ('terms_version',        '2026-10-20', true),
  ('privacy_version',      '2026-10-20', true),
  ('dpo_name',             'Encarregado de Dados EcoSafari Go', true),
  ('dpo_email',            'privacidade@ecosafarigo.com', true),
  ('staff_mfa_required',   'false', true),
  ('retention_analytics_months',   '13', false),
  ('retention_read_alerts_months', '6',  false),
  ('retention_applications_months','6',  false)
on conflict (key) do nothing;

create or replace function setting(p_key text)
returns text language sql stable security definer set search_path = public
as $$ select value from platform_settings where key = p_key $$;


-- =====================================================================
-- 3) 2FA OBRIGATÓRIO PARA A EQUIPE
-- ---------------------------------------------------------------------
-- O Supabase coloca no token de login o nível "aal2" quando a pessoa
-- confirmou o código do app autenticador. Quando a configuração
-- staff_mfa_required = 'true', toda ação de equipe (guia/admin da
-- pousada e admin da plataforma) exige esse nível.
--
-- Vem DESLIGADO de propósito: ative só depois de você mesmo ter
-- cadastrado o 2FA no app (Perfil > Segurança), senão você se tranca
-- fora. Para ativar:
--   update platform_settings set value = 'true' where key = 'staff_mfa_required';
-- =====================================================================
create or replace function mfa_satisfied()
returns boolean language sql stable security definer set search_path = public
as $$
  select auth.uid() is null  -- tarefas do servidor (agendador, Edge Functions)
      or coalesce(setting('staff_mfa_required'), 'false') <> 'true'
      or coalesce(auth.jwt() ->> 'aal', '') = 'aal2';
$$;

-- As duas funções de permissão passam a exigir o 2FA (quando ligado).
create or replace function is_staff_of_lodge(p_lodge_id uuid)
returns boolean language sql security definer stable set search_path = public
as $$
  select exists(
    select 1 from profiles
    where id = auth.uid() and role in ('guide','admin') and lodge_id = p_lodge_id
  ) and mfa_satisfied();
$$;

create or replace function is_platform_admin()
returns boolean language sql security definer stable set search_path = public
as $$
  select exists(select 1 from platform_admins where user_id = auth.uid()) and mfa_satisfied();
$$;

-- Trava de escrita: qualquer escrita feita por uma conta de equipe nas
-- tabelas sensíveis exige o 2FA. Pega todas as funções de admin de uma
-- vez, sem precisar reescrever cada uma.
create or replace function enforce_staff_mfa()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_role user_role; v_is_platform boolean;
begin
  if auth.uid() is null then
    return coalesce(new, old); -- tarefas automáticas / service role
  end if;
  select role into v_role from profiles where id = auth.uid();
  select exists(select 1 from platform_admins where user_id = auth.uid()) into v_is_platform;
  if (v_role in ('guide','admin') or v_is_platform) and not mfa_satisfied() then
    raise exception 'Esta ação exige verificação em duas etapas. Ative o 2FA em Perfil > Segurança e entre de novo.';
  end if;
  return coalesce(new, old);
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['reservations','benefits','lodge_reward_settings','lodges','species','platform_admins','platform_ai_actions_log','platform_settings'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_enforce_staff_mfa on %I', t);
      execute format('create trigger trg_enforce_staff_mfa before insert or update or delete on %I for each row execute function enforce_staff_mfa()', t);
    end if;
  end loop;
end $$;

-- Em avistamentos e vouchers, só a parte que é ação de equipe
-- (aprovar/rejeitar, validar voucher) exige 2FA — hóspede continua
-- publicando e resgatando normalmente.
drop trigger if exists trg_enforce_staff_mfa on sightings;
create trigger trg_enforce_staff_mfa
  before update of status on sightings
  for each row execute function enforce_staff_mfa();

drop trigger if exists trg_enforce_staff_mfa on redemptions;
create trigger trg_enforce_staff_mfa
  before update of used on redemptions
  for each row execute function enforce_staff_mfa();


-- =====================================================================
-- 1) LGPD
-- =====================================================================

-- 1a) Registro de consentimento (quem aceitou, quando, qual versão)
create table if not exists consents (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references profiles(id) on delete cascade,
  document     text not null check (document in ('terms','privacy','analytics')),
  version      text not null,
  accepted     boolean not null default true,
  user_agent   text,
  created_at   timestamptz not null default now()
);
create index if not exists idx_consents_user on consents(user_id, document, created_at desc);
alter table consents enable row level security;
drop policy if exists "consents_select_own" on consents;
create policy "consents_select_own" on consents for select using (user_id = auth.uid() or is_platform_admin());
-- sem policy de insert: só pela função abaixo (garante versão correta)

alter table profiles
  add column if not exists terms_version_accepted text,
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists analytics_consent boolean not null default false;

create or replace function record_consent(p_analytics boolean, p_user_agent text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_terms text := setting('terms_version'); v_priv text := setting('privacy_version');
begin
  if auth.uid() is null then raise exception 'Faça login para aceitar os termos.'; end if;
  insert into consents (user_id, document, version, accepted, user_agent) values
    (auth.uid(), 'terms', v_terms, true, p_user_agent),
    (auth.uid(), 'privacy', v_priv, true, p_user_agent),
    (auth.uid(), 'analytics', v_priv, coalesce(p_analytics,false), p_user_agent);
  update profiles set terms_version_accepted = v_terms, terms_accepted_at = now(),
    analytics_consent = coalesce(p_analytics,false)
  where id = auth.uid();
end;
$$;

create or replace function set_analytics_consent(p_value boolean)
returns void language plpgsql security definer set search_path = public
as $$
begin
  insert into consents (user_id, document, version, accepted) values (auth.uid(), 'analytics', setting('privacy_version'), p_value);
  update profiles set analytics_consent = p_value where id = auth.uid();
end;
$$;

-- 1b) Portabilidade: o titular baixa todos os dados dele (art. 18, LGPD)
create or replace function export_my_data()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Faça login para exportar seus dados.'; end if;
  return jsonb_build_object(
    'gerado_em', now(),
    'perfil', (select to_jsonb(p) from profiles p where p.id = uid),
    'reservas', coalesce((select jsonb_agg(to_jsonb(r) - 'checkin_location') from reservations r where r.user_id = uid), '[]'),
    'avistamentos', coalesce((select jsonb_agg(to_jsonb(s) - 'location') from sightings s where s.user_id = uid), '[]'),
    'comentarios', coalesce((select jsonb_agg(to_jsonb(c)) from sighting_comments c where c.user_id = uid), '[]'),
    'curtidas', coalesce((select jsonb_agg(to_jsonb(l)) from sighting_likes l where l.user_id = uid), '[]'),
    'moedas', coalesce((select jsonb_agg(to_jsonb(t) order by t.created_at) from jaguarcoin_transactions t where t.user_id = uid), '[]'),
    'resgates', coalesce((select jsonb_agg(to_jsonb(x)) from redemptions x where x.user_id = uid), '[]'),
    'alertas', coalesce((select jsonb_agg(to_jsonb(a)) from alerts a where a.user_id = uid), '[]'),
    'conquistas', coalesce((select jsonb_agg(to_jsonb(b)) from user_badges b where b.user_id = uid), '[]'),
    'consentimentos', coalesce((select jsonb_agg(to_jsonb(k) order by k.created_at) from consents k where k.user_id = uid), '[]')
  );
end;
$$;

-- 1c) Retenção: apaga/anonimiza o que não precisa mais ser guardado.
create or replace function apply_data_retention()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare n_events int; n_alerts int; n_apps int;
begin
  n_events := 0;
  if to_regclass('public.site_analytics_events') is not null then
    execute 'delete from site_analytics_events where created_at < now() - ($1 || '' months'')::interval'
      using setting('retention_analytics_months');
    get diagnostics n_events = row_count;
  end if;

  delete from alerts
    where read = true and created_at < now() - (setting('retention_read_alerts_months') || ' months')::interval;
  get diagnostics n_alerts = row_count;

  -- Solicitações de pousada recusadas: mantém o registro, apaga os dados pessoais
  update lodge_applications
    set tax_id = '[removido]', applicant_name = '[removido]',
        applicant_email = '[removido]', applicant_phone = null
    where status = 'rejected' and tax_id <> '[removido]'
      and coalesce(reviewed_at, created_at) < now() - (setting('retention_applications_months') || ' months')::interval;
  get diagnostics n_apps = row_count;

  return jsonb_build_object('eventos_site', n_events, 'alertas_lidos', n_alerts, 'solicitacoes_anonimizadas', n_apps);
end;
$$;
-- Agendar (depois de ativar pg_cron em Database > Extensions):
-- select cron.schedule('lgpd-retention-weekly', '0 4 * * 0', $$select apply_data_retention()$$);


-- =====================================================================
-- 2) LOG DE AUDITORIA
-- =====================================================================
create table if not exists audit_log (
  id          bigint generated always as identity primary key,
  actor_id    uuid,
  actor_email text,
  lodge_id    uuid,
  table_name  text not null,
  action      text not null,
  row_id      text,
  old_data    jsonb,
  new_data    jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists idx_audit_lodge_date on audit_log(lodge_id, created_at desc);
create index if not exists idx_audit_date on audit_log(created_at desc);
alter table audit_log enable row level security;
drop policy if exists "audit_select_lodge_admin_or_platform" on audit_log;
create policy "audit_select_lodge_admin_or_platform" on audit_log
  for select using (
    is_platform_admin()
    or (lodge_id is not null and exists (
      select 1 from profiles where id = auth.uid() and role = 'admin' and lodge_id = audit_log.lodge_id
    ) and mfa_satisfied())
  );
-- sem insert/update/delete: o log é só escrito pelo gatilho e nunca editado

create or replace function audit_row_change()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end;
  v_row jsonb := coalesce(v_new, v_old);
  v_lodge uuid;
begin
  -- não registra updates que não mudaram nada
  if tg_op = 'UPDATE' and v_old = v_new then return new; end if;

  -- não guarda documento pessoal inteiro no log
  v_old := v_old - 'tax_id'; v_new := v_new - 'tax_id';

  v_lodge := case
    when tg_table_name = 'lodges' then (v_row ->> 'id')::uuid
    when v_row ? 'lodge_id' then nullif(v_row ->> 'lodge_id','')::uuid
  end;

  insert into audit_log (actor_id, actor_email, lodge_id, table_name, action, row_id, old_data, new_data)
  values (auth.uid(), (select email from profiles where id = auth.uid()), v_lodge,
          tg_table_name, tg_op, coalesce(v_row ->> 'id', v_row ->> 'lodge_id', v_row ->> 'user_id'), v_old, v_new);
  return coalesce(new, old);
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['lodges','benefits','reservations','lodge_reward_settings','platform_admins','lodge_invites','platform_settings'] loop
    if exists (select 1 from information_schema.tables where table_schema='public' and table_name=t) then
      execute format('drop trigger if exists trg_audit on %I', t);
      execute format('create trigger trg_audit after insert or update or delete on %I for each row execute function audit_row_change()', t);
    end if;
  end loop;
end $$;

-- Avistamentos e vouchers: só as decisões da equipe vão para o log
drop trigger if exists trg_audit on sightings;
create trigger trg_audit after update of status on sightings
  for each row execute function audit_row_change();
drop trigger if exists trg_audit on redemptions;
create trigger trg_audit after update of used on redemptions
  for each row execute function audit_row_change();

-- Perfis: só mudanças de papel/pousada (não registra troca de tema etc.)
create or replace function audit_profile_role_change()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if old.role is distinct from new.role or old.lodge_id is distinct from new.lodge_id then
    insert into audit_log (actor_id, actor_email, lodge_id, table_name, action, row_id, old_data, new_data)
    values (auth.uid(), (select email from profiles where id = auth.uid()), coalesce(new.lodge_id, old.lodge_id),
      'profiles', 'UPDATE', new.id::text,
      jsonb_build_object('role', old.role, 'lodge_id', old.lodge_id, 'email', old.email),
      jsonb_build_object('role', new.role, 'lodge_id', new.lodge_id, 'email', new.email));
  end if;
  return new;
end;
$$;
drop trigger if exists trg_audit_profile_role on profiles;
create trigger trg_audit_profile_role after update on profiles
  for each row execute function audit_profile_role_change();


-- =====================================================================
-- 4) EQUIPE POR POUSADA (convites)
-- ---------------------------------------------------------------------
-- O dono (admin) gera um código de convite para um e-mail, escolhendo
-- o papel: 'guide' (aprova avistamentos e valida vouchers) ou 'admin'
-- (tudo, inclusive convidar outras pessoas). A pessoa cria a conta
-- normalmente no app e digita o código em Perfil > Sou da equipe.
-- =====================================================================
create table if not exists lodge_invites (
  id           uuid primary key default gen_random_uuid(),
  lodge_id     uuid not null references lodges(id) on delete cascade,
  email        text not null,
  role         user_role not null check (role in ('guide','admin')),
  code         text unique not null,
  invited_by   uuid references profiles(id),
  accepted_by  uuid references profiles(id),
  accepted_at  timestamptz,
  revoked_at   timestamptz,
  expires_at   timestamptz not null default now() + interval '7 days',
  created_at   timestamptz not null default now()
);
alter table lodge_invites enable row level security;
drop policy if exists "invites_select_lodge_admin" on lodge_invites;
create policy "invites_select_lodge_admin" on lodge_invites
  for select using (exists (select 1 from profiles where id = auth.uid() and role='admin' and lodge_id = lodge_invites.lodge_id));

drop trigger if exists trg_audit on lodge_invites;
create trigger trg_audit after insert or update or delete on lodge_invites
  for each row execute function audit_row_change();

create or replace function admin_invite_staff(p_email text, p_role text)
returns text language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; v_code text;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' or caller_lodge is null then raise exception 'Apenas o administrador da pousada pode convidar a equipe.'; end if;
  if not mfa_satisfied() then raise exception 'Esta ação exige verificação em duas etapas.'; end if;
  if p_role not in ('guide','admin') then raise exception 'Papel inválido.'; end if;
  if coalesce(trim(p_email),'') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido.'; end if;

  loop
    v_code := 'EQP-' || upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (select 1 from lodge_invites where code = v_code);
  end loop;

  insert into lodge_invites (lodge_id, email, role, code, invited_by)
    values (caller_lodge, lower(trim(p_email)), p_role::user_role, v_code, auth.uid());
  return v_code;
end;
$$;

create or replace function accept_staff_invite(p_code text)
returns json language plpgsql security definer set search_path = public
as $$
declare v_inv lodge_invites%rowtype; v_email text; v_lodge_name text;
begin
  select email into v_email from profiles where id = auth.uid();
  select * into v_inv from lodge_invites where code = upper(trim(p_code));
  if v_inv.id is null then raise exception 'Convite não encontrado.'; end if;
  if v_inv.revoked_at is not null then raise exception 'Este convite foi cancelado.'; end if;
  if v_inv.accepted_at is not null then raise exception 'Este convite já foi usado.'; end if;
  if v_inv.expires_at < now() then raise exception 'Este convite expirou. Peça um novo ao administrador.'; end if;
  if lower(coalesce(v_email,'')) <> v_inv.email then
    raise exception 'Este convite foi enviado para outro e-mail (%). Entre com a conta desse e-mail.', v_inv.email;
  end if;

  update profiles set role = v_inv.role, lodge_id = v_inv.lodge_id, verified_guest = true where id = auth.uid();
  update lodge_invites set accepted_by = auth.uid(), accepted_at = now() where id = v_inv.id;
  select name into v_lodge_name from lodges where id = v_inv.lodge_id;
  return json_build_object('lodge_name', v_lodge_name, 'role', v_inv.role);
end;
$$;

create or replace function admin_list_staff()
returns table (user_id uuid, full_name text, email text, role user_role)
language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid;
begin
  select p.role, p.lodge_id into caller_role, caller_lodge from profiles p where p.id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas o administrador da pousada pode ver a equipe.'; end if;
  return query select p.id, p.full_name, p.email, p.role from profiles p
    where p.lodge_id = caller_lodge and p.role in ('guide','admin') order by p.role, p.full_name;
end;
$$;

create or replace function admin_remove_staff(p_user_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; target_lodge uuid; admins_left int;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  select lodge_id into target_lodge from profiles where id = p_user_id;
  if caller_role <> 'admin' or caller_lodge is distinct from target_lodge then
    raise exception 'Apenas o administrador da mesma pousada pode remover alguém da equipe.';
  end if;
  if not mfa_satisfied() then raise exception 'Esta ação exige verificação em duas etapas.'; end if;
  select count(*) into admins_left from profiles where lodge_id = caller_lodge and role = 'admin' and id <> p_user_id;
  if admins_left = 0 then raise exception 'A pousada precisa ter pelo menos um administrador.'; end if;
  update profiles set role = 'guest' where id = p_user_id;
end;
$$;

create or replace function admin_revoke_invite(p_invite_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_lodge uuid;
begin
  select lodge_id into caller_lodge from profiles where id = auth.uid() and role = 'admin';
  update lodge_invites set revoked_at = now() where id = p_invite_id and lodge_id = caller_lodge and accepted_at is null;
end;
$$;


-- =====================================================================
-- 5) GRUPOS / REDES DE POUSADAS
-- ---------------------------------------------------------------------
-- Uma rede (ex.: "Grupo Pantanal") com várias unidades. O dono da rede
-- vê os números de todas juntas. Criado pelo admin da plataforma.
-- =====================================================================
create table if not exists lodge_groups (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  owner_user_id uuid references profiles(id),
  created_at    timestamptz not null default now()
);
alter table lodges add column if not exists group_id uuid references lodge_groups(id) on delete set null;
alter table lodge_groups enable row level security;
drop policy if exists "groups_select_owner_or_platform" on lodge_groups;
create policy "groups_select_owner_or_platform" on lodge_groups
  for select using (owner_user_id = auth.uid() or is_platform_admin());
drop policy if exists "groups_write_platform" on lodge_groups;
create policy "groups_write_platform" on lodge_groups
  for all using (is_platform_admin()) with check (is_platform_admin());

create or replace function my_group_overview()
returns table (lodge_id uuid, lodge_name text, plan_code text, avistamentos bigint, hospedes bigint, checkins_30d bigint, moedas_em_circulacao bigint)
language plpgsql security definer set search_path = public
as $$
begin
  if not mfa_satisfied() then raise exception 'Esta ação exige verificação em duas etapas.'; end if;
  return query
    select l.id, l.name, l.plan_code,
      (select count(*) from sightings s where s.lodge_id = l.id and s.status = 'approved'),
      (select count(distinct r.user_id) from reservations r where r.lodge_id = l.id and r.user_id is not null),
      (select count(*) from reservations r where r.lodge_id = l.id and r.checked_in_at > now() - interval '30 days'),
      (select coalesce(sum(t.amount),0)::bigint from jaguarcoin_transactions t where t.lodge_id = l.id)
    from lodges l
    join lodge_groups g on g.id = l.group_id
    where g.owner_user_id = auth.uid() or is_platform_admin()
    order by l.name;
end;
$$;


-- =====================================================================
-- 6) WEB PUSH (notificação no app instalado na tela inicial)
-- =====================================================================
create table if not exists web_push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  endpoint    text unique not null,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now()
);
alter table web_push_subscriptions enable row level security;
drop policy if exists "webpush_all_own" on web_push_subscriptions;
create policy "webpush_all_own" on web_push_subscriptions
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());


-- =====================================================================
-- 7) VERIFICAÇÃO AUTOMÁTICA DO VÍDEO
-- ---------------------------------------------------------------------
-- A Edge Function verify-video transcreve o áudio e confere se a
-- pessoa disse nome, município e data/hora. O resultado aparece para o
-- guia como uma checagem pronta — a aprovação continua sendo humana.
-- =====================================================================
alter table sightings
  add column if not exists video_url text,
  add column if not exists video_transcript text,
  add column if not exists video_check jsonb,
  add column if not exists video_check_status text not null default 'not_applicable';

create or replace function set_video_check(p_sighting_id uuid, p_transcript text, p_check jsonb, p_status text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  -- chamada apenas pela Edge Function (service role)
  if auth.uid() is not null then raise exception 'Função reservada ao servidor.'; end if;
  update sightings set video_transcript = p_transcript, video_check = p_check, video_check_status = p_status
    where id = p_sighting_id;
end;
$$;
revoke execute on function set_video_check(uuid, text, jsonb, text) from public, anon, authenticated;

create or replace function mark_video_pending()
returns trigger language plpgsql as $$
begin
  if new.video_url is not null then new.video_check_status := 'pending'; end if;
  return new;
end;
$$;
drop trigger if exists trg_mark_video_pending on sightings;
create trigger trg_mark_video_pending before insert on sightings
  for each row execute function mark_video_pending();


-- =====================================================================
-- 8) RELATÓRIO MENSAL DA POUSADA
-- =====================================================================
create or replace function admin_monthly_report(p_month date)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; v_from timestamptz; v_to timestamptz;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas o administrador da pousada pode gerar o relatório.'; end if;
  if not mfa_satisfied() then raise exception 'Esta ação exige verificação em duas etapas.'; end if;
  v_from := date_trunc('month', p_month); v_to := v_from + interval '1 month';

  return jsonb_build_object(
    'pousada', (select name from lodges where id = caller_lodge),
    'mes', to_char(v_from, 'YYYY-MM'),
    'avistamentos_aprovados', (select count(*) from sightings where lodge_id = caller_lodge and status='approved' and created_at >= v_from and created_at < v_to),
    'avistamentos_enviados', (select count(*) from sightings where lodge_id = caller_lodge and created_at >= v_from and created_at < v_to),
    'hospedes_ativos', (select count(distinct user_id) from sightings where lodge_id = caller_lodge and created_at >= v_from and created_at < v_to),
    'checkins', (select count(*) from reservations where lodge_id = caller_lodge and checked_in_at >= v_from and checked_in_at < v_to),
    'especies_raras', (select count(*) from sightings where lodge_id = caller_lodge and is_rare and created_at >= v_from and created_at < v_to),
    'moedas_emitidas', (select coalesce(sum(amount),0) from jaguarcoin_transactions where lodge_id = caller_lodge and amount > 0 and created_at >= v_from and created_at < v_to),
    'moedas_resgatadas', (select coalesce(abs(sum(amount)),0) from jaguarcoin_transactions where lodge_id = caller_lodge and type='redemption' and created_at >= v_from and created_at < v_to),
    'top_especies', coalesce((select jsonb_agg(x) from (
        select species_text as especie, count(*) as total from sightings
        where lodge_id = caller_lodge and status='approved' and created_at >= v_from and created_at < v_to
        group by species_text order by total desc limit 10) x), '[]'),
    'beneficios_resgatados', coalesce((select jsonb_agg(x) from (
        select b.name as beneficio, count(*) as total from redemptions r join benefits b on b.id = r.benefit_id
        where r.lodge_id = caller_lodge and r.created_at >= v_from and r.created_at < v_to
        group by b.name order by total desc) x), '[]'),
    'top_hospedes', coalesce((select jsonb_agg(x) from (
        select p.full_name as hospede, count(*) as avistamentos from sightings s join profiles p on p.id = s.user_id
        where s.lodge_id = caller_lodge and s.status='approved' and s.created_at >= v_from and s.created_at < v_to
        group by p.full_name order by avistamentos desc limit 5) x), '[]')
  );
end;
$$;


-- =====================================================================
-- VERSÃO DO SCHEMA (para saber o que já foi aplicado)
-- =====================================================================
insert into platform_settings (key, value, is_public) values ('schema_version', 'enterprise-2026-10-20', true)
on conflict (key) do update set value = excluded.value, updated_at = now();

-- Funções de manutenção: só o servidor/agendador chama
revoke execute on function apply_data_retention() from public, anon, authenticated;

-- =====================================================================
-- FILA OFFLINE: identificador único por envio, para um reenvio após
-- queda de sinal nunca criar o mesmo avistamento duas vezes
-- =====================================================================
alter table sightings add column if not exists client_id uuid;
create unique index if not exists sightings_client_id_unique on sightings(client_id) where client_id is not null;
