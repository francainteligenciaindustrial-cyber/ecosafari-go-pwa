-- =====================================================================
-- ECOSAFARI GO — SCHEMA COMPLETO CONSOLIDADO (do zero) — v2.0 com enterprise
-- =====================================================================
-- Este arquivo reconstrói o banco inteiro, do zero, juntando tudo que
-- foi construído ao longo do projeto (mais de 15 migrações separadas)
-- num único script consistente — pensado para você usar como base ao
-- unificar com o banco do site institucional.
--
-- COMO USAR:
--   1. Rode num banco NOVO/VAZIO (Supabase novo, ou um schema de teste)
--   2. Confirme que tudo rodou sem erro
--   3. Só depois disso, planeje a migração/unificação com o banco do site
--
-- NÃO rode isso por cima de um banco em produção com dados reais — ele
-- assume que as tabelas ainda não existem. Se for aplicar em cima do
-- banco atual, use os arquivos de migração incrementais que já te
-- entreguei antes, não este.
-- =====================================================================


-- =====================================================================
-- 1) EXTENSÕES
-- =====================================================================
create extension if not exists pgcrypto;
create extension if not exists postgis;


-- =====================================================================
-- 2) TIPOS ENUMERADOS
-- =====================================================================
create type user_role as enum ('guest', 'guide', 'admin');
create type sighting_status as enum ('pending', 'approved', 'rejected');
create type coin_transaction_type as enum ('sighting_reward', 'checkin_reward', 'redemption', 'adjustment');
create type report_status as enum ('open', 'reviewed', 'dismissed');
create type moderation_status as enum ('not_applicable', 'pending', 'clear', 'flagged');


-- =====================================================================
-- 3) TABELAS PRINCIPAIS
-- =====================================================================

create table lodges (
  id                        uuid primary key default gen_random_uuid(),
  name                      text not null,
  slug                      text unique not null,
  address                   text,
  location                  geography(point, 4326),
  geofence_radius_meters    integer not null default 500,
  created_at                timestamptz not null default now(),
  -- marca/moeda personalizada (plano Pro/Premium)
  display_name              text,
  logo_url                  text,
  currency_name             text not null default 'JaguarCoin',
  currency_icon             text not null default '🪙',
  conservation_partner      text,
  -- plano de assinatura
  plan_code                 text not null default 'free',
  plan_status               text not null default 'active',
  plan_renews_at            date,
  stripe_customer_id        text,
  stripe_subscription_id    text,
  -- código de check-in compartilhado (Pro/Premium)
  shared_access_code        text unique,
  -- contato e comissão (uso do painel da plataforma)
  contact_email             text,
  contact_phone             text,
  commission_rate           numeric(5,4) not null default 0.10
);

create table profiles (
  id                          uuid primary key references auth.users(id) on delete cascade,
  lodge_id                    uuid references lodges(id) on delete set null,
  full_name                   text,
  email                       text,
  role                        user_role not null default 'guest',
  avatar_url                  text,
  created_at                  timestamptz not null default now(),
  theme_preference             text not null default 'dark' check (theme_preference in ('dark','light')),
  language_preference          text not null default 'pt' check (language_preference in ('pt','en','es','de','fr','ru')),
  verified_guest               boolean not null default false,
  verified_observer            boolean not null default false,
  approved_sightings_count     integer not null default 0,
  rejected_sightings_count     integer not null default 0,
  birth_date                   date,
  nationality                  text
);

create table reservations (
  id                  uuid primary key default gen_random_uuid(),
  lodge_id            uuid not null references lodges(id) on delete cascade,
  user_id             uuid references profiles(id) on delete cascade, -- pode ser nulo até alguém reivindicar o código
  reservation_code    text unique not null,
  check_in_date       date not null,
  check_out_date      date not null,
  checked_in_at       timestamptz,
  checkin_location    geography(point, 4326),
  created_at          timestamptz not null default now(),
  booking_value       numeric(10,2) -- opcional, usado na projeção de caixa da plataforma
);

create table species (
  id                uuid primary key default gen_random_uuid(),
  common_name       text not null,
  scientific_name   text,
  category          text,
  created_at        timestamptz not null default now(),
  lodge_id          uuid references lodges(id) on delete cascade -- nulo = catálogo global
);
create unique index species_common_name_lodge_unique
  on species (common_name, coalesce(lodge_id, '00000000-0000-0000-0000-000000000000'));

create table user_followed_species (
  user_id     uuid not null references profiles(id) on delete cascade,
  species_id  uuid not null references species(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, species_id)
);

create table sightings (
  id                uuid primary key default gen_random_uuid(),
  lodge_id          uuid not null references lodges(id) on delete cascade,
  user_id           uuid references profiles(id) on delete set null, -- preserva o conteúdo se a conta for excluída
  species_id        uuid references species(id),
  species_text      text not null,
  description       text,
  photo_url         text,
  photo_thumb_url   text,
  has_photo         boolean not null default false,
  video_url         text,
  video_thumb_url   text,
  video_trim_start  numeric default 0,
  location          geography(point, 4326), -- mantido por compatibilidade; o app usa as duas colunas abaixo
  location_lat      double precision,
  location_lng      double precision,
  photo_taken_at    timestamptz,
  observed_at       timestamptz default now(), -- momento real do avistamento (mesmo se enviado offline depois)
  status            sighting_status not null default 'pending',
  moderation_status moderation_status not null default 'not_applicable',
  moderation_reason text,
  is_rare           boolean not null default false,
  reviewed_by       uuid references profiles(id),
  reviewed_at       timestamptz,
  likes_count       integer not null default 0,
  created_at        timestamptz not null default now()
);
create index idx_sightings_lodge_status on sightings(lodge_id, status);
create index idx_sightings_species on sightings(species_id);

create table sighting_likes (
  sighting_id  uuid not null references sightings(id) on delete cascade,
  user_id      uuid not null references profiles(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (sighting_id, user_id)
);

create table sighting_comments (
  id           uuid primary key default gen_random_uuid(),
  sighting_id  uuid not null references sightings(id) on delete cascade,
  user_id      uuid references profiles(id) on delete set null,
  body         text not null,
  likes_count  integer not null default 0,
  created_at   timestamptz not null default now()
);
create index idx_comments_sighting on sighting_comments(sighting_id);

create table comment_likes (
  comment_id   uuid not null references sighting_comments(id) on delete cascade,
  user_id      uuid not null references profiles(id) on delete cascade,
  created_at   timestamptz not null default now(),
  primary key (comment_id, user_id)
);

create table jaguarcoin_transactions (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references profiles(id) on delete cascade,
  lodge_id         uuid not null references lodges(id) on delete cascade,
  amount           integer not null,
  type             coin_transaction_type not null,
  reference_table  text,
  reference_id     uuid,
  created_at       timestamptz not null default now()
);
create index idx_transactions_user on jaguarcoin_transactions(user_id);

create table lodge_reward_settings (
  lodge_id                uuid primary key references lodges(id) on delete cascade,
  sighting_reward_coins   integer not null default 10 check (sighting_reward_coins >= 0),
  checkin_reward_coins    integer not null default 5  check (checkin_reward_coins >= 0),
  updated_at              timestamptz not null default now()
);

create table benefits (
  id          uuid primary key default gen_random_uuid(),
  lodge_id    uuid not null references lodges(id) on delete cascade,
  name        text not null,
  cost_coins  integer not null check (cost_coins > 0),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table redemptions (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  benefit_id  uuid not null references benefits(id),
  lodge_id    uuid not null references lodges(id) on delete cascade,
  code        text unique not null,
  cost_coins  integer not null,
  used        boolean not null default false,
  used_at     timestamptz,
  used_by     uuid references profiles(id),
  created_at  timestamptz not null default now()
);

create table alerts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  sighting_id uuid references sightings(id) on delete cascade,
  lodge_id    uuid not null references lodges(id) on delete cascade,
  title       text not null,
  body        text not null,
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);
create index idx_alerts_user on alerts(user_id, read);

create table reports (
  id           uuid primary key default gen_random_uuid(),
  sighting_id  uuid not null references sightings(id) on delete cascade,
  reporter_id  uuid not null references profiles(id) on delete cascade,
  reason       text,
  status       report_status not null default 'open',
  created_at   timestamptz not null default now()
);

create table badges (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null,
  name         text not null,
  icon         text not null,
  description  text
);

create table user_badges (
  user_id     uuid not null references profiles(id) on delete cascade,
  badge_id    uuid not null references badges(id) on delete cascade,
  lodge_id    uuid references lodges(id),
  earned_at   timestamptz not null default now(),
  primary key (user_id, badge_id)
);

create table push_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  token       text not null,
  platform    text not null,
  created_at  timestamptz not null default now(),
  unique (user_id, token)
);

create table account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  requested_at timestamptz not null default now(),
  processed boolean not null default false,
  processed_at timestamptz
);

create table plans (
  code                        text primary key,
  name                        text not null,
  max_active_reservations     integer,
  analytics_enabled           boolean not null default false,
  custom_branding_enabled     boolean not null default false,
  custom_currency_enabled     boolean not null default false,
  custom_species_enabled      boolean not null default false,
  shared_checkin_code_enabled boolean not null default false,
  monthly_price_usd           numeric(10,2)
);

alter table lodges add constraint lodges_plan_code_fkey foreign key (plan_code) references plans(code);

create table lodge_applications (
  id                uuid primary key default gen_random_uuid(),
  lodge_name        text not null,
  address           text not null,
  tax_id            text not null,
  applicant_name    text not null,
  applicant_email   text not null,
  applicant_phone   text,
  status            text not null default 'pending',
  created_at        timestamptz not null default now(),
  reviewed_at       timestamptz
);

-- ---------------------------------------------------------------------
-- Tabelas do Painel da Plataforma (visão de todas as pousadas juntas)
-- ---------------------------------------------------------------------
create table platform_admins (
  user_id     uuid primary key references profiles(id) on delete cascade,
  added_at    timestamptz not null default now(),
  notes       text
);

create table platform_ai_actions_log (
  id              uuid primary key default gen_random_uuid(),
  requested_by    uuid references profiles(id),
  action_type     text not null,
  action_payload  jsonb not null,
  ai_reasoning    text,
  status          text not null default 'proposed',
  confirmed_by    uuid references profiles(id),
  confirmed_at    timestamptz,
  result          text,
  created_at      timestamptz not null default now()
);

create table site_analytics_events (
  id                uuid primary key default gen_random_uuid(),
  session_id        text not null,
  event_type        text not null,
  page_url          text,
  referrer          text,
  duration_seconds  integer,
  user_agent        text,
  metadata          jsonb,
  created_at        timestamptz not null default now()
);
create index idx_site_events_session on site_analytics_events(session_id);
create index idx_site_events_type_date on site_analytics_events(event_type, created_at);


-- =====================================================================
-- 4) FUNÇÕES AUXILIARES (usadas dentro das políticas de segurança)
-- =====================================================================

create or replace function is_staff_of_lodge(p_lodge_id uuid)
returns boolean
language sql security definer stable set search_path = public
as $$
  select exists(
    select 1 from profiles
    where id = auth.uid() and role in ('guide','admin') and lodge_id = p_lodge_id
  );
$$;

create or replace function is_platform_admin()
returns boolean
language sql security definer stable set search_path = public
as $$
  select exists(select 1 from platform_admins where user_id = auth.uid());
$$;


-- =====================================================================
-- 5) GATILHO: criar perfil automaticamente no cadastro
-- =====================================================================
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, new.raw_user_meta_data ->> 'full_name')
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists trg_handle_new_user on auth.users;
create trigger trg_handle_new_user
  after insert on auth.users
  for each row execute function handle_new_user();


-- =====================================================================
-- 6) GATILHOS: contagem de curtidas
-- =====================================================================
create or replace function bump_sighting_likes()
returns trigger language plpgsql security definer as $$
begin
  if tg_op = 'INSERT' then
    update sightings set likes_count = likes_count + 1 where id = new.sighting_id;
  elsif tg_op = 'DELETE' then
    update sightings set likes_count = likes_count - 1 where id = old.sighting_id;
  end if;
  return null;
end;
$$;
create trigger trg_sighting_likes
  after insert or delete on sighting_likes
  for each row execute function bump_sighting_likes();

create or replace function bump_comment_likes()
returns trigger language plpgsql security definer as $$
begin
  if tg_op = 'INSERT' then
    update sighting_comments set likes_count = likes_count + 1 where id = new.comment_id;
  elsif tg_op = 'DELETE' then
    update sighting_comments set likes_count = likes_count - 1 where id = old.comment_id;
  end if;
  return null;
end;
$$;
create trigger trg_comment_likes
  after insert or delete on comment_likes
  for each row execute function bump_comment_likes();


