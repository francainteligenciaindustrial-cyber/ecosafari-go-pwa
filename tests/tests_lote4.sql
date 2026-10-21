reset role;
update platform_settings set value='false' where key='staff_mfa_required';
-- 33.. = hospedeiro (A), 44.. = ana (B). os dois públicos, com avistamento aprovado de B
update profiles set profile_public=true, username='aaa_host' where id='33333333-3333-3333-3333-333333333333';
update profiles set profile_public=true, username='bbb_ana', lodge_id=(select id from lodges limit 1), verified_guest=true where id='44444444-4444-4444-4444-444444444444';
delete from follows;
insert into follows(follower_id,followee_id) values ('33333333-3333-3333-3333-333333333333','44444444-4444-4444-4444-444444444444'),('44444444-4444-4444-4444-444444444444','33333333-3333-3333-3333-333333333333');
insert into sightings(user_id,lodge_id,species_text,status) select '44444444-4444-4444-4444-444444444444',(select id from lodges limit 1),'Tuiuiú-L4','approved';
insert into sighting_comments(sighting_id,user_id,body) select id,'44444444-4444-4444-4444-444444444444','oi' from sightings where species_text='Tuiuiú-L4' limit 1;

set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
-- antes do bloqueio: A enxerga B
do $$ declare n int; begin
  select count(*) into n from sightings where species_text='Tuiuiú-L4'; if n<>1 then raise exception 'FALHA base feed %', n; end if;
  select count(*) into n from sighting_comments; if n<1 then raise exception 'FALHA base comentarios'; end if;
  if get_profile_card('bbb_ana') is null then raise exception 'FALHA base perfil'; end if;
  raise notice 'OK L4-0 antes do bloqueio A enxerga B';
end $$;
-- A bloqueia B
do $$ declare r boolean; begin r := toggle_block('44444444-4444-4444-4444-444444444444'); if not r then raise exception 'FALHA nao bloqueou'; end if; end $$;
do $$ declare n int; c jsonb; begin
  select count(*) into n from sightings where species_text='Tuiuiú-L4'; if n<>0 then raise exception 'FALHA A ainda ve avistamento de B'; end if;
  select count(*) into n from sighting_comments where user_id='44444444-4444-4444-4444-444444444444'; if n<>0 then raise exception 'FALHA A ve comentario de B'; end if;
  c := get_profile_card('bbb_ana'); if not (c->>'is_blocked')::boolean or (c->>'posts')::int <> 0 then raise exception 'FALHA cartao bloqueado %', c; end if;
  if exists (select 1 from get_profile_posts('44444444-4444-4444-4444-444444444444')) then raise exception 'FALHA posts de bloqueado'; end if;
  if exists (select 1 from search_profiles('bbb')) then raise exception 'FALHA busca acha bloqueado'; end if;
  begin perform toggle_follow('44444444-4444-4444-4444-444444444444'); raise exception 'FALHA seguiu bloqueado';
  exception when others then if sqlerrm like '%Não é possível seguir%' then null; else raise; end if; end;
  if (select count(*) from list_blocks()) <> 1 then raise exception 'FALHA list_blocks'; end if;
  raise notice 'OK L4-1 A nao ve feed/comentarios/perfil/busca de B; nao segue';
end $$;
reset role;
do $$ begin
  if exists (select 1 from follows where (follower_id,followee_id) in (('33333333-3333-3333-3333-333333333333','44444444-4444-4444-4444-444444444444'),('44444444-4444-4444-4444-444444444444','33333333-3333-3333-3333-333333333333'))) then raise exception 'FALHA follows nao removidos'; end if;
  raise notice 'OK L4-2 seguidores dos dois lados removidos';
end $$;
-- B (bloqueado) não vê A nem acha o perfil
set role authenticated;
select set_config('request.jwt.claim.sub','44444444-4444-4444-4444-444444444444',false);
do $$ begin
  if get_profile_card('aaa_host') is not null then raise exception 'FALHA B abre perfil de A'; end if;
  if exists (select 1 from search_profiles('aaa')) then raise exception 'FALHA B acha A'; end if;
  raise notice 'OK L4-3 bloqueado nao encontra quem bloqueou';
end $$;
-- ninguém grava direto na tabela
do $$ begin
  begin insert into user_blocks values ('44444444-4444-4444-4444-444444444444','33333333-3333-3333-3333-333333333333'); raise exception 'FALHA insert direto';
  exception when insufficient_privilege then raise notice 'OK L4-4 sem insert direto';
            when others then if sqlerrm like '%FALHA%' then raise; else raise notice 'OK L4-4 sem insert direto (%)', sqlerrm; end if; end;
end $$;
-- desbloquear devolve tudo
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ declare n int; begin
  if toggle_block('44444444-4444-4444-4444-444444444444') then raise exception 'FALHA nao desbloqueou'; end if;
  select count(*) into n from sightings where species_text='Tuiuiú-L4'; if n<>1 then raise exception 'FALHA feed nao voltou'; end if;
  raise notice 'OK L4-5 desbloqueio restaura o feed';
end $$;
reset role;
