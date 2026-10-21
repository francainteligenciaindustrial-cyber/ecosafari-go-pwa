-- =====================================================================
-- EcoSafari Go — LOTE 4: BLOQUEAR USUÁRIO (exigido pelas lojas de aplicativos)
-- ---------------------------------------------------------------------
-- Pode rodar quantas vezes quiser (idempotente). Rode DEPOIS do social-profile.
--  * Quem bloqueia some do feed, dos comentários, da busca e das listas da
--    pessoa bloqueada, e vice-versa. Seguidores dos dois lados são removidos.
--  * Quem foi bloqueado não consegue abrir o perfil de quem bloqueou.
-- =====================================================================

create table if not exists user_blocks (
  blocker_id uuid not null references profiles(id) on delete cascade,
  blocked_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index if not exists user_blocks_blocked_idx on user_blocks (blocked_id);
alter table user_blocks enable row level security;
drop policy if exists "user_blocks_select_own" on user_blocks;
create policy "user_blocks_select_own" on user_blocks for select using (blocker_id = auth.uid());
-- gravação só pelas funções abaixo
revoke insert, update, delete on user_blocks from anon, authenticated;

create or replace function is_blocked_between(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select coalesce(a is not null and b is not null and exists (
    select 1 from user_blocks where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)), false);
$$;
revoke all on function is_blocked_between(uuid, uuid) from public;
grant execute on function is_blocked_between(uuid, uuid) to anon, authenticated;

-- Bloqueia / desbloqueia. Devolve true se agora está bloqueado.
create or replace function toggle_block(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Entre na sua conta para bloquear.'; end if;
  if p_user_id = me then raise exception 'Você não pode bloquear a si mesmo.'; end if;
  if not exists (select 1 from profiles where id = p_user_id) then raise exception 'Perfil não encontrado.'; end if;
  if exists (select 1 from user_blocks where blocker_id = me and blocked_id = p_user_id) then
    delete from user_blocks where blocker_id = me and blocked_id = p_user_id;
    return false;
  end if;
  insert into user_blocks (blocker_id, blocked_id) values (me, p_user_id);
  delete from follows where (follower_id = me and followee_id = p_user_id) or (follower_id = p_user_id and followee_id = me);
  return true;
end;
$$;

create or replace function list_blocks()
returns table (id uuid, username text, full_name text, avatar_url text)
language sql stable security definer set search_path = public
as $$
  select p.id, p.username, p.full_name, p.avatar_url
    from user_blocks b join profiles p on p.id = b.blocked_id
   where b.blocker_id = auth.uid() order by b.created_at desc;
$$;
revoke all on function toggle_block(uuid), list_blocks() from public, anon;
grant execute on function toggle_block(uuid), list_blocks() to authenticated;

-- Feed e comentários respeitam o bloqueio (nos dois sentidos)
drop policy if exists "sightings_select" on sightings;
create policy "sightings_select" on sightings
  for select using (
    (status = 'approved' and not is_blocked_between(auth.uid(), user_id))
    or user_id = auth.uid() or is_staff_of_lodge(lodge_id));
drop policy if exists "comments_select_all" on sighting_comments;
create policy "comments_select_all" on sighting_comments
  for select using (not is_blocked_between(auth.uid(), user_id));

-- Funções do perfil, agora com bloqueio
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
  if not is_me and me is not null and is_blocked_between(me, p.id) then
    if exists (select 1 from user_blocks where blocker_id = me and blocked_id = p.id) then
      -- eu bloqueei: mostro só o básico, com a opção de desbloquear
      return jsonb_build_object('id', p.id, 'username', p.username, 'full_name', p.full_name, 'avatar_url', p.avatar_url,
        'is_private', true, 'is_me', false, 'is_following', false, 'is_blocked', true,
        'followers', 0, 'following', 0, 'posts', 0, 'species', 0);
    end if;
    return null;   -- quem foi bloqueado não encontra o perfil
  end if;
  select count(*) into v_followers from follows where followee_id = p.id;
  select count(*) into v_following from follows where follower_id = p.id;
  v_i_follow := me is not null and exists (select 1 from follows where follower_id = me and followee_id = p.id);

  if not p.profile_public and not is_me then
    return jsonb_build_object(
      'id', p.id, 'username', p.username, 'full_name', p.full_name, 'avatar_url', p.avatar_url,
      'is_private', true, 'is_me', false, 'is_following', v_i_follow, 'is_blocked', false,
      'followers', v_followers, 'following', v_following, 'posts', 0, 'species', 0);
  end if;

  select count(*), count(distinct species_text) into v_posts, v_species
    from sightings where user_id = p.id and status = 'approved';

  return jsonb_build_object(
    'id', p.id, 'username', p.username, 'full_name', p.full_name, 'bio', p.bio,
    'avatar_url', p.avatar_url, 'cover_url', p.cover_url, 'link_url', p.link_url,
    'verified_observer', p.verified_observer, 'profile_public', p.profile_public,
    'is_private', false, 'is_me', is_me, 'is_following', v_i_follow, 'is_blocked', false,
    'posts', v_posts, 'species', v_species, 'followers', v_followers, 'following', v_following,
    'member_since', p.created_at);
end;
$$;

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
  if me is not null and is_blocked_between(me, p_user_id) then return; end if;
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
       and (me is null or not is_blocked_between(me, p.id))
     order by f.created_at desc
     limit least(greatest(p_limit, 1), 100) offset greatest(p_offset, 0);
end;
$$;

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
     where p.profile_public and p.id <> auth.uid() and not is_blocked_between(auth.uid(), p.id)
       and (p.username like replace(replace(q, '%', ''), '_', '\_') || '%' or lower(coalesce(p.full_name, '')) like '%' || replace(replace(q, '%', ''), '_', '\_') || '%')
     order by (p.username = q) desc, p.verified_observer desc, p.username
     limit 20;
end;
$$;

create or replace function toggle_follow(p_user_id uuid)
returns boolean language plpgsql security definer set search_path = public
as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Entre na sua conta para seguir.'; end if;
  if p_user_id = me then raise exception 'Você não pode seguir a si mesmo.'; end if;
  if not exists (select 1 from profiles where id = p_user_id) then raise exception 'Perfil não encontrado.'; end if;
  if is_blocked_between(me, p_user_id) then raise exception 'Não é possível seguir este perfil.'; end if;
  if exists (select 1 from follows where follower_id = me and followee_id = p_user_id) then
    delete from follows where follower_id = me and followee_id = p_user_id;
    return false;
  end if;
  insert into follows (follower_id, followee_id) values (me, p_user_id);
  return true;
end;
$$;

revoke all on function get_profile_card(text, uuid) from public;
revoke all on function get_profile_posts(uuid, int, int) from public;
revoke all on function list_follows(uuid, text, int, int) from public;
revoke all on function search_profiles(text) from public;
revoke all on function toggle_follow(uuid) from public;
grant execute on function get_profile_card(text, uuid) to anon, authenticated;
grant execute on function get_profile_posts(uuid, int, int) to anon, authenticated;
grant execute on function list_follows(uuid, text, int, int) to authenticated;
grant execute on function search_profiles(text) to authenticated;
grant execute on function toggle_follow(uuid) to authenticated;
