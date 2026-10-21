-- reset: hospede (33..) e dono (11..) vêm de tests.sql
reset role;
update platform_settings set value='false' where key='staff_mfa_required';
insert into auth.users (id,email,raw_user_meta_data) values ('44444444-4444-4444-4444-444444444444','ana@x.com','{"full_name":"Ana"}') on conflict do nothing;
update profiles set lodge_id=(select id from lodges limit 1), verified_guest=true where id='44444444-4444-4444-4444-444444444444';
update profiles set role='guest', verified_observer=false where email='hosp@x.com';

-- ===== A1: escalada de privilégio bloqueada =====
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
select set_config('request.jwt.claims','{"aal":"aal1"}',false);
do $$ begin
  begin update profiles set role='admin' where id=auth.uid(); raise exception 'FALHA: virou admin';
  exception when others then if sqlerrm like '%não é permitida%' then raise notice 'OK A1 role bloqueado'; else raise; end if; end;
  begin update profiles set verified_observer=true where id=auth.uid(); raise exception 'FALHA: auto-verificou';
  exception when others then if sqlerrm like '%não é permitida%' then raise notice 'OK A1 verified_observer bloqueado'; else raise; end if; end;
  begin update profiles set lodge_id=gen_random_uuid() where id=auth.uid(); raise exception 'FALHA: trocou pousada';
  exception when others then if sqlerrm like '%não é permitida%' or sqlerrm like '%foreign key%' then raise notice 'OK A1 lodge_id bloqueado'; else raise; end if; end;
  update profiles set theme_preference='light' where id=auth.uid();
  raise notice 'OK A1 tema continua editavel';
end $$;

-- ===== A2: avistamento sempre pendente, na própria pousada =====
do $$ declare sid uuid; st text; lg uuid; mine uuid;
begin
  select lodge_id into mine from profiles where id=auth.uid();
  insert into sightings(lodge_id,user_id,species_text,status,is_rare,likes_count,video_check_status)
    values (gen_random_uuid(), auth.uid(), 'Tuiuiú', 'approved', true, 99, 'ok') returning id into sid;
  select status::text, lodge_id into st, lg from sightings where id=sid;
  if st <> 'pending' or lg is distinct from mine then raise exception 'FALHA A2 st=% lg=%', st, lg; end if;
  if (select is_rare or likes_count<>0 or video_check_status<>'not_applicable' from sightings where id=sid) then raise exception 'FALHA A2 campos'; end if;
  raise notice 'OK A2 sighting forçado a pending';
end $$;

-- ===== A3: pedido de pousada só pendente =====
reset role; set role anon;
do $$ begin
  begin insert into lodge_applications(lodge_name,address,tax_id,applicant_name,applicant_email,status) values('X','R','1','Y','z@z.com','approved'); raise exception 'FALHA A3';
  exception when others then if sqlerrm like '%row-level security%' then raise notice 'OK A3 aplicação aprovada bloqueada'; else raise; end if; end;
  insert into lodge_applications(lodge_name,address,tax_id,applicant_name,applicant_email) values('Pousada Teste','Rua 1','123','Fulano','f@f.com');
  raise notice 'OK A3 aplicação pendente aceita';
end $$;
reset role;

-- ===== B: perfil social =====
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ declare c jsonb; begin
  c := update_my_profile('Eliton Silva','Eliton_Silva','Biólogo e fotógrafo 🌿','instagram.com/eliton','true'::boolean);
  if c->>'username' <> 'eliton_silva' or c->>'link_url' <> 'https://instagram.com/eliton' then raise exception 'FALHA B update %', c; end if;
  raise notice 'OK B update_my_profile normaliza usuario e link';
  begin perform update_my_profile('Eliton','ab','', null, true); raise exception 'FALHA curto'; exception when others then if sqlerrm like '%3 a 30%' then raise notice 'OK B usuario curto barrado'; else raise; end if; end;
  begin perform update_my_profile('Eliton','com espaço','', null, true); raise exception 'FALHA espaco'; exception when others then if sqlerrm like '%3 a 30%' then raise notice 'OK B espaco barrado'; else raise; end if; end;
  begin perform update_my_profile('Eliton','admin','', null, true); raise exception 'FALHA reservado'; exception when others then if sqlerrm like '%disponível%' then raise notice 'OK B reservado barrado'; else raise; end if; end;
  begin perform update_my_profile('Eliton','eliton_silva','', 'javascript:alert(1)', true); raise exception 'FALHA js link'; exception when others then if sqlerrm like '%link%' then raise notice 'OK B link javascript barrado'; else raise; end if; end;
  begin perform update_my_profile('Eliton','dono','', null, true); raise exception 'FALHA duplicado'; exception when others then if sqlerrm like '%já está em uso%' then raise notice 'OK B duplicado barrado'; else raise; end if; end;
  begin update profiles set cover_url='https://evil.com/x.jpg' where id=auth.uid(); raise exception 'FALHA capa externa'; exception when others then if sqlerrm like '%cover_own_storage%' then raise notice 'OK B capa externa barrada'; else raise; end if; end;
  update profiles set cover_url='https://abc.supabase.co/storage/v1/object/public/user-covers/33/c.jpg' where id=auth.uid();
  raise notice 'OK B capa do storage aceita';