-- =====================================================================
-- 7) GATILHO: quando um avistamento é aprovado
--    (alertas por espécie + conquistas + raridade — NÃO credita moeda
--    aqui, isso é feito dentro de approve_sighting(), para nunca
--    duplicar o crédito)
-- =====================================================================
create or replace function on_sighting_approved()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  follower record;
  sighting_count integer;
  distinct_species integer;
  has_jaguar boolean;
  species_count_at_lodge integer;
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then

    if new.species_id is not null then
      for follower in
        select ufs.user_id
        from user_followed_species ufs
        join profiles pr on pr.id = ufs.user_id
        where ufs.species_id = new.species_id
          and ufs.user_id <> new.user_id
          and pr.lodge_id = new.lodge_id
      loop
        insert into alerts (user_id, sighting_id, lodge_id, title, body)
        values (follower.user_id, new.id, new.lodge_id,
          upper(new.species_text) || ' AVISTADO!',
          'Um hóspede avistou ' || new.species_text || ' agora. Confira no feed de Avistamentos!');
      end loop;
    end if;

    select count(*) into species_count_at_lodge
      from sightings where lodge_id = new.lodge_id and species_text = new.species_text and status = 'approved';

    if species_count_at_lodge <= 3 then
      update sightings set is_rare = true where id = new.id;
      insert into alerts (user_id, sighting_id, lodge_id, title, body)
      values (new.user_id, new.id, new.lodge_id, '🌟 AVISTAMENTO RARO!',
        'Uau! ' || new.species_text || ' é uma espécie rara de ser avistada por aqui — você é uma das poucas pessoas a registrar isso nesta pousada!');
    end if;

    select count(*), count(distinct species_id) into sighting_count, distinct_species
      from sightings where user_id = new.user_id and status = 'approved';

    select exists(select 1 from sightings where user_id = new.user_id and status='approved' and species_text ilike '%onça%')
      into has_jaguar;

    if sighting_count >= 1 then
      insert into user_badges (user_id, badge_id, lodge_id)
        select new.user_id, b.id, new.lodge_id from badges b where b.code = 'first_sighting'
        on conflict do nothing;
    end if;
    if sighting_count >= 5 then
      insert into user_badges (user_id, badge_id, lodge_id)
        select new.user_id, b.id, new.lodge_id from badges b where b.code = 'frequent_observer'
        on conflict do nothing;
    end if;
    if distinct_species >= 3 then
      insert into user_badges (user_id, badge_id, lodge_id)
        select new.user_id, b.id, new.lodge_id from badges b where b.code = 'biodiversity'
        on conflict do nothing;
    end if;
    if has_jaguar then
      insert into user_badges (user_id, badge_id, lodge_id)
        select new.user_id, b.id, new.lodge_id from badges b where b.code = 'jaguar_hunter'
        on conflict do nothing;
    end if;

  end if;
  return new;
end;
$$;
create trigger trg_on_sighting_approved
  after update of status on sightings
  for each row execute function on_sighting_approved();


-- =====================================================================
-- 8) GATILHOS: moderação de foto + limite de postagens
-- =====================================================================
create or replace function set_initial_moderation_status()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.photo_url is not null then
    new.moderation_status := 'pending';
  end if;
  return new;
end;
$$;
create trigger trg_set_initial_moderation
  before insert on sightings
  for each row execute function set_initial_moderation_status();

create or replace function set_moderation_result(p_sighting_id uuid, p_status moderation_status, p_reason text)
returns void language plpgsql security definer set search_path = public
as $$
begin
  update sightings set moderation_status = p_status, moderation_reason = p_reason where id = p_sighting_id;
end;
$$;

create or replace function enforce_sighting_rate_limit()
returns trigger language plpgsql security definer set search_path = public
as $$
declare recent_count integer;
begin
  select count(*) into recent_count from sightings
    where user_id = new.user_id and created_at > now() - interval '1 hour';
  if recent_count >= 5 then
    raise exception 'Você atingiu o limite de 5 avistamentos por hora. Tente novamente mais tarde.';
  end if;
  return new;
end;
$$;
create trigger trg_sighting_rate_limit
  before insert on sightings
  for each row execute function enforce_sighting_rate_limit();


-- =====================================================================
-- 9) FUNÇÕES RPC — HÓSPEDE
-- =====================================================================

