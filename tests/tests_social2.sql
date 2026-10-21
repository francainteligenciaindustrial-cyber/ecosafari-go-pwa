reset role;
update platform_settings set value='false' where key='staff_mfa_required';
update lodges set shared_access_code='ARL-TESTE1', conservation_partner='Instituto Conservação Pantanal' where id=(select id from lodges limit 1);
-- dono vira admin da plataforma também (para testar as funções restritas)
insert into platform_admins(user_id) values ('11111111-1111-1111-1111-111111111111') on conflict do nothing;
-- ana (guest sem pousada) e hosp (guest da pousada)
update profiles set lodge_id=null, verified_guest=false where id='44444444-4444-4444-4444-444444444444';
update profiles set profile_public=true where id='44444444-4444-4444-4444-444444444444';

-- ===== C1/C2: validação de estadia =====
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select set_config('request.jwt.claims','{"aal":"aal2"}',false);
do $$ begin
  begin perform claim_lodge_access_code('ARL-TESTE1'); raise exception 'FALHA staff validou';
  exception when others then if sqlerrm like '%Contas da equipe%' then raise notice 'OK C1 equipe nao valida estadia'; else raise; end if; end;
end $$;
select set_config('request.jwt.claim.sub','44444444-4444-4444-4444-444444444444',false);
do $$ declare r json; i int; begin
  for i in 1..8 loop
    r := claim_lodge_access_code('ERRADO'||i);
    if (r->>'ok')::boolean then raise exception 'FALHA aceitou codigo errado'; end if;
  end loop;
  begin perform claim_lodge_access_code('ARL-TESTE1'); raise exception 'FALHA sem limite';
  exception when others then if sqlerrm like '%Muitas tentativas%' then raise notice 'OK C2 bloqueio apos 8 erros (mesmo com codigo certo)'; else raise; end if; end;
end $$;
reset role; delete from code_attempts where user_id='44444444-4444-4444-4444-444444444444';
set role authenticated;
select set_config('request.jwt.claim.sub','44444444-4444-4444-4444-444444444444',false);
do $$ declare r json; begin
  r := claim_lodge_access_code(' arl-teste1 ');
  if not (r->>'ok')::boolean then raise exception 'FALHA codigo certo %', r; end if;
  raise notice 'OK C2 codigo certo aceito (case/espacos)';
end $$;
reset role;

-- ===== C3: espécie ameaçada com localização aproximada =====
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ declare sid uuid; sid2 uuid; la double precision; ob boolean; d double precision; begin
  insert into sightings(species_text, location_lat, location_lng) values ('Onça-Pintada (Panthera onca)', -16.7414, -56.7325) returning id into sid;
  insert into sightings(species_text, location_lat, location_lng) values ('Capivara (Hydrochoerus hydrochaeris)', -16.7414, -56.7325) returning id into sid2;
  select location_lat, location_obscured into la, ob from sightings where id = sid;
  if not ob or la = -16.7414 then raise exception 'FALHA onca nao ocultada lat=% ob=%', la, ob; end if;
  select ST_Distance(ST_SetSRID(ST_MakePoint(location_lng, location_lat),4326)::geography, ST_SetSRID(ST_MakePoint(-56.7325,-16.7414),4326)::geography) into d from sightings where id = sid;
  if d > 9000 then raise exception 'FALHA aproximacao longe demais %', d; end if;
  if (select location_lat from sightings where id = sid2) <> -16.7414 or (select location_obscured from sightings where id = sid2) then raise exception 'FALHA capivara alterada'; end if;
  if (select count(*) from sighting_private_locations where sighting_id = sid2) <> 0 then raise exception 'FALHA privado capivara'; end if;
  if (select lat from sighting_private_locations where sighting_id = sid) <> -16.7414 then raise exception 'FALHA ponto exato nao guardado'; end if;
  raise notice 'OK C3 onca aproximada (a % m), capivara intacta, exato guardado so no privado', round(d);
end $$;
select set_config('request.jwt.claim.sub','44444444-4444-4444-4444-444444444444',false);
do $$ begin
  if (select count(*) from sighting_private_locations) <> 0 then raise exception 'FALHA outro hospede ve ponto exato'; end if;
  raise notice 'OK C3 outro hospede nao ve o ponto exato';
end $$;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
do $$ begin
  if (select count(*) from sighting_private_locations) < 1 then raise exception 'FALHA equipe nao ve ponto exato'; end if;
  raise notice 'OK C3 equipe da pousada ve o ponto exato';
end $$;
reset role;

