--@@
grant usage on schema public, auth, storage to anon, authenticated; grant all on all tables in schema public to anon, authenticated; grant all on all sequences in schema public to anon, authenticated; grant execute on all functions in schema auth to anon, authenticated;
--@@
-- usuários
--@@
insert into auth.users (id,email,raw_user_meta_data) values
 ('11111111-1111-1111-1111-111111111111','dono@x.com','{"full_name":"Dono"}'),
 ('22222222-2222-2222-2222-222222222222','guia@x.com','{"full_name":"Guia"}'),
 ('33333333-3333-3333-3333-333333333333','hosp@x.com','{"full_name":"Hosp"}');
--@@
update profiles set role='admin', lodge_id=(select id from lodges limit 1) where email='dono@x.com';
--@@
update profiles set lodge_id=(select id from lodges limit 1), verified_guest=true where email='hosp@x.com';
--@@
insert into reservations(lodge_id,user_id,reservation_code,check_in_date,check_out_date) select id,'33333333-3333-3333-3333-333333333333','R-1',current_date,current_date+1 from lodges limit 1;
--@@
insert into jaguarcoin_transactions(user_id,lodge_id,amount,type) select '33333333-3333-3333-3333-333333333333',id,10,'sighting_reward' from lodges limit 1;

--@@
-- 0) views respeitam RLS: um usuário qualquer não vê contatos de pousadas nem e-mails
--@@
set role authenticated;
--@@
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
--@@
do $$ declare n int; begin
  select count(*) into n from platform_returning_guests; if n<>0 then raise exception 'vazamento returning_guests'; end if;
  select count(*) into n from platform_lodge_overview where contact_email is not null; 
  select count(*) into n from user_coin_summary where user_id <> auth.uid(); if n<>0 then raise exception 'vazamento coin summary'; end if;
  raise notice 'views ok';
end $$;

--@@
-- 1) consentimento + exportação
--@@
select record_consent(true, 'test-agent');
--@@
do $$ declare j jsonb; begin
  j := export_my_data();
  if jsonb_array_length(j->'consentimentos') <> 3 then raise exception 'consent count'; end if;
  if (j->'perfil'->>'terms_version_accepted') is null then raise exception 'terms not set'; end if;
  if jsonb_array_length(j->'moedas') <> 1 then raise exception 'moedas'; end if;
  raise notice 'lgpd ok';
end $$;

--@@
-- 4) convite de equipe
--@@
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
--@@
do $$ declare c text; begin
  c := admin_invite_staff('GUIA@x.com','guide');
  perform set_config('test.code', c, false);
  raise notice 'invite %', c;
end $$;
--@@
select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',false);
--@@
select accept_staff_invite(current_setting('test.code'));
--@@
reset role;
--@@
do $$ begin if (select role from profiles where email='guia@x.com') <> 'guide' then raise exception 'invite fail'; end if; raise notice 'invite ok'; end $$;

--@@
-- 2) auditoria: admin cria benefício
--@@
set role authenticated;
--@@
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
--@@
select admin_create_benefit('Caipirinha', 20);
--@@
do $$ begin if (select count(*) from audit_log where table_name='benefits') < 1 then raise exception 'audit benefits'; end if;
  if (select count(*) from audit_log where table_name='profiles') < 1 then raise exception 'audit profiles'; end if; raise notice 'audit ok'; end $$;
--@@
select admin_monthly_report(current_date) is not null as report_ok;
--@@
select count(*) as staff from admin_list_staff();

--@@
-- 3) 2FA obrigatório
--@@
reset role;
--@@
update platform_settings set value='true' where key='staff_mfa_required';
--@@
set role authenticated;
--@@
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
--@@
select set_config('request.jwt.claims','{"aal":"aal1"}',false);
--@@
do $$ begin
  begin perform admin_create_benefit('Bloqueado', 5); raise exception 'mfa nao bloqueou';
  exception when others then if sqlerrm like '%duas etapas%' then raise notice 'mfa bloqueou ok'; else raise; end if; end;
end $$;
--@@
select set_config('request.jwt.claims','{"aal":"aal2"}',false);
--@@
select admin_create_benefit('Liberado', 5) is not null as mfa_aal2_ok;
--@@
-- hóspede sem 2FA continua resgatando normal
--@@
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
--@@
select set_config('request.jwt.claims','{"aal":"aal1"}',false);
--@@
select length(redeem_benefit((select id from benefits where name='Liberado'))) > 0 as guest_redeem_ok;
--@@
reset role;
--@@
select apply_data_retention();
--@@
select set_config('request.jwt.claim.sub','',false); select count(*) as group_rows from my_group_overview();