create or replace function recompute_user_trust(p_user_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare v_approved integer; v_rejected integer;
begin
  select count(*) filter (where status='approved'), count(*) filter (where status='rejected')
    into v_approved, v_rejected from sightings where user_id = p_user_id;
  update profiles set
    approved_sightings_count = v_approved,
    rejected_sightings_count = v_rejected,
    verified_observer = (v_approved >= 3 and v_rejected = 0)
    where id = p_user_id;
end;
$$;

create or replace function approve_sighting(p_sighting_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare
  caller_role user_role; caller_lodge uuid; target_lodge uuid; target_user uuid; reward_amount integer;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  select lodge_id, user_id into target_lodge, target_user from sightings where id = p_sighting_id;

  if caller_role not in ('guide','admin') or caller_lodge is distinct from target_lodge then
    raise exception 'Apenas guias/administradores da mesma pousada podem aprovar avistamentos.';
  end if;

  select coalesce(sighting_reward_coins, 10) into reward_amount
    from lodge_reward_settings where lodge_id = target_lodge;
  reward_amount := coalesce(reward_amount, 10);

  update sightings set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_sighting_id and status = 'pending';

  insert into jaguarcoin_transactions (user_id, lodge_id, amount, type, reference_table, reference_id)
  values (target_user, target_lodge, reward_amount, 'sighting_reward', 'sightings', p_sighting_id);

  perform recompute_user_trust(target_user);
end;
$$;

create or replace function reject_sighting(p_sighting_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; target_lodge uuid; target_user uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  select lodge_id, user_id into target_lodge, target_user from sightings where id = p_sighting_id;
  if caller_role not in ('guide','admin') or caller_lodge is distinct from target_lodge then
    raise exception 'Apenas guias/administradores da mesma pousada podem rejeitar avistamentos.';
  end if;
  update sightings set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now()
    where id = p_sighting_id and status = 'pending';
  perform recompute_user_trust(target_user);
end;
$$;

create or replace function toggle_sighting_like(p_sighting_id uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
declare already_liked boolean;
begin
  select exists(select 1 from sighting_likes where sighting_id=p_sighting_id and user_id=auth.uid()) into already_liked;
  if already_liked then
    delete from sighting_likes where sighting_id=p_sighting_id and user_id=auth.uid();
    return false;
  else
    insert into sighting_likes (sighting_id, user_id) values (p_sighting_id, auth.uid());
    return true;
  end if;
end;
$$;

create or replace function toggle_comment_like(p_comment_id uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
declare already_liked boolean;
begin
  select exists(select 1 from comment_likes where comment_id=p_comment_id and user_id=auth.uid()) into already_liked;
  if already_liked then
    delete from comment_likes where comment_id=p_comment_id and user_id=auth.uid();
    return false;
  else
    insert into comment_likes (comment_id, user_id) values (p_comment_id, auth.uid());
    return true;
  end if;
end;
$$;

create or replace function generate_unique_lodge_code(p_lodge_name text)
returns text language plpgsql security definer set search_path = public
as $$
declare v_prefix text; v_candidate text; v_attempts integer := 0;
begin
  v_prefix := upper(substr(regexp_replace(p_lodge_name, '[^a-zA-Z]', '', 'g'), 1, 3));
  if length(v_prefix) < 3 then v_prefix := rpad(v_prefix, 3, 'X'); end if;
  loop
    v_candidate := v_prefix || '-' || lpad(floor(random()*1000000)::text, 6, '0');
    exit when not exists (select 1 from lodges where shared_access_code = v_candidate)
      and not exists (select 1 from reservations where reservation_code = v_candidate);
    v_attempts := v_attempts + 1;
    if v_attempts > 30 then raise exception 'Não foi possível gerar um código único no momento.'; end if;
  end loop;
  return v_candidate;
end;
$$;

create or replace function claim_reservation(p_code text)
returns json language plpgsql security definer set search_path = public
as $$
declare v_reservation reservations%rowtype; v_lodge_name text; v_updated integer;
begin
  select * into v_reservation from reservations where reservation_code = p_code;
  if v_reservation.id is null then raise exception 'Código de reserva não encontrado.'; end if;
  if v_reservation.user_id is not null and v_reservation.user_id <> auth.uid() then
    raise exception 'Este código já foi vinculado a outra conta.';
  end if;

  update reservations set user_id = auth.uid()
    where id = v_reservation.id and (user_id is null or user_id = auth.uid());
  get diagnostics v_updated = row_count;
  if v_updated = 0 then raise exception 'Este código já foi vinculado a outra conta.'; end if;

  update profiles set verified_guest = true, lodge_id = v_reservation.lodge_id where id = auth.uid();
  select name into v_lodge_name from lodges where id = v_reservation.lodge_id;
  return json_build_object('reservation_id', v_reservation.id, 'lodge_name', v_lodge_name);
end;
$$;

create or replace function claim_lodge_access_code(p_code text)
returns json language plpgsql security definer set search_path = public
as $$
declare v_lodge lodges%rowtype;
begin
  select * into v_lodge from lodges where shared_access_code = p_code;
  if v_lodge.id is null then raise exception 'Código de acesso da pousada não encontrado.'; end if;
  update profiles set verified_guest = true, lodge_id = v_lodge.id where id = auth.uid();
  return json_build_object('lodge_name', v_lodge.name);
end;
$$;

create or replace function checkin_reservation(p_reservation_id uuid, p_lat double precision, p_lng double precision)
returns boolean language plpgsql security definer set search_path = public
as $$
declare
  lodge_location geography; radius integer; reservation_owner uuid; reservation_lodge uuid;
  distance_meters double precision; reward_amount integer; v_updated integer;
begin
  select r.user_id, r.lodge_id, l.location, l.geofence_radius_meters
    into reservation_owner, reservation_lodge, lodge_location, radius
    from reservations r join lodges l on l.id = r.lodge_id where r.id = p_reservation_id;

  if reservation_owner is distinct from auth.uid() then
    raise exception 'Esta reserva não pertence ao usuário autenticado.';
  end if;

  distance_meters := ST_Distance(lodge_location, ST_MakePoint(p_lng, p_lat)::geography);
  if distance_meters > radius then return false; end if;

  update reservations set checked_in_at = now(), checkin_location = ST_MakePoint(p_lng, p_lat)::geography
    where id = p_reservation_id and checked_in_at is null;
  get diagnostics v_updated = row_count;
  if v_updated = 0 then return true; end if;

  select coalesce(checkin_reward_coins, 5) into reward_amount from lodge_reward_settings where lodge_id = reservation_lodge;
  reward_amount := coalesce(reward_amount, 5);

  insert into jaguarcoin_transactions (user_id, lodge_id, amount, type, reference_table, reference_id)
    values (reservation_owner, reservation_lodge, reward_amount, 'checkin_reward', 'reservations', p_reservation_id);

  return true;
end;
$$;

create or replace function redeem_benefit(p_benefit_id uuid)
returns text language plpgsql security definer set search_path = public
as $$
declare v_cost integer; v_lodge uuid; v_balance integer; v_code text;
begin
  perform pg_advisory_xact_lock(hashtext(auth.uid()::text));
  select cost_coins, lodge_id into v_cost, v_lodge from benefits where id = p_benefit_id and active = true;
  if v_cost is null then raise exception 'Benefício não encontrado ou inativo.'; end if;

  select coalesce(balance, 0) into v_balance from user_coin_summary where user_id = auth.uid() and lodge_id = v_lodge;
  if v_balance < v_cost then raise exception 'Saldo insuficiente de JaguarCoin.'; end if;

  v_code := 'ARL-' || upper(substr(md5(random()::text), 1, 6));
  insert into redemptions (user_id, benefit_id, lodge_id, code, cost_coins) values (auth.uid(), p_benefit_id, v_lodge, v_code, v_cost);
  insert into jaguarcoin_transactions (user_id, lodge_id, amount, type, reference_table, reference_id)
    values (auth.uid(), v_lodge, -v_cost, 'redemption', 'redemptions', (select id from redemptions where code = v_code));

  return v_code;
end;
$$;

create or replace function validate_redemption_code(p_code text)
returns boolean language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; v_lodge uuid; already_used boolean;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  select lodge_id, used into v_lodge, already_used from redemptions where code = p_code;
  if caller_role not in ('guide','admin') or caller_lodge is distinct from v_lodge then
    raise exception 'Apenas a equipe da pousada pode validar vouchers.';
  end if;
  if already_used then return false; end if;
  update redemptions set used = true, used_at = now(), used_by = auth.uid() where code = p_code;
  return true;
end;
$$;

create or replace function mark_alerts_read()
returns void language sql security definer set search_path = public
as $$
  update alerts set read = true where user_id = auth.uid() and read = false;
$$;

create or replace function submit_lodge_application(
  p_lodge_name text, p_address text, p_tax_id text,
  p_applicant_name text, p_applicant_email text, p_applicant_phone text
) returns uuid language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  insert into lodge_applications (lodge_name, address, tax_id, applicant_name, applicant_email, applicant_phone)
    values (p_lodge_name, p_address, p_tax_id, p_applicant_name, p_applicant_email, p_applicant_phone)
    returning id into v_id;
  return v_id;
end;
$$;


-- =====================================================================
-- 10) FUNÇÕES RPC — ADMINISTRADOR DA POUSADA
-- =====================================================================

create or replace function admin_create_reservation(p_code text, p_checkin date, p_checkout date)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  caller_role user_role; caller_lodge uuid; v_id uuid; v_plan text; v_lodge_name text;
  v_max integer; v_active_count integer; v_code text;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas administradores podem criar reservas.'; end if;

  select l.plan_code, l.name, p.max_active_reservations into v_plan, v_lodge_name, v_max
    from lodges l join plans p on p.code = l.plan_code where l.id = caller_lodge;

  if v_max is not null then
    select count(*) into v_active_count from reservations where lodge_id = caller_lodge and check_out_date >= current_date;
    if v_active_count >= v_max then
      raise exception 'Seu plano (%) permite no máximo % reservas ativas. Faça upgrade para o Pro/Premium para reservas ilimitadas.', v_plan, v_max;
    end if;
  end if;

  v_code := coalesce(nullif(trim(p_code), ''), generate_unique_lodge_code(v_lodge_name));
  insert into reservations (lodge_id, reservation_code, check_in_date, check_out_date)
    values (caller_lodge, v_code, p_checkin, p_checkout) returning id into v_id;
  return v_id;
end;
$$;

create or replace function admin_create_benefit(p_name text, p_cost integer)
returns uuid language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; v_id uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas administradores podem criar benefícios.'; end if;
  insert into benefits (lodge_id, name, cost_coins, active) values (caller_lodge, p_name, p_cost, true) returning id into v_id;
  return v_id;
end;
$$;

create or replace function admin_toggle_benefit(p_benefit_id uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; target_lodge uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  select lodge_id into target_lodge from benefits where id = p_benefit_id;
  if caller_role <> 'admin' or caller_lodge is distinct from target_lodge then
    raise exception 'Apenas administradores da mesma pousada podem alterar este benefício.';
  end if;
  update benefits set active = p_active where id = p_benefit_id;
end;
$$;

create or replace function admin_update_reward_settings(p_sighting_reward integer, p_checkin_reward integer)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas administradores podem alterar os valores de recompensa.'; end if;
  insert into lodge_reward_settings (lodge_id, sighting_reward_coins, checkin_reward_coins, updated_at)
    values (caller_lodge, p_sighting_reward, p_checkin_reward, now())
  on conflict (lodge_id) do update set
    sighting_reward_coins = excluded.sighting_reward_coins,
    checkin_reward_coins = excluded.checkin_reward_coins,
    updated_at = now();
end;
$$;

create or replace function admin_list_reservations()
returns table (
  id uuid, reservation_code text, check_in_date date, check_out_date date,
  claimed boolean, checked_in boolean, guest_name text
) language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role not in ('admin','guide') then raise exception 'Apenas administradores/guias podem ver as reservas.'; end if;
  return query
    select r.id, r.reservation_code, r.check_in_date, r.check_out_date,
           (r.user_id is not null) as claimed, (r.checked_in_at is not null) as checked_in,
           p.full_name as guest_name
    from reservations r left join profiles p on p.id = r.user_id
    where r.lodge_id = caller_lodge order by r.created_at desc;
end;
$$;

create or replace function admin_update_branding(p_display_name text, p_logo_url text, p_currency_name text, p_currency_icon text, p_conservation_partner text)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; v_branding_ok boolean; v_currency_ok boolean;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas administradores podem alterar a marca da pousada.'; end if;

  select p.custom_branding_enabled, p.custom_currency_enabled into v_branding_ok, v_currency_ok
    from lodges l join plans p on p.code = l.plan_code where l.id = caller_lodge;

  if (p_display_name is not null or p_logo_url is not null) and not v_branding_ok then
    raise exception 'Personalizar marca/logo é um recurso do plano Pro.';
  end if;
  if (p_currency_name is not null or p_currency_icon is not null) and not v_currency_ok then
    raise exception 'Renomear a moeda é um recurso do plano Pro.';
  end if;

  update lodges set
    display_name = coalesce(p_display_name, display_name),
    logo_url = coalesce(p_logo_url, logo_url),
    currency_name = coalesce(p_currency_name, currency_name),
    currency_icon = coalesce(p_currency_icon, currency_icon),
    conservation_partner = coalesce(p_conservation_partner, conservation_partner)
  where id = caller_lodge;
end;
$$;

create or replace function admin_create_species(p_common_name text, p_scientific_name text, p_category text)
returns uuid language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; v_id uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas administradores podem cadastrar espécies.'; end if;
  insert into species (common_name, scientific_name, category, lodge_id)
    values (p_common_name, p_scientific_name, p_category, caller_lodge) returning id into v_id;
  return v_id;
end;
$$;

create or replace function admin_generate_shared_access_code()
returns text language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; v_lodge_name text; v_enabled boolean; v_code text;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas administradores podem gerar o código de acesso da pousada.'; end if;
  select l.name, p.shared_checkin_code_enabled into v_lodge_name, v_enabled
    from lodges l join plans p on p.code = l.plan_code where l.id = caller_lodge;
  if not v_enabled then raise exception 'O código de check-in compartilhado é um recurso exclusivo dos planos Pro e Premium.'; end if;
  v_code := generate_unique_lodge_code(v_lodge_name);
  update lodges set shared_access_code = v_code where id = caller_lodge;
  return v_code;
end;
$$;

create or replace function admin_set_shared_access_code(p_code text)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; v_enabled boolean;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas administradores podem definir o código de acesso da pousada.'; end if;
  select p.shared_checkin_code_enabled into v_enabled from lodges l join plans p on p.code = l.plan_code where l.id = caller_lodge;
  if not v_enabled then raise exception 'O código de check-in compartilhado é um recurso exclusivo dos planos Pro e Premium.'; end if;
  update lodges set shared_access_code = p_code where id = caller_lodge;
end;
$$;

create or replace function admin_reset_checkin(p_reservation_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; target_lodge uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  select lodge_id into target_lodge from reservations where id = p_reservation_id;
  if caller_role not in ('admin','guide') or caller_lodge is distinct from target_lodge then
    raise exception 'Apenas a equipe da mesma pousada pode refazer um check-in.';
  end if;
  update reservations set checked_in_at = null, checkin_location = null where id = p_reservation_id;
end;
$$;


-- =====================================================================
-- 11) EXPIRAÇÃO DE MOEDA (agendada via pg_cron — ative a extensão pelo
--     painel do Supabase: Database -> Extensions -> pg_cron)
-- =====================================================================
create or replace function expire_old_coin_balances()
returns void language plpgsql security definer set search_path = public
as $$
declare r record;
begin
  for r in
    select user_id, lodge_id, sum(amount) as balance, max(created_at) filter (where amount > 0) as last_earned
    from jaguarcoin_transactions group by user_id, lodge_id having sum(amount) > 0
  loop
    if r.last_earned < now() - interval '14 days' then
      insert into jaguarcoin_transactions (user_id, lodge_id, amount, type, reference_table)
        values (r.user_id, r.lodge_id, -r.balance, 'adjustment', 'expiration');
      insert into alerts (user_id, lodge_id, title, body)
        values (r.user_id, r.lodge_id, 'Seu saldo de JaguarCoin expirou',
          'Você ficou 14 dias sem registrar um avistamento ou check-in, e seu saldo de JaguarCoin foi zerado. Continue explorando para ganhar mais!');
    end if;
  end loop;
end;
$$;
-- Depois de ativar a extensão pg_cron, agende com:
-- select cron.schedule('expire-jaguarcoin-daily', '0 3 * * *', $$select expire_old_coin_balances()$$);

-- Rede de segurança: nunca deixa o saldo ficar negativo
create or replace function prevent_negative_balance()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_balance integer;
begin
  select coalesce(sum(amount), 0) into v_balance from jaguarcoin_transactions
    where user_id = new.user_id and lodge_id = new.lodge_id;
  if v_balance < 0 then raise exception 'Operação recusada: deixaria o saldo de JaguarCoin negativo.'; end if;
  return new;
end;
$$;
create constraint trigger trg_prevent_negative_balance
  after insert on jaguarcoin_transactions
  deferrable initially deferred
  for each row execute function prevent_negative_balance();


-- =====================================================================
-- 12) FUNÇÕES RPC — PAINEL DA PLATAFORMA (IA e ações administrativas)
-- =====================================================================
create or replace function confirm_ai_action(p_action_id uuid)
returns text language plpgsql security definer set search_path = public
as $$
declare v_action platform_ai_actions_log%rowtype; v_result text;
begin
  if not is_platform_admin() then raise exception 'Apenas administradores da plataforma podem confirmar ações.'; end if;
  select * into v_action from platform_ai_actions_log where id = p_action_id and status = 'proposed';
  if v_action.id is null then raise exception 'Proposta não encontrada ou já processada.'; end if;

  begin
    if v_action.action_type = 'update_lodge_plan' then
      update lodges set plan_code = (v_action.action_payload->>'new_plan_code') where id = (v_action.action_payload->>'lodge_id')::uuid;
      v_result := 'Plano atualizado.';
    elsif v_action.action_type = 'set_lodge_commission_rate' then
      update lodges set commission_rate = (v_action.action_payload->>'new_rate')::numeric where id = (v_action.action_payload->>'lodge_id')::uuid;
      v_result := 'Comissão atualizada.';
    elsif v_action.action_type = 'add_platform_admin' then
      insert into platform_admins (user_id) select id from profiles where email = (v_action.action_payload->>'email') on conflict (user_id) do nothing;
      v_result := 'Administrador da plataforma adicionado.';
    elsif v_action.action_type = 'approve_lodge_application' then
      update lodge_applications set status = 'approved', reviewed_at = now() where id = (v_action.action_payload->>'application_id')::uuid;
      v_result := 'Solicitação marcada como aprovada.';
    else
      raise exception 'Tipo de ação desconhecido: %', v_action.action_type;
    end if;

    update platform_ai_actions_log set status='executed', confirmed_by=auth.uid(), confirmed_at=now(), result=v_result where id = p_action_id;
    return v_result;
  exception when others then
    update platform_ai_actions_log set status='failed', confirmed_by=auth.uid(), confirmed_at=now(), result=SQLERRM where id = p_action_id;
    raise;
  end;
end;
$$;

create or replace function reject_ai_action(p_action_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if not is_platform_admin() then raise exception 'Apenas administradores da plataforma podem rejeitar ações.'; end if;
  update platform_ai_actions_log set status='rejected', confirmed_by=auth.uid(), confirmed_at=now() where id = p_action_id and status='proposed';
end;
$$;


-- =====================================================================
-- 13) VIEWS
-- =====================================================================

create view user_coin_summary as
select user_id, lodge_id, sum(amount) as balance, sum(amount) filter (where amount > 0) as total_earned
from jaguarcoin_transactions group by user_id, lodge_id;

create view lodge_leaderboard as
select p.lodge_id, p.id as user_id, p.full_name, coalesce(s.total_earned, 0) as points
from profiles p
left join user_coin_summary s on s.user_id = p.id and s.lodge_id = p.lodge_id
where p.role = 'guest' order by points desc;

create view lodge_species_popularity as
select lodge_id, species_text, count(*) as sighting_count
from sightings where status = 'approved' group by lodge_id, species_text order by sighting_count desc;

create view lodge_activity_summary as
select lodge_id, count(distinct user_id) as active_guests, count(*) as total_approved_sightings,
  count(*) filter (where created_at > now() - interval '30 days') as sightings_last_30_days
from sightings where status = 'approved' group by lodge_id;

create view lodge_top_guests as
select p.lodge_id, p.full_name, count(s.id) as sightings_count
from sightings s join profiles p on p.id = s.user_id
where s.status = 'approved' group by p.lodge_id, p.full_name order by sightings_count desc;

create view lodge_plan_features as
select
  l.id as lodge_id, l.name, l.display_name, l.logo_url,
  l.currency_name, l.currency_icon, l.conservation_partner,
  l.plan_code, l.plan_status, l.plan_renews_at, l.shared_access_code,
  p.max_active_reservations, p.analytics_enabled, p.custom_branding_enabled,
  p.custom_currency_enabled, p.custom_species_enabled, p.shared_checkin_code_enabled,
  p.monthly_price_usd
from lodges l join plans p on p.code = l.plan_code;

create view lodge_coin_audit_log as
select t.id, t.lodge_id, p.full_name as guest_name, t.amount, t.type, t.reference_table, t.reference_id, t.created_at,
  sum(t.amount) over (partition by t.user_id, t.lodge_id order by t.created_at rows between unbounded preceding and current row) as saldo_apos_esta_transacao
from jaguarcoin_transactions t join profiles p on p.id = t.user_id order by t.created_at desc;

create view lodge_coin_economy as
select lodge_id,
  sum(amount) filter (where amount > 0) as total_emitido,
  abs(sum(amount) filter (where type = 'redemption')) as total_resgatado,
  abs(sum(amount) filter (where type = 'adjustment' and reference_table = 'expiration')) as total_expirado,
  sum(amount) as em_circulacao
from jaguarcoin_transactions group by lodge_id;

-- Painel da plataforma (todas as pousadas)
create view platform_lodge_overview as
select
  l.id, l.name, l.slug, l.plan_code, l.plan_status, l.plan_renews_at,
  l.contact_email, l.contact_phone, l.commission_rate, l.created_at,
  (select count(*) from sightings s where s.lodge_id = l.id and s.status = 'approved') as total_avistamentos,
  (select count(distinct s.user_id) from sightings s where s.lodge_id = l.id) as total_hospedes_ativos,
  (select count(*) from reservations r where r.lodge_id = l.id) as total_reservas,
  (select count(*) from reservations r where r.lodge_id = l.id and r.checked_in_at is not null) as total_checkins
from lodges l;

create view platform_top_lodges_by_posts as
select l.id, l.name, count(s.id) as total_avistamentos
from lodges l join sightings s on s.lodge_id = l.id and s.status = 'approved'
group by l.id, l.name order by total_avistamentos desc;

create view platform_top_lodges_by_guests as
select l.id, l.name, count(distinct r.user_id) as total_hospedes
from lodges l join reservations r on r.lodge_id = l.id and r.checked_in_at is not null
group by l.id, l.name order by total_hospedes desc;

create view platform_returning_guests as
select p.id as user_id, p.full_name, p.email, count(r.id) as total_estadias
from profiles p join reservations r on r.user_id = p.id
group by p.id, p.full_name, p.email having count(r.id) > 1 order by total_estadias desc;

create view platform_guests_by_country as
select coalesce(nullif(trim(nationality), ''), 'Não informado') as pais, count(*) as total_hospedes
from profiles where role = 'guest' group by 1 order by total_hospedes desc;

create view platform_species_by_region as
select l.name as pousada, l.address, s.species_text, count(*) as total
from sightings s join lodges l on l.id = s.lodge_id
where s.status = 'approved' group by l.name, l.address, s.species_text order by total desc;

create view platform_coin_circulation as
select
  sum(amount) filter (where amount > 0) as total_emitido,
  abs(sum(amount) filter (where type = 'redemption')) as total_resgatado,
  abs(sum(amount) filter (where type = 'adjustment' and reference_table = 'expiration')) as total_expirado,
  sum(amount) as em_circulacao
from jaguarcoin_transactions;

create view platform_subscribers_summary as
select plan_code, count(*) as total_pousadas,
  sum(case when plan_code <> 'free' then 1 else 0 end) over () as total_assinantes_pagos
from lodges group by plan_code;

create view platform_cashflow_projection as
select l.id as lodge_id, l.name as pousada, date_trunc('month', r.check_in_date)::date as mes,
  count(r.id) as qtd_reservas, sum(r.booking_value) as valor_total_agendado,
  l.commission_rate, sum(r.booking_value) * l.commission_rate as comissao_projetada
from reservations r join lodges l on l.id = r.lodge_id
where r.booking_value is not null
group by l.id, l.name, date_trunc('month', r.check_in_date), l.commission_rate order by mes, pousada;

create view platform_subscription_revenue as
select l.id, l.name, l.plan_code, l.plan_status, l.plan_renews_at, p.monthly_price_usd
from lodges l join plans p on p.code = l.plan_code where l.plan_code <> 'free';

create view platform_lodges_timeline as
select id, name, slug, plan_code, created_at from lodges order by created_at desc;

create view platform_churn_risk as
select l.id, l.name, l.plan_code, l.contact_email,
  (select max(s.created_at) from sightings s where s.lodge_id = l.id) as ultimo_avistamento,
  (select max(r.created_at) from reservations r where r.lodge_id = l.id) as ultima_reserva,
  greatest(
    coalesce((select max(s.created_at) from sightings s where s.lodge_id = l.id), l.created_at),
    coalesce((select max(r.created_at) from reservations r where r.lodge_id = l.id), l.created_at)
  ) as ultima_atividade
from lodges l where l.plan_code <> 'free' order by ultima_atividade asc nulls first;

create view platform_conversion_funnel as
select
  (select count(*) from lodge_applications) as total_solicitacoes,
  (select count(*) from lodge_applications where status = 'approved') as total_aprovadas,
  (select count(distinct lodge_id) from reservations) as pousadas_com_reserva,
  (select count(*) from lodges where plan_code <> 'free') as pousadas_pagantes;

create view site_analytics_summary as
select
  count(*) filter (where event_type = 'pageview') as total_pageviews,
  count(distinct session_id) as total_sessoes,
  count(*) filter (where event_type = 'whatsapp_click') as total_cliques_whatsapp,
  round(avg(duration_seconds) filter (where event_type = 'session_end')) as duracao_media_segundos
from site_analytics_events;

create view site_analytics_top_pages as
select page_url, count(*) as visualizacoes from site_analytics_events
where event_type = 'pageview' group by page_url order by visualizacoes desc;

create view site_analytics_daily as
select date_trunc('day', created_at)::date as dia,
  count(*) filter (where event_type = 'pageview') as pageviews,
  count(distinct session_id) as sessoes,
  count(*) filter (where event_type = 'whatsapp_click') as cliques_whatsapp
from site_analytics_events group by 1 order by 1;


-- =====================================================================
-- 14) DADOS INICIAIS (seed)
-- =====================================================================
insert into plans (code, name, max_active_reservations, analytics_enabled, custom_branding_enabled, custom_currency_enabled, custom_species_enabled, shared_checkin_code_enabled, monthly_price_usd)
values
  ('free',    'Free',    20,   false, false, false, false, false, 0),
  ('pro',     'Pro',     null, true,  true,  true,  true,  true,  49.00),
  ('premium', 'Premium', null, true,  true,  true,  true,  true,  99.00);

insert into badges (code, name, icon, description) values
  ('first_sighting', 'Primeiro Avistamento', '🥉', 'Registrou seu primeiro avistamento validado.'),
  ('frequent_observer', 'Observador Frequente', '🥈', 'Registrou 5 avistamentos validados.'),
  ('biodiversity', 'Diversidade da Fauna', '🌿', 'Avistou 3 espécies diferentes.'),
  ('jaguar_hunter', 'Caçador de Onças', '🐆', 'Avistou uma onça-pintada.');

insert into species (common_name, scientific_name, category) values
  ('Onça-Pintada', 'Panthera onca', 'mamifero'),
  ('Tuiuiú', 'Jabiru mycteria', 'ave'),
  ('Lobo-guará', 'Chrysocyon brachyurus', 'mamifero'),
  ('Arara-azul', 'Anodorhynchus hyacinthinus', 'ave'),
  ('Capivara', 'Hydrochoerus hydrochaeris', 'mamifero'),
  ('Jacaré-do-pantanal', 'Caiman yacare', 'reptil'),
  ('Anta', 'Tapirus terrestris', 'mamifero'),
  ('Tamanduá-bandeira', 'Myrmecophaga tridactyla', 'mamifero'),
  ('Queixada', 'Tayassu pecari', 'mamifero'),
  ('Tucano-toco', 'Ramphastos toco', 'ave');

-- Exemplo de pousada (edite ou apague antes de ir para produção)
insert into lodges (name, slug, address, location, geofence_radius_meters, plan_code) values
  ('Araras Eco Lodge', 'araras-eco-lodge', 'Estrada Transpantaneira, Poconé - MT',
   ST_MakePoint(-56.7325, -16.7414)::geography, 500, 'free');

insert into lodge_reward_settings (lodge_id)
  select id from lodges on conflict (lodge_id) do nothing;

create or replace function create_default_reward_settings()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into lodge_reward_settings (lodge_id) values (new.id) on conflict (lodge_id) do nothing;
  return new;
end;
$$;
create trigger trg_create_default_reward_settings
  after insert on lodges
  for each row execute function create_default_reward_settings();


-- =====================================================================
-- 15) ROW LEVEL SECURITY (RLS)
-- =====================================================================

alter table lodges enable row level security;
alter table profiles enable row level security;
alter table reservations enable row level security;
alter table species enable row level security;
alter table user_followed_species enable row level security;
alter table sightings enable row level security;
alter table sighting_likes enable row level security;
alter table sighting_comments enable row level security;
alter table comment_likes enable row level security;
alter table jaguarcoin_transactions enable row level security;
alter table lodge_reward_settings enable row level security;
alter table benefits enable row level security;
alter table redemptions enable row level security;
alter table alerts enable row level security;
alter table reports enable row level security;
alter table badges enable row level security;
alter table user_badges enable row level security;
alter table push_tokens enable row level security;
alter table account_deletion_requests enable row level security;
alter table plans enable row level security;
alter table lodge_applications enable row level security;
alter table platform_admins enable row level security;
alter table platform_ai_actions_log enable row level security;
alter table site_analytics_events enable row level security;

-- leitura pública
create policy "lodges_select_all" on lodges for select using (true);
create policy "species_select_all" on species for select using (true);
create policy "badges_select_all" on badges for select using (true);
create policy "plans_select_all" on plans for select using (true);
create policy "benefits_select_all" on benefits for select using (true);
create policy "user_badges_select_all" on user_badges for select using (true);
create policy "likes_select_all" on sighting_likes for select using (true);
create policy "comments_select_all" on sighting_comments for select using (true);
create policy "comment_likes_select_all" on comment_likes for select using (true);

-- profiles (sem auto-referência — usa is_staff_of_lodge)
create policy "profiles_select_own_or_same_lodge_staff" on profiles
  for select using (id = auth.uid() or is_staff_of_lodge(lodge_id));
create policy "profiles_update_own" on profiles for update using (id = auth.uid());

-- reservations
create policy "reservations_select_own_or_staff" on reservations
  for select using (user_id = auth.uid() or is_staff_of_lodge(lodge_id));

-- espécies seguidas
create policy "followed_species_all_own" on user_followed_species
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- sightings: exige hóspede verificado para publicar
create policy "sightings_select" on sightings
  for select using (status = 'approved' or user_id = auth.uid() or is_staff_of_lodge(lodge_id));
create policy "sightings_insert_verified_only" on sightings
  for insert with check (user_id = auth.uid() and exists (select 1 from profiles where id = auth.uid() and verified_guest = true));

create policy "likes_insert_own" on sighting_likes for insert with check (user_id = auth.uid());
create policy "likes_delete_own" on sighting_likes for delete using (user_id = auth.uid());

create policy "comments_insert_verified_only" on sighting_comments
  for insert with check (user_id = auth.uid() and exists (select 1 from profiles where id = auth.uid() and verified_guest = true));
create policy "comments_delete_own" on sighting_comments for delete using (user_id = auth.uid());

create policy "comment_likes_insert_own" on comment_likes for insert with check (user_id = auth.uid());
create policy "comment_likes_delete_own" on comment_likes for delete using (user_id = auth.uid());

-- moeda: NUNCA gravável direto pelo cliente, só via funções SECURITY DEFINER
create policy "transactions_select_own_or_staff" on jaguarcoin_transactions
  for select using (user_id = auth.uid() or is_staff_of_lodge(lodge_id));

create policy "reward_settings_select_all" on lodge_reward_settings for select using (true);
create policy "reward_settings_update_admin_only" on lodge_reward_settings
  for update using (exists (select 1 from profiles where id = auth.uid() and role = 'admin' and lodge_id = lodge_reward_settings.lodge_id));
create policy "reward_settings_insert_admin_only" on lodge_reward_settings
  for insert with check (exists (select 1 from profiles where id = auth.uid() and role = 'admin' and lodge_id = lodge_reward_settings.lodge_id));

create policy "redemptions_select_own_or_staff" on redemptions
  for select using (user_id = auth.uid() or is_staff_of_lodge(lodge_id));

create policy "alerts_select_own" on alerts for select using (user_id = auth.uid());
create policy "alerts_update_own" on alerts for update using (user_id = auth.uid());

create policy "reports_insert_own" on reports for insert with check (reporter_id = auth.uid());
create policy "reports_select_staff" on reports
  for select using (exists (select 1 from sightings s where s.id = reports.sighting_id and is_staff_of_lodge(s.lodge_id)));

create policy "push_tokens_all_own" on push_tokens for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "deletion_requests_insert_own" on account_deletion_requests for insert with check (user_id = auth.uid());
create policy "deletion_requests_select_own" on account_deletion_requests for select using (user_id = auth.uid());

create policy "lodge_applications_insert_anyone" on lodge_applications for insert with check (true);

-- painel da plataforma
create policy "platform_admins_select_self_list" on platform_admins for select using (user_id = auth.uid());
create policy "ai_log_platform_admin_only" on platform_ai_actions_log for all using (is_platform_admin()) with check (is_platform_admin());
create policy "site_events_insert_anyone" on site_analytics_events for insert with check (true);
create policy "site_events_select_platform_admin" on site_analytics_events for select using (is_platform_admin());

-- acesso do admin da plataforma às tabelas de todas as pousadas
create policy "platform_admin_sees_all_lodges" on lodges for select using (is_platform_admin());
create policy "platform_admin_sees_all_profiles" on profiles for select using (is_platform_admin());
create policy "platform_admin_sees_all_reservations" on reservations for select using (is_platform_admin());
create policy "platform_admin_sees_all_sightings" on sightings for select using (is_platform_admin());
create policy "platform_admin_sees_all_transactions" on jaguarcoin_transactions for select using (is_platform_admin());
create policy "platform_admin_sees_all_redemptions" on redemptions for select using (is_platform_admin());
create policy "platform_admin_sees_all_applications" on lodge_applications for select using (is_platform_admin());


-- =====================================================================
-- 16) STORAGE (buckets e políticas)
-- =====================================================================
insert into storage.buckets (id, name, public) values ('sighting-photos', 'sighting-photos', true);
create policy "sighting_photos_public_read" on storage.objects for select using (bucket_id = 'sighting-photos');
create policy "sighting_photos_authenticated_upload" on storage.objects for insert with check (bucket_id = 'sighting-photos' and auth.role() = 'authenticated');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sighting-videos', 'sighting-videos', true, 31457280, array['video/mp4','video/webm','video/quicktime']);
create policy "sighting_videos_public_read" on storage.objects for select using (bucket_id = 'sighting-videos');
create policy "sighting_videos_authenticated_upload" on storage.objects for insert with check (bucket_id = 'sighting-videos' and auth.role() = 'authenticated');

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('user-avatars', 'user-avatars', true, 5242880, array['image/jpeg','image/png','image/webp']);
create policy "avatars_public_read" on storage.objects for select using (bucket_id = 'user-avatars');
create policy "avatars_owner_upload" on storage.objects for insert with check (bucket_id = 'user-avatars' and auth.role() = 'authenticated');
create policy "avatars_owner_update" on storage.objects for update using (bucket_id = 'user-avatars' and owner = auth.uid());

-- Observação: um bucket "app-web" para hospedar o HTML do app foi
-- tentado durante o projeto, mas o Supabase Storage não serve .html
-- com o content-type correto para isso funcionar bem (confirmado em
-- teste real) — a hospedagem do app ficou por conta do GitHub Pages.
-- Não recriamos esse bucket aqui por causa dessa limitação conhecida.


-- =====================================================================
-- FIM DO SCHEMA CONSOLIDADO
-- =====================================================================


-- =====================================================================
-- PARTE 2 — ENTERPRISE (mesmo conteúdo de ecosafari-go-migration-enterprise.sql)
-- =====================================================================
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
-- =====================================================================
-- EcoSafari Go — PERFIL SOCIAL + CORREÇÕES DE SEGURANÇA
-- ---------------------------------------------------------------------
-- Pode rodar quantas vezes quiser (idempotente).
-- Parte A: corrige dois furos de segurança encontrados em auditoria.
-- Parte B: perfil estilo Instagram (@usuário, bio, capa, link, seguidores).
-- =====================================================================


-- =====================================================================
-- PARTE A — SEGURANÇA
-- =====================================================================

-- A1) Ninguém pode se promover a admin / se verificar pelo app.
--     Antes, a regra "atualizar o próprio perfil" valia para TODAS as colunas:
--     qualquer pessoa logada podia gravar role='admin' ou lodge_id de outra pousada.
--     Agora, chamadas diretas do app (papéis authenticated/anon) não mexem nessas
--     colunas. As funções do banco (SECURITY DEFINER), o SQL Editor, o service_role
--     e o admin da plataforma continuam podendo.
--     (A função é SECURITY INVOKER de propósito: current_user precisa ser quem
--      chamou, e não o dono da função.)
create or replace function guard_profile_update()
returns trigger language plpgsql set search_path = public
as $$
begin
  if current_user in ('authenticated', 'anon') and not coalesce(is_platform_admin(), false) then
    if new.id                       is distinct from old.id
    or new.role                     is distinct from old.role
    or new.lodge_id                 is distinct from old.lodge_id
    or new.email                    is distinct from old.email
    or new.verified_guest           is distinct from old.verified_guest
    or new.verified_observer        is distinct from old.verified_observer
    or new.approved_sightings_count is distinct from old.approved_sightings_count
    or new.rejected_sightings_count is distinct from old.rejected_sightings_count
    then
      raise exception 'Esta alteração não é permitida.' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_00_guard_profile_update on profiles;
