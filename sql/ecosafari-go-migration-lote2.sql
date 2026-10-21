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
