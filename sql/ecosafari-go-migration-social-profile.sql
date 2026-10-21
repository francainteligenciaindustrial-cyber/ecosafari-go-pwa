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