create trigger trg_00_guard_profile_update
  before update on profiles
  for each row execute function guard_profile_update();


-- A2) Avistamento novo sempre nasce "pendente".
--     Antes, o app podia inserir já com status='approved' (pulando a equipe),
--     is_rare=true, checagem de vídeo "ok" falsa, ou em nome de outra pousada.
create or replace function guard_sighting_insert()
returns trigger language plpgsql set search_path = public
as $$
declare v_lodge uuid;
begin
  if current_user in ('authenticated', 'anon') then
    select lodge_id into v_lodge from profiles where id = auth.uid();
    new.user_id            := auth.uid();
    new.lodge_id           := v_lodge;
    new.status             := 'pending';
    new.moderation_status  := 'not_applicable';
    new.moderation_reason  := null;
    new.is_rare            := false;
    new.reviewed_by        := null;
    new.reviewed_at        := null;
    new.likes_count        := 0;
    new.video_transcript   := null;
    new.video_check        := null;
    new.video_check_status := 'not_applicable';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_00_guard_sighting_insert on sightings;
create trigger trg_00_guard_sighting_insert
  before insert on sightings
  for each row execute function guard_sighting_insert();


-- A3) Pedido de cadastro de pousada: sempre entra como "pendente".
drop policy if exists "lodge_applications_insert_anyone" on lodge_applications;
create policy "lodge_applications_insert_anyone" on lodge_applications
  for insert with check (status = 'pending' and reviewed_at is null);


