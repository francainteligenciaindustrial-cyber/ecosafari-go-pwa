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