-- ===== C4: menores =====
do $$ declare u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); u3 uuid := gen_random_uuid(); u4 uuid := gen_random_uuid(); begin
  begin insert into auth.users(id,email,raw_user_meta_data) values (u1,'k10@x.com', jsonb_build_object('full_name','Kid','birth_date',(current_date - interval '10 years')::date::text,'guardian_consent',true)); raise exception 'FALHA aceitou 10 anos';
  exception when others then if sqlerrm like '%13 anos%' then raise notice 'OK C4 menor de 13 barrado'; else raise; end if; end;
  begin insert into auth.users(id,email,raw_user_meta_data) values (u2,'k15@x.com', jsonb_build_object('full_name','Teen','birth_date',(current_date - interval '15 years')::date::text)); raise exception 'FALHA aceitou 15 sem responsavel';
  exception when others then if sqlerrm like '%responsável%' then raise notice 'OK C4 15 anos exige responsavel'; else raise; end if; end;
  insert into auth.users(id,email,raw_user_meta_data) values (u3,'k15b@x.com', jsonb_build_object('full_name','Teen OK','birth_date',(current_date - interval '15 years')::date::text,'guardian_consent',true,'nationality','Brasileira'));
  if (select profile_public from profiles where id=u3) or (select guardian_consent_at from profiles where id=u3) is null then raise exception 'FALHA perfil menor publico'; end if;
  insert into auth.users(id,email,raw_user_meta_data) values (u4,'adult@x.com', jsonb_build_object('full_name','Adulto','birth_date',(current_date - interval '30 years')::date::text));
  if not (select profile_public from profiles where id=u4) then raise exception 'FALHA adulto nao publico'; end if;
  raise notice 'OK C4 menor 15 com responsavel: perfil privado; adulto: publico';
  perform set_config('t.minor', u3::text, false);
end $$;
set role authenticated;
select set_config('request.jwt.claim.sub', current_setting('t.minor'), false);
do $$ declare c jsonb; begin
  begin perform update_my_profile('Teen OK','teen.ok','', 'https://instagram.com/x', true); raise exception 'FALHA menor com link';
  exception when others then if sqlerrm like '%Menores de 18%' then raise notice 'OK C4 menor sem link externo'; else raise; end if; end;
  c := update_my_profile('Teen OK','teen.ok','oi', null, true);
  if (c->>'profile_public')::boolean then raise exception 'FALHA menor ficou publico'; end if;
  begin update profiles set profile_public = true where id = auth.uid(); end;
  if (select profile_public from profiles where id = auth.uid()) then raise exception 'FALHA menor forcou publico direto'; end if;
  if (select count(*) from search_profiles('teen')) <> 0 then raise exception 'FALHA menor na busca'; end if;
  raise notice 'OK C4 menor nao fica publico nem na busca';
end $$;
reset role;

-- ===== C5: denúncia =====
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ begin
  perform report_profile('44444444-4444-4444-4444-444444444444','spam','x');
  perform report_profile('44444444-4444-4444-4444-444444444444','spam','x');
  if (select count(*) from profile_reports) <> 0 then null; end if; -- hóspede nem lê a tabela
  begin perform report_profile(auth.uid(),'spam'); raise exception 'FALHA auto-denuncia'; exception when others then if sqlerrm like '%a si mesmo%' then raise notice 'OK C5 auto-denuncia barrada'; else raise; end if; end;
  begin perform platform_open_profile_reports(); raise exception 'FALHA lista aberta'; exception when others then if sqlerrm like '%restrito%' then raise notice 'OK C5 lista so para admin da plataforma'; else raise; end if; end;
end $$;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
do $$ begin
  if (select count(*) from platform_open_profile_reports()) <> 1 then raise exception 'FALHA denuncia duplicada ou ausente'; end if;
  raise notice 'OK C5 denuncia registrada uma vez';
end $$;
reset role;

-- ===== D1: bingo =====
insert into species(common_name, scientific_name, category) values ('Onça-Pintada','Panthera onca','mamífero'),('Capivara','Hydrochoerus hydrochaeris','mamífero'),('Tuiuiú','Jabiru mycteria','ave') on conflict do nothing;
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ declare c jsonb; begin
  c := my_species_checklist();
  if (c->>'seen')::int < 2 then raise exception 'FALHA bingo seen %', c->>'seen'; end if;
  raise notice 'OK D1 bingo: viu % de % (catalogo completo)', c->>'seen', c->>'total';