-- A4) Fotos: cada pessoa só grava dentro da própria pasta (uid/arquivo).
--     Antes, qualquer usuário logado podia gravar em qualquer pasta do bucket.
drop policy if exists "avatars_owner_upload" on storage.objects;
create policy "avatars_owner_upload" on storage.objects for insert
  with check (bucket_id = 'user-avatars' and auth.role() = 'authenticated'
              and split_part(name, '/', 1) = auth.uid()::text);
drop policy if exists "avatars_owner_update" on storage.objects;
create policy "avatars_owner_update" on storage.objects for update
  using (bucket_id = 'user-avatars' and owner = auth.uid());


-- =====================================================================
-- PARTE B — PERFIL SOCIAL
-- =====================================================================

-- B1) Colunas novas
alter table profiles add column if not exists username       text;
alter table profiles add column if not exists bio            text;
alter table profiles add column if not exists cover_url      text;
alter table profiles add column if not exists link_url       text;
alter table profiles add column if not exists profile_public boolean not null default true;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_username_format') then
    alter table profiles add constraint profiles_username_format
      check (username is null or username ~ '^[a-z0-9._]{3,30}$');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_bio_length') then
    alter table profiles add constraint profiles_bio_length
      check (bio is null or char_length(bio) <= 200);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_link_format') then
    alter table profiles add constraint profiles_link_format
      check (link_url is null or (link_url ~* '^https?://[^[:space:]]+$' and char_length(link_url) <= 300));
  end if;
  -- a capa só pode apontar para o nosso próprio armazenamento
  if not exists (select 1 from pg_constraint where conname = 'profiles_cover_own_storage') then
    alter table profiles add constraint profiles_cover_own_storage
      check (cover_url is null or position('/storage/v1/object/public/user-covers/' in cover_url) > 0);
  end if;
end $$;

create unique index if not exists profiles_username_unique on profiles (username);

-- B2) Geração automática do @usuário (para contas novas e antigas)
create or replace function make_username(p_base text)
returns text language plpgsql set search_path = public
as $$
declare b text; cand text; n int := 0;
begin
  b := lower(coalesce(p_base, ''));
  b := translate(b, 'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn');
  b := regexp_replace(b, '[^a-z0-9._]+', '', 'g');
  b := regexp_replace(b, '^[._]+|[._]+$', '', 'g');
  if char_length(b) < 3 then b := 'viajante' || b; end if;
  b := left(b, 24);
  cand := b;
  while exists (select 1 from profiles where username = cand)
     or cand in ('admin','administrador','suporte','support','ecosafari','ecosafarigo','root','api','www','app','perfil','login','equipe','oficial')
  loop
    n := n + 1;
    cand := left(b, 24) || (floor(random() * 9000) + 1000)::int::text;
    exit when n > 50;
  end loop;
  return cand;
end;
$$;

create or replace function set_default_username()
returns trigger language plpgsql set search_path = public
as $$
begin
  if new.username is null then
    new.username := make_username(coalesce(nullif(split_part(coalesce(new.email, ''), '@', 1), ''), new.full_name, 'viajante'));
  end if;
  return new;
end;
$$;
drop trigger if exists trg_set_default_username on profiles;
create trigger trg_set_default_username
  before insert on profiles
  for each row execute function set_default_username();

-- contas que já existiam ganham um @usuário
do $$
declare r record;
begin
  for r in select id, email, full_name from profiles where username is null loop
    update profiles set username = make_username(coalesce(nullif(split_part(coalesce(r.email, ''), '@', 1), ''), r.full_name, 'viajante'))
      where id = r.id;
  end loop;
end $$;


-- B3) Seguidores
create table if not exists follows (
  follower_id uuid not null references profiles(id) on delete cascade,
  followee_id uuid not null references profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index if not exists follows_followee_idx on follows (followee_id);
alter table follows enable row level security;
drop policy if exists "follows_select_involved" on follows;
create policy "follows_select_involved" on follows for select
  using (follower_id = auth.uid() or followee_id = auth.uid());
drop policy if exists "follows_insert_own" on follows;
create policy "follows_insert_own" on follows for insert with check (follower_id = auth.uid());
drop policy if exists "follows_delete_own" on follows;
create policy "follows_delete_own" on follows for delete using (follower_id = auth.uid());


-- B4) Bucket das fotos de capa (cada pessoa só grava na própria pasta)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('user-covers', 'user-covers', true, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = true, file_size_limit = 8388608,
  allowed_mime_types = array['image/jpeg','image/png','image/webp'];
drop policy if exists "covers_public_read" on storage.objects;
create policy "covers_public_read" on storage.objects for select using (bucket_id = 'user-covers');
drop policy if exists "covers_owner_insert" on storage.objects;
create policy "covers_owner_insert" on storage.objects for insert
  with check (bucket_id = 'user-covers' and auth.role() = 'authenticated'
              and split_part(name, '/', 1) = auth.uid()::text);
drop policy if exists "covers_owner_update" on storage.objects;
create policy "covers_owner_update" on storage.objects for update
  using (bucket_id = 'user-covers' and owner = auth.uid());
drop policy if exists "covers_owner_delete" on storage.objects;
create policy "covers_owner_delete" on storage.objects for delete
  using (bucket_id = 'user-covers' and owner = auth.uid());


-- B5) Funções (tudo passa por aqui; o app não lê a tabela profiles de outras pessoas)

-- Cartão do perfil: por @usuário ou por id. Funciona também sem login (link público).
create or replace function get_profile_card(p_username text default null, p_user_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare p profiles; me uuid := auth.uid(); is_me boolean;
        v_posts int; v_species int; v_followers int; v_following int; v_i_follow boolean;
begin
  if p_user_id is not null then
    select * into p from profiles where id = p_user_id;
  elsif p_username is not null then
    select * into p from profiles where username = lower(trim(both '@' from p_username));
  end if;
  if p.id is null then return null; end if;

  is_me := (me is not null and me = p.id);
  select count(*) into v_followers from follows where followee_id = p.id;
  select count(*) into v_following from follows where follower_id = p.id;
  v_i_follow := me is not null and exists (select 1 from follows where follower_id = me and followee_id = p.id);

  if not p.profile_public and not is_me then
    return jsonb_build_object(
      'id', p.id, 'username', p.username, 'full_name', p.full_name, 'avatar_url', p.avatar_url,
      'is_private', true, 'is_me', false, 'is_following', v_i_follow,
      'followers', v_followers, 'following', v_following, 'posts', 0, 'species', 0);
  end if;

  select count(*), count(distinct species_text) into v_posts, v_species
    from sightings where user_id = p.id and status = 'approved';

  return jsonb_build_object(
    'id', p.id, 'username', p.username, 'full_name', p.full_name, 'bio', p.bio,
    'avatar_url', p.avatar_url, 'cover_url', p.cover_url, 'link_url', p.link_url,
    'verified_observer', p.verified_observer, 'profile_public', p.profile_public,
    'is_private', false, 'is_me', is_me, 'is_following', v_i_follow,
    'posts', v_posts, 'species', v_species, 'followers', v_followers, 'following', v_following,
    'member_since', p.created_at);
end;
$$;

-- Publicações aprovadas de uma pessoa (grade do perfil)
create or replace function get_profile_posts(p_user_id uuid, p_limit int default 30, p_offset int default 0)
returns table (
  id uuid, species_text text, description text, photo_url text, photo_thumb_url text,
  video_url text, video_trim_start numeric, observed_at timestamptz,
  created_at timestamptz, likes_count int, is_rare boolean
) language plpgsql stable security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if not exists (select 1 from profiles pr where pr.id = p_user_id and (pr.profile_public or pr.id = me)) then
    return;
  end if;
  return query
    select s.id, s.species_text, s.description, s.photo_url, s.photo_thumb_url,
           s.video_url, s.video_trim_start, s.observed_at,
           s.created_at, s.likes_count, s.is_rare
      from sightings s
     where s.user_id = p_user_id and s.status = 'approved'
     order by s.created_at desc
     limit least(greatest(p_limit, 1), 60) offset greatest(p_offset, 0);
end;
$$;

-- Nome e foto de várias pessoas de uma vez (autores do feed, comentários)
create or replace function get_profiles_basic(p_ids uuid[])
returns table (id uuid, username text, full_name text, avatar_url text, verified_observer boolean)
language sql stable security definer set search_path = public
as $$
  select p.id, p.username, p.full_name, p.avatar_url, p.verified_observer
    from profiles p where p.id = any(p_ids) limit 200;
$$;

-- Seguir / deixar de seguir. Devolve true se agora está seguindo.
create or replace function toggle_follow(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Entre na sua conta para seguir.'; end if;
  if p_user_id = me then raise exception 'Você não pode seguir a si mesmo.'; end if;
  if not exists (select 1 from profiles where id = p_user_id) then raise exception 'Perfil não encontrado.'; end if;
  if exists (select 1 from follows where follower_id = me and followee_id = p_user_id) then
    delete from follows where follower_id = me and followee_id = p_user_id;
    return false;
  end if;
  insert into follows (follower_id, followee_id) values (me, p_user_id);
  return true;
end;
$$;

-- Lista de seguidores / seguindo
create or replace function list_follows(p_user_id uuid, p_kind text, p_limit int default 50, p_offset int default 0)
returns table (id uuid, username text, full_name text, avatar_url text, i_follow boolean)
language plpgsql stable security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if not exists (select 1 from profiles pr where pr.id = p_user_id and (pr.profile_public or pr.id = me)) then
    return;
  end if;
  return query
    select p.id, p.username, p.full_name, p.avatar_url,
           (me is not null and exists (select 1 from follows f2 where f2.follower_id = me and f2.followee_id = p.id))
      from follows f
      join profiles p on p.id = (case when p_kind = 'followers' then f.follower_id else f.followee_id end)
     where (case when p_kind = 'followers' then f.followee_id else f.follower_id end) = p_user_id
       and (p.profile_public or p.id = me)
     order by f.created_at desc
     limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
end;
$$;

-- Buscar pessoas por @usuário ou nome (só perfis públicos)
create or replace function search_profiles(p_q text)
returns table (id uuid, username text, full_name text, avatar_url text, verified_observer boolean)
language plpgsql stable security definer set search_path = public
as $$
declare q text := lower(trim(both '@' from trim(coalesce(p_q, ''))));
begin
  if auth.uid() is null or char_length(q) < 2 then return; end if;
  return query
    select p.id, p.username, p.full_name, p.avatar_url, p.verified_observer
      from profiles p
     where p.profile_public and p.id <> auth.uid()
       and (p.username like replace(replace(q, '%', ''), '_', '\_') || '%' or lower(coalesce(p.full_name, '')) like '%' || replace(replace(q, '%', ''), '_', '\_') || '%')
     order by (p.username = q) desc, p.verified_observer desc, p.username
     limit 20;
end;
$$;

-- Editar o próprio perfil, com validação e mensagens claras
create or replace function update_my_profile(
  p_full_name text, p_username text, p_bio text, p_link_url text, p_profile_public boolean
) returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); u text; l text; n text;
begin
  if me is null then raise exception 'Faça login para editar o perfil.'; end if;

  n := nullif(trim(coalesce(p_full_name, '')), '');
  if n is null or char_length(n) < 2 or char_length(n) > 60 then
    raise exception 'Digite seu nome (2 a 60 letras).';
  end if;

  u := lower(trim(both '@' from trim(coalesce(p_username, ''))));
  if u !~ '^[a-z0-9._]{3,30}$' then
    raise exception 'O @usuário precisa ter de 3 a 30 caracteres: letras minúsculas, números, ponto ou _ (sem espaços ou acentos).';
  end if;
  if u in ('admin','administrador','suporte','support','ecosafari','ecosafarigo','root','api','www','app','perfil','login','equipe','oficial') then
    raise exception 'Esse @usuário não está disponível.';
  end if;
  if exists (select 1 from profiles where username = u and id <> me) then
    raise exception 'Esse @usuário já está em uso. Escolha outro.';
  end if;

  if char_length(coalesce(p_bio, '')) > 200 then
    raise exception 'A bio pode ter no máximo 200 caracteres.';
  end if;

  l := nullif(trim(coalesce(p_link_url, '')), '');
  if l is not null then
    if l !~* '^https?://' then l := 'https://' || l; end if;
    if l !~* '^https?://[^[:space:]]+\.[^[:space:]]+$' or char_length(l) > 300 then
      raise exception 'O link do perfil não parece válido. Exemplo: https://instagram.com/seuperfil';
    end if;
  end if;

  update profiles
     set full_name = n, username = u, bio = nullif(trim(coalesce(p_bio, '')), ''),
         link_url = l, profile_public = coalesce(p_profile_public, true)
   where id = me;

  return get_profile_card(null, me);
end;
$$;

-- Permissões: apenas quem deve chamar cada função
revoke all on function get_profile_card(text, uuid)             from public;
revoke all on function get_profile_posts(uuid, int, int)        from public;
revoke all on function get_profiles_basic(uuid[])               from public;
revoke all on function toggle_follow(uuid)                      from public;
revoke all on function list_follows(uuid, text, int, int)       from public;
revoke all on function search_profiles(text)                    from public;
revoke all on function update_my_profile(text, text, text, text, boolean) from public;
grant execute on function get_profile_card(text, uuid)          to anon, authenticated;   -- link público funciona sem login
grant execute on function get_profile_posts(uuid, int, int)     to anon, authenticated;
grant execute on function get_profiles_basic(uuid[])            to authenticated;
grant execute on function toggle_follow(uuid)                   to authenticated;
grant execute on function list_follows(uuid, text, int, int)    to authenticated;
grant execute on function search_profiles(text)                 to authenticated;
grant execute on function update_my_profile(text, text, text, text, boolean) to authenticated;

-- Exportação de dados (LGPD) passa a incluir quem a pessoa segue
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
    'consentimentos', coalesce((select jsonb_agg(to_jsonb(k) order by k.created_at) from consents k where k.user_id = uid), '[]'),
    'seguindo', coalesce((select jsonb_agg(to_jsonb(f)) from follows f where f.follower_id = uid), '[]'),
    'seguidores', coalesce((select jsonb_agg(to_jsonb(f)) from follows f where f.followee_id = uid), '[]')
  );