end $$;

-- seguir
do $$ declare r boolean; c jsonb; begin
  r := toggle_follow('44444444-4444-4444-4444-444444444444');
  if not r then raise exception 'FALHA follow'; end if;
  c := get_profile_card('ana', null);
  if (c->>'followers')::int <> 1 or not (c->>'is_following')::boolean then raise exception 'FALHA contagem %', c; end if;
  begin perform toggle_follow(auth.uid()); raise exception 'FALHA self-follow'; exception when others then if sqlerrm like '%a si mesmo%' then raise notice 'OK B auto-follow barrado'; else raise; end if; end;
  raise notice 'OK B follow + contadores';
  if (select count(*) from list_follows('44444444-4444-4444-4444-444444444444','followers')) <> 1 then raise exception 'FALHA list followers'; end if;
  if (select count(*) from list_follows('33333333-3333-3333-3333-333333333333','following')) <> 1 then raise exception 'FALHA list following'; end if;
  if (select count(*) from search_profiles('an')) <> 1 then raise exception 'FALHA search'; end if;
  raise notice 'OK B listas e busca';
  r := toggle_follow('44444444-4444-4444-4444-444444444444');
  if r then raise exception 'FALHA unfollow'; end if;
  raise notice 'OK B unfollow';
end $$;

-- ações diretas em follows: não dá para seguir "em nome" de outro
do $$ begin
  begin insert into follows(follower_id, followee_id) values ('44444444-4444-4444-4444-444444444444','33333333-3333-3333-3333-333333333333'); raise exception 'FALHA follow em nome de outro';
  exception when others then if sqlerrm like '%row-level security%' then raise notice 'OK B follow forjado barrado'; else raise; end if; end;
end $$;

-- aprova um post da Ana (como staff, via SQL) e confere perfil público anônimo
reset role;
insert into sightings(lodge_id,user_id,species_text,status,photo_url) select lodge_id,id,'Arara-azul','approved','http://x/p.jpg' from profiles where id='44444444-4444-4444-4444-444444444444';
set role anon;
select set_config('request.jwt.claim.sub','',false);
do $$ declare c jsonb; n int; begin
  c := get_profile_card('ana', null);
  if c->>'username' <> 'ana' or (c->>'posts')::int <> 1 then raise exception 'FALHA publico anon %', c; end if;
  if c ? 'email' then raise exception 'FALHA vazou email'; end if;
  select count(*) into n from get_profile_posts('44444444-4444-4444-4444-444444444444');
  if n <> 1 then raise exception 'FALHA posts anon %', n; end if;
  raise notice 'OK B perfil publico visivel sem login, sem e-mail';
  begin perform toggle_follow('44444444-4444-4444-4444-444444444444'); raise exception 'FALHA anon follow'; exception when others then if sqlerrm like '%permission denied%' then raise notice 'OK B anon nao segue'; else raise; end if; end;
end $$;

-- perfil privado
reset role;
update profiles set profile_public=false where id='44444444-4444-4444-4444-444444444444';
set role anon;
do $$ declare c jsonb; n int; begin
  c := get_profile_card('ana', null);
  if (c->>'is_private')::boolean is not true or c ? 'bio' or (c->>'posts')::int <> 0 then raise exception 'FALHA privado %', c; end if;
  select count(*) into n from get_profile_posts('44444444-4444-4444-4444-444444444444');
  if n <> 0 then raise exception 'FALHA posts privado'; end if;
  raise notice 'OK B perfil privado oculta bio e posts';
end $$;
reset role;

-- funções internas (RPC) continuam podendo mexer nas colunas protegidas
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select set_config('request.jwt.claims','{"aal":"aal2"}',false);
do $$ begin
  perform admin_create_reservation('Z-1', current_date, current_date+1);
  raise notice 'OK RPC admin continua funcionando';
exception when undefined_function then raise notice 'skip admin_create_reservation assinatura';
end $$;
reset role;
select 'FIM' as fim;