end $$;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
do $$ declare n int; c jsonb; begin
  n := admin_set_lodge_species(array(select id from species where common_name in ('Tuiuiú','Capivara')));
  if n <> 2 then raise exception 'FALHA set species %', n; end if;
  raise notice 'OK D1 admin definiu lista da pousada (2 especies)';
end $$;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ declare c jsonb; begin
  c := my_species_checklist();
  if (c->>'total')::int <> 2 or not (c->>'configured')::boolean or (c->>'seen')::int <> 2 then raise exception 'FALHA bingo custom %', c; end if;
  raise notice 'OK D1 bingo respeita a lista da pousada (viu 2 de 2: Tuiuiú e Capivara)';
end $$;
select set_config('request.jwt.claim.sub','44444444-4444-4444-4444-444444444444',false);
do $$ begin
  begin perform admin_set_lodge_species(array[]::uuid[]); raise exception 'FALHA hospede editou lista'; exception when others then if sqlerrm like '%administrador%' then raise notice 'OK D1 hospede nao edita lista'; else raise; end if; end;
end $$;
reset role;

-- ===== D2: doação =====
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ declare r jsonb; b0 int; begin
  select balance into b0 from user_coin_summary where user_id=auth.uid();
  r := donate_coins(3);
  if (r->>'balance')::int <> b0 - 3 then raise exception 'FALHA saldo apos doar %', r; end if;
  begin perform donate_coins(5000); raise exception 'FALHA doou demais'; exception when others then if sqlerrm like '%entre 1 e 1000%' then raise notice 'OK D2 limite de valor'; else raise; end if; end;
  begin perform donate_coins(900); raise exception 'FALHA doou sem saldo'; exception when others then if sqlerrm like '%Saldo insuficiente%' then raise notice 'OK D2 sem saldo nao doa'; else raise; end if; end;
  raise notice 'OK D2 doacao de 3 moedas; saldo %', r->>'balance';
end $$;
reset role;
select count(*) as doacoes_ledger from jaguarcoin_transactions where type='donation';

-- ===== D3: resumo e orçamento =====
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
do $$ declare s jsonb; begin
  perform admin_set_coin_budget(100);
  s := admin_value_summary(30);
  if (s->>'hospedes_validados')::int < 1 or (s->>'orcamento_mensal')::int <> 100 or s->>'orcamento_pct' is null then raise exception 'FALHA resumo %', s; end if;
  if (s->>'moedas_doadas')::int <> 3 then raise exception 'FALHA doadas %', s->>'moedas_doadas'; end if;
  raise notice 'OK D3 resumo: validados %, orcamento % usado %%%', s->>'hospedes_validados', s->>'orcamento_mensal', s->>'orcamento_pct';
end $$;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ begin
  begin perform admin_value_summary(30); raise exception 'FALHA hospede viu resumo'; exception when others then if sqlerrm like '%administrador%' then raise notice 'OK D3 hospede nao ve resumo'; else raise; end if; end;
end $$;
reset role;

-- ===== D4: exportação científica =====
update sightings set status='approved' where user_id='33333333-3333-3333-3333-333333333333';
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
do $$ declare n int; begin
  select count(*) into n from admin_export_darwin_core(); 
  if n <> 0 then raise exception 'FALHA exportou sem consentimento %', n; end if;
  raise notice 'OK D4 sem consentimento nada e exportado';
end $$;
reset role;
update profiles set share_science = true where id='33333333-3333-3333-3333-333333333333';
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
do $$ declare r jsonb; n int; begin
  select count(*) into n from admin_export_darwin_core();
  if n < 2 then raise exception 'FALHA exportacao n=%', n; end if;
  select x into r from admin_export_darwin_core() x where x->>'vernacularName' like 'Onça%' limit 1;
  if (r->>'coordinateUncertaintyInMeters')::int <> 15000 or r->>'scientificName' <> 'Panthera onca' or (r->>'decimalLatitude')::float = -16.7414 then raise exception 'FALHA darwin core onca %', r; end if;
  raise notice 'OK D4 exporta % registros; onca sai aproximada e com cientifico', n;
end $$;
reset role;

-- ===== D5: métricas do piloto =====
set role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
do $$ declare n int; begin
  select count(*) into n from platform_pilot_metrics();
  if n < 1 then raise exception 'FALHA pilot'; end if;
  raise notice 'OK D5 metricas do piloto (% pousada)', n;
end $$;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ begin
  begin perform platform_pilot_metrics(); raise exception 'FALHA hospede viu metricas'; exception when others then if sqlerrm like '%restrito%' then raise notice 'OK D5 so admin da plataforma'; else raise; end if; end;
end $$;
reset role;
select 'FIM2' as fim;
