reset role;
update platform_settings set value='false' where key='staff_mfa_required';
-- 1) toda pousada existente tem código válido e distinto
do $$ declare n int; d int; bad int; begin
  select count(*) into n from lodges; select count(distinct code) into d from lodge_access_codes;
  select count(*) into bad from lodge_access_codes where code !~ '^[A-HJ-NP-Z2-9]{9}$';
  if n <> d or bad > 0 then raise exception 'FALHA codigos existentes n=% d=% bad=%', n, d, bad; end if;
  if exists (select 1 from lodges where shared_access_code is not null) then raise exception 'FALHA codigo antigo ainda legivel em lodges'; end if;
  raise notice 'OK L3-1 toda pousada tem codigo valido e unico; coluna antiga zerada';
end $$;
-- 2) pousada nova já nasce com código; 500 pousadas = 500 códigos diferentes
do $$ declare n int; d int; begin
  insert into lodges (name, slug, address, location, geofence_radius_meters, plan_code)
    select 'Pousada '||g, 'p-'||g, 'x', 'SRID=4326;POINT(-56 -17)'::geography, 500, 'free' from generate_series(1,500) g;
  select count(*), count(distinct code) into n, d from lodge_access_codes;
  if n <> d then raise exception 'FALHA repetiu codigo'; end if;
  raise notice 'OK L3-2 % codigos, todos diferentes', n;
end $$;
-- 3) permissões: hóspede não lê a tabela nem chama a função; admin só vê o da própria pousada
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ begin
  declare n int; begin
    select count(*) into n from lodge_access_codes;   -- sem privilégio (erro) ou RLS sem política (0 linhas): os dois protegem
    if n > 0 then raise exception 'FALHA hospede leu % codigos', n; end if;
    raise notice 'OK L3-3a hospede enxerga 0 codigos na tabela';
  exception when insufficient_privilege then raise notice 'OK L3-3a hospede sem acesso a tabela'; end;
  begin perform admin_get_access_code(); raise exception 'FALHA hospede pegou codigo';
  exception when others then if sqlerrm like '%Apenas administradores%' then raise notice 'OK L3-3b hospede nao pega codigo'; else raise; end if; end;
  begin perform admin_generate_shared_access_code(); raise exception 'FALHA hospede gerou codigo';
  exception when others then if sqlerrm like '%Apenas administradores%' then raise notice 'OK L3-3c hospede nao gera codigo'; else raise; end if; end;
end $$;
-- 4) admin gera novo: o antigo morre, o novo funciona (com hífen/minúsculas)
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',false);
select set_config('request.jwt.claims','{"aal":"aal2"}',false);
create temp table _c(old text, new text);
grant all on _c to authenticated;
insert into _c(old) select admin_get_access_code();
update _c set new = admin_generate_shared_access_code();
do $$ declare o text; nw text; r json; begin
  select old, new into o, nw from _c;
  if o = nw then raise exception 'FALHA codigo nao mudou'; end if;
  if admin_get_access_code() <> nw then raise exception 'FALHA get != novo'; end if;
  raise notice 'OK L3-4a admin gerou novo codigo %', length(nw);
end $$;
reset role;
update profiles set lodge_id=null, verified_guest=false where id='33333333-3333-3333-3333-333333333333';
set role authenticated;
select set_config('request.jwt.claim.sub','33333333-3333-3333-3333-333333333333',false);
do $$ declare o text; nw text; r json; begin
  select old, new into o, nw from _c;
  r := claim_lodge_access_code(o);
  if (r->>'ok')::boolean then raise exception 'FALHA codigo antigo ainda vale'; end if;
  r := claim_lodge_access_code(lower(substr(nw,1,3)||'-'||substr(nw,4,3)||' '||substr(nw,7,3)));
  if not (r->>'ok')::boolean then raise exception 'FALHA codigo novo recusado %', r; end if;
  raise notice 'OK L3-4b antigo recusado, novo aceito (minusculas/hifen/espaco)';
end $$;
-- 5) código manual não existe mais
reset role;
do $$ begin
  if exists (select 1 from pg_proc where proname = 'admin_set_shared_access_code') then raise exception 'FALHA funcao manual ainda existe'; end if;
  raise notice 'OK L3-5 sem codigo manual';
end $$;