end;
$$;


-- Mudança relevante na política de privacidade (perfil público e seguidores):
-- todos precisam aceitar de novo na próxima abertura do app.
update platform_settings set value = '2026-10-21' where key in ('terms_version', 'privacy_version');
-- =====================================================================
-- EcoSafari Go — LOTE 2: SEGURANÇA + FUNCIONALIDADES
-- ---------------------------------------------------------------------
-- Rode DEPOIS de ecosafari-go-migration-social-profile.sql.
-- Pode rodar quantas vezes quiser (idempotente).
--
-- PARTE C  Segurança
--   C1 Equipe não pode "validar estadia" em outra pousada (virava admin dela)
--   C2 Limite de tentativas de código (anti força-bruta)
--   C3 Localização de espécies ameaçadas fica aproximada (anti-caça/tráfico)
--   C4 Menores de 18: perfil sempre privado, sem link externo; cadastro exige idade
--   C5 Denúncia de perfil
-- PARTE D  Funcionalidades
--   D1 Bingo de espécies da pousada
--   D2 Doar moedas para conservação
--   D3 Resumo de valor + orçamento mensal de moedas (painel do dono)
--   D4 Exportação científica (Darwin Core, para GBIF / iNaturalist)
--   D5 Métricas do piloto (admin da plataforma)
-- =====================================================================

-- O valor novo do enum precisa existir antes de ser usado (fora de funções, só aqui).
alter type coin_transaction_type add value if not exists 'donation';


-- =====================================================================
-- C1 + C2) Validação de estadia: só hóspede, com limite de tentativas
-- =====================================================================
create table if not exists code_attempts (
  id          bigserial primary key,
  user_id     uuid not null,
  kind        text not null,
  created_at  timestamptz not null default now()
);
create index if not exists code_attempts_user_idx on code_attempts (user_id, created_at desc);
alter table code_attempts enable row level security;   -- sem políticas: só as funções do banco acessam

create or replace function check_code_attempts(p_uid uuid)
returns void language plpgsql security definer set search_path = public
as $$
begin
  if (select count(*) from code_attempts where user_id = p_uid and created_at > now() - interval '15 minutes') >= 8 then
    raise exception 'Muitas tentativas com código inválido. Aguarde 15 minutos e tente de novo.';
  end if;
end;
$$;

-- Nota técnica: quando o código está errado a função DEVOLVE {ok:false,...} em vez de dar erro,
-- porque um erro desfaria o registro da tentativa e o limite nunca valeria.
create or replace function claim_reservation(p_code text)
returns json language plpgsql security definer set search_path = public
as $$
declare v_role user_role; v_res reservations%rowtype; v_lodge_name text; v_updated integer;
        v_code text := upper(trim(coalesce(p_code, '')));
begin
  if auth.uid() is null then raise exception 'Faça login para validar a reserva.'; end if;
  select role into v_role from profiles where id = auth.uid();
  if v_role is distinct from 'guest' then
    raise exception 'Contas da equipe da pousada não validam estadia como hóspede.';
  end if;
  perform check_code_attempts(auth.uid());

  select * into v_res from reservations where upper(reservation_code) = v_code;
  if v_res.id is null or (v_res.user_id is not null and v_res.user_id <> auth.uid()) then
    insert into code_attempts (user_id, kind) values (auth.uid(), 'reservation');
    return json_build_object('ok', false, 'error', 'Código de reserva não encontrado ou já vinculado a outra conta.');
  end if;

  update reservations set user_id = auth.uid()
    where id = v_res.id and (user_id is null or user_id = auth.uid());
  get diagnostics v_updated = row_count;
  if v_updated = 0 then
    insert into code_attempts (user_id, kind) values (auth.uid(), 'reservation');
    return json_build_object('ok', false, 'error', 'Código de reserva não encontrado ou já vinculado a outra conta.');
  end if;

  update profiles set verified_guest = true, lodge_id = v_res.lodge_id where id = auth.uid();
  select name into v_lodge_name from lodges where id = v_res.lodge_id;
  return json_build_object('ok', true, 'reservation_id', v_res.id, 'lodge_name', v_lodge_name);
end;
$$;

create or replace function claim_lodge_access_code(p_code text)
returns json language plpgsql security definer set search_path = public
as $$
declare v_role user_role; v_lodge lodges%rowtype; v_code text := upper(trim(coalesce(p_code, '')));
begin
  if auth.uid() is null then raise exception 'Faça login para validar o código.'; end if;
  select role into v_role from profiles where id = auth.uid();
  if v_role is distinct from 'guest' then
    raise exception 'Contas da equipe da pousada não validam estadia como hóspede.';
  end if;
  perform check_code_attempts(auth.uid());

  select * into v_lodge from lodges where upper(shared_access_code) = v_code;
  if v_lodge.id is null then
    insert into code_attempts (user_id, kind) values (auth.uid(), 'lodge_code');
    return json_build_object('ok', false, 'error', 'Código de acesso da pousada não encontrado.');
  end if;

  update profiles set verified_guest = true, lodge_id = v_lodge.id where id = auth.uid();
  return json_build_object('ok', true, 'lodge_name', v_lodge.name);
end;
$$;


-- =====================================================================
-- C3) Espécies ameaçadas: a localização pública fica aproximada
-- ---------------------------------------------------------------------
-- Para espécies da lista abaixo, o ponto exato NÃO fica no avistamento
-- (que todo mundo lê). Fica numa tabela privada, visível só para quem
-- publicou, para a equipe da pousada e para a plataforma. O ponto público
-- vira o CENTRO de uma célula de 0,1° (~11 km), o que não permite achar
-- o animal ou o ninho. É a mesma prática do iNaturalist.
-- A lista é editável: insert/delete em sensitive_species_patterns.
-- =====================================================================
create table if not exists sensitive_species_patterns (
  pattern  text primary key,       -- trecho do nome, sem acento não é exigido (usa ILIKE)
  note     text
);
insert into sensitive_species_patterns (pattern, note) values
  ('%onça%',             'Onça-pintada e onça-parda: alvo de caça'),
  ('%panthera onca%',    'Onça-pintada'),
  ('%puma concolor%',    'Onça-parda'),
  ('%ariranha%',         'Ameaçada; tocas'),
  ('%pteronura%',        'Ariranha'),
  ('%harpia%',           'Gavião-real / harpia: ninhos'),
  ('%gavião-real%',      'Harpia: ninhos'),
  ('%arara-azul%',       'Alvo do tráfico; ninhos'),
  ('%anodorhynchus%',    'Araras-azuis'),
  ('%tartaruga%',        'Ninhos e ovos'),
  ('%muriqui%',          'Criticamente ameaçado')
on conflict (pattern) do nothing;
alter table sensitive_species_patterns enable row level security;
drop policy if exists "sensitive_patterns_platform_admin" on sensitive_species_patterns;
create policy "sensitive_patterns_platform_admin" on sensitive_species_patterns
  for all using (is_platform_admin()) with check (is_platform_admin());

create or replace function is_sensitive_species(p_text text)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (select 1 from sensitive_species_patterns where coalesce(p_text, '') ilike pattern);
$$;

create table if not exists sighting_private_locations (
  sighting_id  uuid primary key references sightings(id) on delete cascade deferrable initially deferred,
  user_id      uuid not null,
  lodge_id     uuid,
  lat          double precision not null,
  lng          double precision not null,
  created_at   timestamptz not null default now()
);
alter table sighting_private_locations enable row level security;
drop policy if exists "private_loc_select" on sighting_private_locations;
create policy "private_loc_select" on sighting_private_locations for select
  using (user_id = auth.uid() or is_staff_of_lodge(lodge_id) or is_platform_admin());

alter table sightings add column if not exists location_obscured boolean not null default false;

create or replace function obscure_sensitive_location()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  if new.location_lat is not null and new.location_lng is not null
     and is_sensitive_species(new.species_text) then
    insert into sighting_private_locations (sighting_id, user_id, lodge_id, lat, lng)
      values (new.id, new.user_id, new.lodge_id, new.location_lat, new.location_lng)
      on conflict (sighting_id) do nothing;
    new.location_lat := floor(new.location_lat * 10) / 10 + 0.05;
    new.location_lng := floor(new.location_lng * 10) / 10 + 0.05;
    new.location := ST_SetSRID(ST_MakePoint(new.location_lng, new.location_lat), 4326)::geography;
    new.location_obscured := true;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_01_obscure_sensitive on sightings;
create trigger trg_01_obscure_sensitive
  before insert on sightings
  for each row execute function obscure_sensitive_location();

-- avistamentos que já existiam também passam a ficar aproximados
do $$
declare r record;
begin
  for r in select id, user_id, lodge_id, location_lat, location_lng from sightings
            where location_obscured = false and location_lat is not null and location_lng is not null
              and is_sensitive_species(species_text) loop
    insert into sighting_private_locations (sighting_id, user_id, lodge_id, lat, lng)
      values (r.id, r.user_id, r.lodge_id, r.location_lat, r.location_lng) on conflict do nothing;
    update sightings set location_lat = floor(r.location_lat * 10) / 10 + 0.05,
                         location_lng = floor(r.location_lng * 10) / 10 + 0.05,
                         location = ST_SetSRID(ST_MakePoint(floor(r.location_lng * 10) / 10 + 0.05, floor(r.location_lat * 10) / 10 + 0.05), 4326)::geography,
                         location_obscured = true
      where id = r.id;
  end loop;
end $$;


-- =====================================================================
-- C4) Menores de 18 anos
-- ---------------------------------------------------------------------
-- Perfil sempre privado, fora da busca e sem link externo. No cadastro,
-- a data de nascimento passa a ser obrigatória; de 13 a 17 anos exige a
-- confirmação do responsável (LGPD, art. 14); abaixo de 13 não cadastra.
-- Os dados vêm nos metadados do cadastro, então funcionam mesmo quando
-- a confirmação de e-mail adia o primeiro login.
-- =====================================================================
alter table profiles add column if not exists guardian_consent_at timestamptz;
alter table profiles add column if not exists share_science boolean not null default false;

create or replace function age_years(p_birth date)
returns integer language sql immutable
as $$ select case when p_birth is null then null else date_part('year', age(current_date, p_birth))::int end; $$;

create or replace function enforce_minor_privacy()
returns trigger language plpgsql set search_path = public
as $$
begin
  if new.birth_date is not null and age_years(new.birth_date) < 18 then
    new.profile_public := false;
    new.link_url := null;
    new.share_science := false;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_02_minor_privacy on profiles;
create trigger trg_02_minor_privacy
  before insert or update on profiles
  for each row execute function enforce_minor_privacy();

-- Menores que já existem
update profiles set profile_public = false, link_url = null, share_science = false
 where birth_date is not null and age_years(birth_date) < 18
   and (profile_public or link_url is not null or share_science);

-- O app deixa de gravar a idade depois (o que falhava sem sessão): vem tudo no cadastro.
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
        v_birth date; v_age integer; v_consent boolean := coalesce((m ->> 'guardian_consent')::boolean, false);
begin
  begin v_birth := nullif(m ->> 'birth_date', '')::date; exception when others then v_birth := null; end;
  v_age := age_years(v_birth);
  -- contas criadas pelo painel do Supabase (sem data) continuam funcionando; o app sempre envia a data
  if v_age is not null and v_age < 13 then
    raise exception 'O cadastro é permitido a partir de 13 anos.';
  end if;
  if v_age is not null and v_age < 18 and not v_consent then
    raise exception 'Menores de 18 anos precisam da autorização de um responsável.';
  end if;
  insert into public.profiles (id, email, full_name, birth_date, nationality, guardian_consent_at)
  values (new.id, new.email, m ->> 'full_name', v_birth, nullif(m ->> 'nationality', ''),
          case when v_age is not null and v_age < 18 and v_consent then now() end)
  on conflict (id) do nothing;
  return new;
end;
$$;

-- update_my_profile: menores não publicam perfil nem link
create or replace function update_my_profile(
  p_full_name text, p_username text, p_bio text, p_link_url text, p_profile_public boolean
) returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); u text; l text; n text; v_birth date; v_minor boolean;
begin
  if me is null then raise exception 'Faça login para editar o perfil.'; end if;
  select birth_date into v_birth from profiles where id = me;
  v_minor := v_birth is not null and age_years(v_birth) < 18;

  n := nullif(trim(coalesce(p_full_name, '')), '');
  if n is null or char_length(n) < 2 or char_length(n) > 60 then
    raise exception 'Digite seu nome (2 a 60 letras).';
  end if;

  u := lower(trim(both '@' from trim(coalesce(p_username, ''))));
  if u !~ '^[a-z0-9._]{3,30}$' then
    raise exception 'O @usuário precisa ter de 3 a 30 caracteres: letras minúsculas, números, ponto ou _ (sem espaços ou acentos).';
  end if;
  if u in ('admin','administrador','suporte','support','ecosafari','ecosafarigo','root','api','www','app','perfil','login','equipe','oficial') then
    raise exception 'Esse @usuário não está disponível.';
  end if;
  if exists (select 1 from profiles where username = u and id <> me) then
    raise exception 'Esse @usuário já está em uso. Escolha outro.';
  end if;

  if char_length(coalesce(p_bio, '')) > 200 then
    raise exception 'A bio pode ter no máximo 200 caracteres.';
  end if;

  l := nullif(trim(coalesce(p_link_url, '')), '');
  if l is not null then
    if v_minor then raise exception 'Menores de 18 anos não podem adicionar link externo ao perfil.'; end if;
    if l !~* '^https?://' then l := 'https://' || l; end if;
    if l !~* '^https?://[^[:space:]]+\.[^[:space:]]+$' or char_length(l) > 300 then
      raise exception 'O link do perfil não parece válido. Exemplo: https://instagram.com/seuperfil';
    end if;
  end if;

  update profiles
     set full_name = n, username = u, bio = nullif(trim(coalesce(p_bio, '')), ''),
         link_url = l, profile_public = case when v_minor then false else coalesce(p_profile_public, true) end
   where id = me;

  return get_profile_card(null, me);
end;
$$;

-- O app precisa saber se é menor para esconder o botão "perfil público"
create or replace function my_privacy_flags()
returns jsonb language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'is_minor', coalesce(age_years(birth_date) < 18, false),
    'share_science', share_science)
  from profiles where id = auth.uid();
$$;
revoke all on function my_privacy_flags() from public;
grant execute on function my_privacy_flags() to authenticated;


-- =====================================================================
-- C5) Denúncia de perfil
-- =====================================================================
create table if not exists profile_reports (
  id               uuid primary key default gen_random_uuid(),
  reporter_id      uuid not null references profiles(id) on delete cascade,
  reported_user_id uuid not null references profiles(id) on delete cascade,
  reason           text not null check (reason in ('imagem_impropria','assedio','falso','spam','menor','outro')),
  details          text check (details is null or char_length(details) <= 500),
  status           report_status not null default 'open',
  created_at       timestamptz not null default now()
);
create index if not exists profile_reports_reported_idx on profile_reports (reported_user_id, status);
alter table profile_reports enable row level security;
drop policy if exists "profile_reports_platform_admin" on profile_reports;
create policy "profile_reports_platform_admin" on profile_reports for all
  using (is_platform_admin()) with check (is_platform_admin());

create or replace function report_profile(p_user_id uuid, p_reason text, p_details text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Entre na sua conta para denunciar.'; end if;
  if p_user_id = me then raise exception 'Você não pode denunciar a si mesmo.'; end if;
  if not exists (select 1 from profiles where id = p_user_id) then raise exception 'Perfil não encontrado.'; end if;
  if (select count(*) from profile_reports where reporter_id = me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Limite diário de denúncias atingido.';
  end if;
  if exists (select 1 from profile_reports where reporter_id = me and reported_user_id = p_user_id and status = 'open') then
    return;  -- já denunciado; não duplica
  end if;
  insert into profile_reports (reporter_id, reported_user_id, reason, details)
    values (me, p_user_id, p_reason, left(nullif(trim(coalesce(p_details, '')), ''), 500));
end;
$$;
revoke all on function report_profile(uuid, text, text) from public;
grant execute on function report_profile(uuid, text, text) to authenticated;

-- Lista para o admin da plataforma
create or replace function platform_open_profile_reports()
returns table (id uuid, reported_user_id uuid, reported_username text, reported_name text, reason text, details text, reports_on_user bigint, created_at timestamptz)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_platform_admin() then raise exception 'Acesso restrito.'; end if;
  return query
    select r.id, r.reported_user_id, p.username, p.full_name, r.reason, r.details,
           (select count(*) from profile_reports x where x.reported_user_id = r.reported_user_id and x.status = 'open'), r.created_at
      from profile_reports r join profiles p on p.id = r.reported_user_id
     where r.status = 'open' order by 7 desc, r.created_at desc limit 200;
end;
$$;
revoke all on function platform_open_profile_reports() from public;
grant execute on function platform_open_profile_reports() to authenticated;


-- =====================================================================
-- D1) Bingo de espécies da pousada
-- =====================================================================
create table if not exists lodge_species (
  lodge_id    uuid not null references lodges(id) on delete cascade,
  species_id  uuid not null references species(id) on delete cascade,
  primary key (lodge_id, species_id)
);
alter table lodge_species enable row level security;
drop policy if exists "lodge_species_read" on lodge_species;
create policy "lodge_species_read" on lodge_species for select using (true);

create or replace function admin_set_lodge_species(p_species_ids uuid[])
returns integer language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' or caller_lodge is null then raise exception 'Apenas o administrador da pousada pode editar a lista.'; end if;
  if not mfa_satisfied() then raise exception 'Esta ação exige verificação em duas etapas.'; end if;
  delete from lodge_species where lodge_id = caller_lodge;
  insert into lodge_species (lodge_id, species_id)
    select caller_lodge, s.id from species s
     where s.id = any(coalesce(p_species_ids, '{}')) and (s.lodge_id is null or s.lodge_id = caller_lodge);
  return (select count(*) from lodge_species where lodge_id = caller_lodge);
end;
$$;

-- Lista do hóspede: quais espécies da pousada ele já registrou
create or replace function my_species_checklist()
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare me uuid := auth.uid(); v_lodge uuid; v_custom boolean; v_items jsonb;
begin
  if me is null then return null; end if;
  select lodge_id into v_lodge from profiles where id = me;
  if v_lodge is null then return jsonb_build_object('total', 0, 'seen', 0, 'items', '[]'::jsonb, 'configured', false); end if;
  v_custom := exists (select 1 from lodge_species where lodge_id = v_lodge);

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'name', x.common_name, 'scientific', x.scientific_name, 'category', x.category,
      'seen', x.seen, 'status', x.seen_status, 'lodge_count', x.lodge_count) order by x.seen desc, x.common_name), '[]'::jsonb)
    into v_items
  from (
    select s.id, s.common_name, s.scientific_name, s.category,
      exists (select 1 from sightings g where g.user_id = me and g.lodge_id = v_lodge and g.status in ('pending','approved')
              and (g.species_id = s.id or lower(g.species_text) like lower(s.common_name) || '%')) as seen,
      (select case when bool_or(g.status = 'approved') then 'approved' else 'pending' end from sightings g
        where g.user_id = me and g.lodge_id = v_lodge and g.status in ('pending','approved')
          and (g.species_id = s.id or lower(g.species_text) like lower(s.common_name) || '%')) as seen_status,
      (select count(*) from sightings g where g.lodge_id = v_lodge and g.status = 'approved'
          and (g.species_id = s.id or lower(g.species_text) like lower(s.common_name) || '%')) as lodge_count
    from species s
    where case when v_custom then s.id in (select species_id from lodge_species where lodge_id = v_lodge)
               else (s.lodge_id is null or s.lodge_id = v_lodge) end
  ) x;

  return jsonb_build_object(
    'configured', v_custom,
    'total', jsonb_array_length(v_items),
    'seen', (select count(*) from jsonb_array_elements(v_items) e where (e ->> 'seen')::boolean),
    'items', v_items);
end;
$$;
revoke all on function admin_set_lodge_species(uuid[]) from public;
revoke all on function my_species_checklist() from public;
grant execute on function admin_set_lodge_species(uuid[]) to authenticated;
grant execute on function my_species_checklist() to authenticated;


-- =====================================================================
-- D2) Doar moedas para conservação
-- =====================================================================
create table if not exists coin_donations (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references profiles(id) on delete cascade,
  lodge_id    uuid not null references lodges(id) on delete cascade,
  amount      integer not null check (amount > 0),
  partner     text not null,
  created_at  timestamptz not null default now()
);
create index if not exists coin_donations_lodge_idx on coin_donations (lodge_id, created_at);
alter table coin_donations enable row level security;
drop policy if exists "coin_donations_select" on coin_donations;
create policy "coin_donations_select" on coin_donations for select
  using (user_id = auth.uid() or is_staff_of_lodge(lodge_id) or is_platform_admin());

create or replace function donate_coins(p_amount integer)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid(); v_lodge uuid; v_partner text; v_balance integer;
begin
  if me is null then raise exception 'Faça login para doar.'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000 then raise exception 'Escolha um valor entre 1 e 1000 moedas.'; end if;
  perform pg_advisory_xact_lock(hashtext(me::text));
  select lodge_id into v_lodge from profiles where id = me;
  if v_lodge is null then raise exception 'Valide sua estadia antes de doar.'; end if;
  select conservation_partner into v_partner from lodges where id = v_lodge;
  if v_partner is null or trim(v_partner) = '' then raise exception 'Esta pousada ainda não tem um parceiro de conservação cadastrado.'; end if;
  select coalesce(balance, 0) into v_balance from user_coin_summary where user_id = me and lodge_id = v_lodge;
  if coalesce(v_balance, 0) < p_amount then raise exception 'Saldo insuficiente.'; end if;

  insert into jaguarcoin_transactions (user_id, lodge_id, amount, type, reference_table)
    values (me, v_lodge, -p_amount, 'donation', 'coin_donations');
  insert into coin_donations (user_id, lodge_id, amount, partner) values (me, v_lodge, p_amount, v_partner);
  return jsonb_build_object('partner', v_partner, 'amount', p_amount, 'balance', v_balance - p_amount);
end;
$$;
revoke all on function donate_coins(integer) from public;
grant execute on function donate_coins(integer) to authenticated;


-- =====================================================================
-- D3) Resumo de valor + orçamento mensal de moedas
-- =====================================================================
alter table lodges add column if not exists monthly_coin_budget integer check (monthly_coin_budget is null or monthly_coin_budget >= 0);

create or replace function admin_set_coin_budget(p_budget integer)
returns void language plpgsql security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas o administrador da pousada pode definir o orçamento.'; end if;
  if not mfa_satisfied() then raise exception 'Esta ação exige verificação em duas etapas.'; end if;
  if p_budget is not null and p_budget < 0 then raise exception 'O orçamento não pode ser negativo.'; end if;
  update lodges set monthly_coin_budget = p_budget where id = caller_lodge;
end;
$$;

-- "O que isso me rendeu?" — números dos últimos N dias para o dono
create or replace function admin_value_summary(p_days integer default 30)
returns jsonb language plpgsql stable security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid; v_from timestamptz; v_month timestamptz := date_trunc('month', now());
        v_validated int; v_active int; v_published int; v_budget int; v_used int;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if caller_role <> 'admin' then raise exception 'Apenas o administrador da pousada pode ver o resumo.'; end if;
  if not mfa_satisfied() then raise exception 'Esta ação exige verificação em duas etapas.'; end if;
  p_days := least(greatest(coalesce(p_days, 30), 1), 365);
  v_from := now() - make_interval(days => p_days);

  select count(*) into v_validated from profiles where lodge_id = caller_lodge and role = 'guest' and verified_guest;
  select count(distinct user_id) into v_active from sightings where lodge_id = caller_lodge and created_at >= v_from;
  select count(distinct user_id) into v_published from sightings where lodge_id = caller_lodge and status = 'approved';
  select monthly_coin_budget into v_budget from lodges where id = caller_lodge;
  select coalesce(sum(amount), 0) into v_used from jaguarcoin_transactions
    where lodge_id = caller_lodge and amount > 0 and type in ('sighting_reward', 'checkin_reward') and created_at >= v_month;

  return jsonb_build_object(
    'dias', p_days,
    'hospedes_validados', v_validated,
    'hospedes_ativos', v_active,
    'hospedes_que_publicaram', v_published,
    'taxa_publicacao', case when v_validated > 0 then round(100.0 * v_published / v_validated) else 0 end,
    'avistamentos', (select count(*) from sightings where lodge_id = caller_lodge and created_at >= v_from),
    'aprovados', (select count(*) from sightings where lodge_id = caller_lodge and status = 'approved' and created_at >= v_from),
    'com_foto', (select count(*) from sightings where lodge_id = caller_lodge and status = 'approved' and created_at >= v_from and photo_url is not null),
    'com_video', (select count(*) from sightings where lodge_id = caller_lodge and status = 'approved' and created_at >= v_from and video_url is not null),
    'especies_distintas', (select count(distinct species_text) from sightings where lodge_id = caller_lodge and status = 'approved' and created_at >= v_from),
    'top_especies', coalesce((select jsonb_agg(jsonb_build_object('especie', species_text, 'total', c))
        from (select species_text, count(*) c from sightings where lodge_id = caller_lodge and status = 'approved' and created_at >= v_from
              group by species_text order by c desc limit 5) t), '[]'::jsonb),
    'moedas_emitidas', (select coalesce(sum(amount), 0) from jaguarcoin_transactions where lodge_id = caller_lodge and amount > 0 and created_at >= v_from),
    'moedas_resgatadas', (select coalesce(abs(sum(amount)), 0) from jaguarcoin_transactions where lodge_id = caller_lodge and type = 'redemption' and created_at >= v_from),
    'moedas_doadas', (select coalesce(sum(amount), 0) from coin_donations where lodge_id = caller_lodge and created_at >= v_from),
    'parceiro_conservacao', (select conservation_partner from lodges where id = caller_lodge),
    'orcamento_mensal', v_budget,
    'moedas_emitidas_no_mes', v_used,
    'orcamento_pct', case when coalesce(v_budget, 0) > 0 then round(100.0 * v_used / v_budget) else null end
  );
end;
$$;
revoke all on function admin_set_coin_budget(integer) from public;
revoke all on function admin_value_summary(integer) from public;
grant execute on function admin_set_coin_budget(integer) to authenticated;
grant execute on function admin_value_summary(integer) to authenticated;


-- =====================================================================
-- D4) Exportação científica (Darwin Core → GBIF / iNaturalist)
-- ---------------------------------------------------------------------
-- Só entram avistamentos APROVADOS de quem ativou "compartilhar com a
-- ciência" no perfil. Localização de espécies ameaçadas já sai aproximada.
-- =====================================================================
create or replace function admin_export_darwin_core(p_from date default null, p_to date default null)
returns setof jsonb language plpgsql stable security definer set search_path = public
as $$
declare caller_role user_role; caller_lodge uuid;
begin
  select role, lodge_id into caller_role, caller_lodge from profiles where id = auth.uid();
  if not (caller_role = 'admin' or is_platform_admin()) then raise exception 'Apenas o administrador pode exportar.'; end if;
  if caller_role = 'admin' and not is_platform_admin() and not mfa_satisfied() then
    raise exception 'Esta ação exige verificação em duas etapas.';
  end if;
  return query
    select jsonb_build_object(
      'occurrenceID', 'ecosafari:' || s.id,
      'basisOfRecord', 'HumanObservation',
      'scientificName', coalesce(nullif(substring(s.species_text from '\(([^)]+)\)'), ''), s.species_text),
      'vernacularName', trim(split_part(s.species_text, ' (', 1)),
      'eventDate', to_char(s.observed_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'decimalLatitude', s.location_lat,
      'decimalLongitude', s.location_lng,
      'coordinateUncertaintyInMeters', case when s.location_obscured then 15000 else null end,
      'informationWithheld', case when s.location_obscured then 'Localização aproximada (espécie sensível)' else null end,
      'recordedBy', p.username,
      'associatedMedia', coalesce(s.video_url, s.photo_url),
      'locality', l.name,
      'country', 'BR',
      'license', 'CC BY-NC 4.0',
      'institutionCode', 'EcoSafariGo')
    from sightings s
    join profiles p on p.id = s.user_id
    join lodges l on l.id = s.lodge_id
    where s.status = 'approved' and p.share_science
      and (is_platform_admin() or s.lodge_id = caller_lodge)
      and (p_from is null or s.observed_at >= p_from)
      and (p_to is null or s.observed_at < p_to + 1)
    order by s.observed_at;
end;
$$;
revoke all on function admin_export_darwin_core(date, date) from public;
grant execute on function admin_export_darwin_core(date, date) to authenticated;


-- =====================================================================
-- D5) Métricas do piloto (admin da plataforma)
-- ---------------------------------------------------------------------
-- Responde às perguntas do piloto: quantos hóspedes validaram, quantos
-- publicaram ao menos uma vez e quanto cada pousada gerou.
-- =====================================================================
create or replace function platform_pilot_metrics()
returns table (
  lodge_id uuid, lodge_name text, plan_code text, hospedes_validados bigint, hospedes_que_publicaram bigint,
  taxa_publicacao numeric, avistamentos_aprovados bigint, ativos_30d bigint, ultimo_avistamento timestamptz,
  moedas_emitidas bigint, moedas_resgatadas bigint
) language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_platform_admin() then raise exception 'Acesso restrito.'; end if;
  return query
    select l.id, l.name, l.plan_code,
      (select count(*) from profiles p where p.lodge_id = l.id and p.role = 'guest' and p.verified_guest),
      (select count(distinct s.user_id) from sightings s where s.lodge_id = l.id and s.status = 'approved'),
      case when (select count(*) from profiles p where p.lodge_id = l.id and p.role = 'guest' and p.verified_guest) > 0
        then round(100.0 * (select count(distinct s.user_id) from sightings s where s.lodge_id = l.id and s.status = 'approved')
             / (select count(*) from profiles p where p.lodge_id = l.id and p.role = 'guest' and p.verified_guest), 1) else 0 end,
      (select count(*) from sightings s where s.lodge_id = l.id and s.status = 'approved'),
      (select count(distinct s.user_id) from sightings s where s.lodge_id = l.id and s.created_at > now() - interval '30 days'),
      (select max(s.created_at) from sightings s where s.lodge_id = l.id),
      (select coalesce(sum(t.amount), 0)::bigint from jaguarcoin_transactions t where t.lodge_id = l.id and t.amount > 0),
      (select coalesce(abs(sum(t.amount)), 0)::bigint from jaguarcoin_transactions t where t.lodge_id = l.id and t.type = 'redemption')
    from lodges l order by 5 desc nulls last;
end;
$$;
revoke all on function platform_pilot_metrics() from public;
grant execute on function platform_pilot_metrics() to authenticated;


-- Política de privacidade mudou (menores, compartilhamento científico, CAPTCHA): novo aceite.
update platform_settings set value = '2026-10-22' where key in ('terms_version', 'privacy_version');
-- =====================================================================
-- EcoSafari Go — LOTE 3: CÓDIGO DE ACESSO DA POUSADA (aleatório, único, privado)
-- ---------------------------------------------------------------------
-- Pode rodar quantas vezes quiser (idempotente).
--  * Toda pousada ganha, automaticamente, um código de 9 caracteres
--    sorteado por gerador criptográfico (nunca digitado à mão).
--  * Nunca se repete: o banco impede dois códigos iguais.
--  * O alfabeto não tem 0, 1, I nem O (evita confundir ao ler/digitar).
--  * O código sai da tabela "lodges" (que qualquer pessoa podia ler!) e
--    vai para uma tabela privada. Só o administrador da própria pousada vê.
--  * O administrador pode gerar um novo; o antigo (e o QR impresso) para
--    de funcionar na hora.
-- =====================================================================

create table if not exists lodge_access_codes (
  lodge_id    uuid primary key references lodges(id) on delete cascade,
  code        text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{9}$'),
  rotated_at  timestamptz not null default now(),
  rotated_by  uuid references profiles(id) on delete set null
);
alter table lodge_access_codes enable row level security;
drop policy if exists "lodge_access_codes_platform_admin" on lodge_access_codes;
create policy "lodge_access_codes_platform_admin" on lodge_access_codes for select using (is_platform_admin());
-- ninguém lê/escreve direto pelo app; só pelas funções abaixo
revoke all on lodge_access_codes from public, anon, authenticated;

-- Sorteia um código livre (32 símbolos x 9 posições = ~35 trilhões de combinações)
create or replace function new_lodge_access_code()
returns text language plpgsql volatile security definer set search_path = public, extensions
as $$
declare alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; v text; b bytea; i int; tries int := 0;
begin
  loop
    b := gen_random_bytes(9); v := '';
    for i in 0..8 loop v := v || substr(alphabet, (get_byte(b, i) % 32) + 1, 1); end loop;   -- 256 é múltiplo de 32: sem viés
    exit when not exists (select 1 from lodge_access_codes where code = v);
    tries := tries + 1;
    if tries > 20 then raise exception 'Não foi possível gerar um código único agora. Tente de novo.'; end if;
  end loop;
  return v;
end;
$$;

create or replace function rotate_lodge_access_code(p_lodge uuid, p_by uuid)
returns text language plpgsql security definer set search_path = public, extensions
as $$
declare v text; n int := 0;
begin
  loop
    v := new_lodge_access_code();
    begin
      insert into lodge_access_codes (lodge_id, code, rotated_by) values (p_lodge, v, p_by)
        on conflict (lodge_id) do update set code = excluded.code, rotated_at = now(), rotated_by = excluded.rotated_by;
      return v;
    exception when unique_violation then          -- duas pousadas sortearam o mesmo código no mesmo instante
      n := n + 1; if n > 10 then raise exception 'Não foi possível gerar um código único agora.'; end if;
    end;
  end loop;
end;
$$;
revoke all on function new_lodge_access_code() from public, anon, authenticated;
revoke all on function rotate_lodge_access_code(uuid, uuid) from public, anon, authenticated;

-- Pousada nova já nasce com código
create or replace function create_lodge_access_code_on_insert()
returns trigger language plpgsql security definer set search_path = public, extensions
as $$
begin
  perform rotate_lodge_access_code(new.id, null);
  return new;
end;
$$;
drop trigger if exists trg_create_lodge_access_code on lodges;
create trigger trg_create_lodge_access_code after insert on lodges
  for each row execute function create_lodge_access_code_on_insert();

-- Pousadas existentes sem código ganham um (não troca quem já tem: pode rodar de novo)
do $$ declare l record; begin
  for l in select id from lodges where id not in (select lodge_id from lodge_access_codes) loop
    perform rotate_lodge_access_code(l.id, null);
  end loop;
end $$;

-- Os códigos antigos (legíveis por qualquer pessoa na tabela lodges) são apagados
update lodges set shared_access_code = null where shared_access_code is not null;

-- ---------------------------------------------------------------------
-- Funções do administrador da pousada
-- ---------------------------------------------------------------------
create or replace function admin_get_access_code()
returns text language plpgsql stable security definer set search_path = public
as $$
declare v_role user_role; v_lodge uuid; v_code text;
begin
  select role, lodge_id into v_role, v_lodge from profiles where id = auth.uid();
  if v_role is distinct from 'admin' or v_lodge is null then raise exception 'Apenas administradores da pousada veem o código.'; end if;
  select code into v_code from lodge_access_codes where lodge_id = v_lodge;
  return v_code;
end;
$$;

create or replace function admin_generate_shared_access_code()
returns text language plpgsql security definer set search_path = public
as $$
declare v_role user_role; v_lodge uuid;
begin
  select role, lodge_id into v_role, v_lodge from profiles where id = auth.uid();
  if v_role is distinct from 'admin' or v_lodge is null then raise exception 'Apenas administradores podem gerar um novo código.'; end if;
  return rotate_lodge_access_code(v_lodge, auth.uid());
end;
$$;
drop function if exists admin_set_shared_access_code(text);   -- código digitado à mão não existe mais
revoke all on function admin_get_access_code() from public, anon;
revoke all on function admin_generate_shared_access_code() from public, anon;
grant execute on function admin_get_access_code() to authenticated;
grant execute on function admin_generate_shared_access_code() to authenticated;

-- ---------------------------------------------------------------------
-- Hóspede valida a estadia (com limite de tentativas)
-- Aceita maiúsculas/minúsculas, espaços e hífens: "ktes-t2345" = "KTEST2345"
-- ---------------------------------------------------------------------
create or replace function claim_lodge_access_code(p_code text)
returns json language plpgsql security definer set search_path = public
as $$
declare v_role user_role; v_lodge lodges%rowtype; v_code text := regexp_replace(upper(coalesce(p_code, '')), '[^A-Z0-9]', '', 'g');
begin
  if auth.uid() is null then raise exception 'Faça login para validar o código.'; end if;
  select role into v_role from profiles where id = auth.uid();
  if v_role is distinct from 'guest' then
    raise exception 'Contas da equipe da pousada não validam estadia como hóspede.';
  end if;
  perform check_code_attempts(auth.uid());

  select l.* into v_lodge from lodge_access_codes c join lodges l on l.id = c.lodge_id where c.code = v_code;
  if v_lodge.id is null then
    insert into code_attempts (user_id, kind) values (auth.uid(), 'lodge_code');
    return json_build_object('ok', false, 'error', 'Código da pousada não encontrado. Confira ou escaneie o QR code de novo.');
  end if;

  update profiles set verified_guest = true, lodge_id = v_lodge.id where id = auth.uid();
  return json_build_object('ok', true, 'lodge_name', v_lodge.name);
end;
$$;
revoke all on function claim_lodge_access_code(text) from public, anon;
grant execute on function claim_lodge_access_code(text) to authenticated;
