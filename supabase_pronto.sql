-- =====================================================================
-- Hospital de Amor — Gestão Logística e Atendimento · BANCO DE DADOS v3
--
-- COMO USAR: Supabase → SQL Editor → New query → cole TODO este arquivo → Run.
-- Pode ser rodado de novo quantas vezes quiser: NÃO apaga pacientes.
-- Serve tanto para um projeto novo quanto para atualizar a versão anterior.
--
-- Novidades da v3:
--   • perfis de acesso: Administrador e Usuário padrão
--   • auditoria: quem criou / quem alterou cada ficha, e quando
--   • painel de configuração dos alertas (dias de antecedência)
--   • consultas otimizadas para o Dashboard
--   • importação de pacientes por planilha
--
-- DEPOIS DE RODAR, defina o(s) administrador(es) (passo obrigatório):
--   select public.tornar_admin('seu-email@exemplo.com', 'Seu Nome');
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. FUNÇÕES AUXILIARES (texto e datas)
-- ---------------------------------------------------------------------

-- Normaliza nomes para comparação: minúsculas, sem acento, sem espaços sobrando.
-- "  José  da SILVA " e "jose da silva" ficam iguais.
create or replace function public.sem_acento(t text) returns text
language sql immutable parallel safe set search_path = '' as $$
  select regexp_replace(
           translate(lower(btrim(coalesce(t, ''))),
                     'áàâãäåéèêëíìîïóòôõöúùûüçñ',
                     'aaaaaaeeeeiiiiooooouuuucn'),
           '\s+', ' ', 'g');
$$;

-- Lista (sem repetição) das especialidades dos agendamentos de um paciente.
-- Usada numa coluna calculada automaticamente, para o Dashboard não precisar
-- abrir o JSON de cada paciente a cada consulta.
create or replace function public.lista_especialidades(ag jsonb) returns text[]
language sql immutable parallel safe set search_path = '' as $$
  select coalesce(array_agg(distinct btrim(a ->> 'spec'))
                    filter (where coalesce(btrim(a ->> 'spec'), '') <> ''), '{}')
  from jsonb_array_elements(case when jsonb_typeof(ag) = 'array' then ag else '[]'::jsonb end) as a;
$$;

-- Limpa uma lista de agendamentos vinda de fora (backup ou planilha):
-- só aceita data no formato aaaa-mm-dd e descarta linhas totalmente vazias.
create or replace function public.limpar_agendamentos(ag jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'date',   case when coalesce(a ->> 'date', '') ~ '^\d{4}-\d{2}-\d{2}$' then a ->> 'date' else '' end,
           'spec',   btrim(coalesce(a ->> 'spec', '')),
           'doctor', btrim(coalesce(a ->> 'doctor', ''))) order by t.o), '[]'::jsonb)
  from jsonb_array_elements(case when jsonb_typeof(ag) = 'array' then ag else '[]'::jsonb end)
       with ordinality as t(a, o)
  where jsonb_typeof(a) = 'object'
    and (coalesce(a ->> 'date', '') ~ '^\d{4}-\d{2}-\d{2}$' or coalesce(btrim(a ->> 'spec'), '') <> ''
         or coalesce(btrim(a ->> 'doctor'), '') <> '');
$$;

-- Converte texto em data/hora; se for inválido devolve vazio (null) em vez de dar erro.
create or replace function public.ts_ou_nulo(t text) returns timestamptz
language plpgsql stable set search_path = '' as $$
begin
  return nullif(btrim(t), '')::timestamptz;
exception when others then
  return null;
end $$;


-- ---------------------------------------------------------------------
-- 1. EQUIPE AUTORIZADA E PERFIS DE ACESSO
--    Só quem estiver nesta tabela vê os dados. "papel" define o perfil:
--      admin   → acesso total (cadastros, usuários, alertas, importação, backup)
--      usuario → dashboard, relatórios, consultar/cadastrar/editar pacientes
--    Depois de pronto, o administrador gerencia a equipe pela aba "Usuários".
-- ---------------------------------------------------------------------
create table if not exists public.equipe (
  email     text primary key,
  nome      text not null default '',
  criado_em timestamptz not null default now()
);
alter table public.equipe add column if not exists papel text not null default 'usuario';
do $$ begin
  alter table public.equipe add constraint equipe_papel_check check (papel in ('admin', 'usuario'));
exception when duplicate_object then null; end $$;
alter table public.equipe enable row level security;   -- sem políticas: só as funções abaixo mexem nela

-- A pessoa logada está na equipe?
create or replace function public.is_equipe() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.equipe e
    where lower(btrim(e.email)) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- A pessoa logada é administradora?
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.equipe e
    where lower(btrim(e.email)) = lower(coalesce(auth.jwt() ->> 'email', ''))
      and e.papel = 'admin'
  );
$$;

-- Perfil de quem está logado (o site usa para mostrar/esconder as abas de administrador).
-- Devolve vazio (null) se o e-mail não estiver na equipe.
create or replace function public.meu_perfil() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('email', lower(btrim(e.email)), 'nome', e.nome, 'papel', e.papel)
  from public.equipe e
  where lower(btrim(e.email)) = lower(coalesce(auth.jwt() ->> 'email', ''))
  order by (e.papel = 'admin') desc
  limit 1;
$$;

-- Nomes da equipe (para mostrar "Alterado por Ana" em vez do e-mail). Só para a equipe.
create or replace function public.equipe_nomes() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('email', lower(btrim(e.email)), 'nome', e.nome)), '[]'::jsonb)
  from public.equipe e
  where public.is_equipe();
$$;

-- Lista da equipe com perfil, se já tem login criado e o último acesso (só administrador).
create or replace function public.listar_equipe() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare r jsonb;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem ver a lista de usuários' using errcode = '42501';
  end if;
  -- com o login (auth.users) dá para mostrar se a pessoa já tem acesso criado e quando entrou
  if to_regclass('auth.users') is not null then
    begin
      select coalesce(jsonb_agg(jsonb_build_object(
               'email', lower(btrim(e.email)), 'nome', e.nome, 'papel', e.papel, 'criado_em', e.criado_em,
               'tem_login', u.id is not null, 'ultimo_acesso', u.last_sign_in_at)
             order by (e.papel = 'admin') desc, lower(e.nome), lower(e.email)), '[]'::jsonb)
        into r
        from public.equipe e
        left join auth.users u on lower(u.email) = lower(btrim(e.email));
    exception when others then
      r := null;   -- sem permissão para ler os logins: segue sem essa informação
    end;
  end if;
  if r is null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'email', lower(btrim(e.email)), 'nome', e.nome, 'papel', e.papel, 'criado_em', e.criado_em,
             'tem_login', null, 'ultimo_acesso', null)
           order by (e.papel = 'admin') desc, lower(e.nome), lower(e.email)), '[]'::jsonb)
      into r
      from public.equipe e;
  end if;
  return r;
end $$;

-- Inclui ou atualiza alguém da equipe (só administrador).
-- Impede tirar o último administrador (para ninguém ficar trancado para fora).
create or replace function public.salvar_membro(p_email text, p_nome text default '', p_papel text default 'usuario')
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_papel text := coalesce(nullif(btrim(p_papel), ''), 'usuario');
  v_atual text;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem gerenciar usuários' using errcode = '42501';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido: %', p_email; end if;
  if v_papel not in ('admin', 'usuario') then raise exception 'Perfil inválido: %', p_papel; end if;
  perform 1 from public.equipe where papel = 'admin' for update;   -- evita duas alterações ao mesmo tempo
  select papel into v_atual from public.equipe where lower(btrim(email)) = v_email limit 1;
  if found then
    if v_atual = 'admin' and v_papel <> 'admin'
       and (select count(*) from public.equipe where papel = 'admin') <= 1 then
      raise exception 'Não é possível tirar o último administrador. Promova outra pessoa antes.';
    end if;
    update public.equipe set nome = btrim(coalesce(p_nome, '')), papel = v_papel
     where lower(btrim(email)) = v_email;
  else
    insert into public.equipe (email, nome, papel) values (v_email, btrim(coalesce(p_nome, '')), v_papel);
  end if;
end $$;

-- Remove alguém da equipe (só administrador). Não remove a si mesmo nem o último administrador.
create or replace function public.remover_membro(p_email text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_email text := lower(btrim(coalesce(p_email, ''))); v_papel text;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem gerenciar usuários' using errcode = '42501';
  end if;
  if v_email = lower(coalesce(auth.jwt() ->> 'email', '')) then
    raise exception 'Você não pode remover o seu próprio acesso.';
  end if;
  perform 1 from public.equipe where papel = 'admin' for update;
  select papel into v_papel from public.equipe where lower(btrim(email)) = v_email limit 1;
  if not found then return; end if;
  if v_papel = 'admin' and (select count(*) from public.equipe where papel = 'admin') <= 1 then
    raise exception 'Não é possível remover o último administrador.';
  end if;
  delete from public.equipe where lower(btrim(email)) = v_email;
end $$;

-- Define um administrador. Para ser rodada AQUI no SQL Editor (o site não consegue chamá-la):
--   select public.tornar_admin('seu-email@exemplo.com', 'Seu Nome');
create or replace function public.tornar_admin(p_email text, p_nome text default null)
returns text language plpgsql security invoker set search_path = '' as $$
declare v_email text := lower(btrim(coalesce(p_email, '')));
begin
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail inválido: %', p_email; end if;
  update public.equipe set papel = 'admin', nome = coalesce(nullif(btrim(p_nome), ''), nome)
   where lower(btrim(email)) = v_email;
  if not found then
    insert into public.equipe (email, nome, papel) values (v_email, coalesce(btrim(p_nome), ''), 'admin');
  end if;
  return v_email || ' agora é administrador(a)';
end $$;


-- ---------------------------------------------------------------------
-- 2. PACIENTES
-- ---------------------------------------------------------------------
create table if not exists public.patients (
  id            uuid primary key default gen_random_uuid(),
  pid           text default '',
  name          text not null,
  city          text default '',
  estado        text default 'SE' check (estado in ('SE','AL','PE','BA')),
  phone         text default '',
  agendamentos  jsonb not null default '[]'::jsonb,   -- [{date, spec, doctor}]
  obs           text default '',
  status        text not null default 'Ativo' check (status in ('Ativo','Atendido','Óbito')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid default auth.uid(),
  updated_by    uuid default auth.uid()
);

-- Auditoria: e-mail de quem criou e de quem fez a última alteração
alter table public.patients add column if not exists created_by_email text;
alter table public.patients add column if not exists updated_by_email text;

-- Coluna calculada pelo próprio banco (ninguém digita nela): especialidades do paciente
alter table public.patients add column if not exists especialidades_lista text[]
  generated always as (public.lista_especialidades(agendamentos)) stored;

-- Índices: deixam as buscas rápidas mesmo com dezenas de milhares de pacientes
create index if not exists patients_estado_idx         on public.patients (estado);
create index if not exists patients_name_idx           on public.patients (name);
create index if not exists patients_created_at_idx     on public.patients (created_at);                   -- novos cadastros por dia/semana
create index if not exists patients_pid_idx            on public.patients (pid) where pid <> '';          -- importação (procura pelo ID)
create index if not exists patients_nome_norm_idx      on public.patients (public.sem_acento(name));      -- importação (procura pelo nome)
create index if not exists patients_especialidades_idx on public.patients using gin (especialidades_lista); -- filtro por especialidade

-- Preenche sozinho a data e o autor de cada criação/alteração.
-- O site NÃO consegue falsificar esses campos: o banco sempre sobrescreve
-- com o usuário logado (exceto dentro da restauração de backup feita por administrador,
-- que preserva as datas e autores originais do arquivo).
create or replace function public.auditar_patient() returns trigger
language plpgsql set search_path = '' as $$
declare
  v_email     text    := nullif(lower(coalesce(auth.jwt() ->> 'email', '')), '');
  v_uid       uuid    := auth.uid();
  v_preservar boolean := coalesce(current_setting('app.preservar_auditoria', true), '') = 'on';
begin
  -- agendamentos sempre no formato certo: data aaaa-mm-dd, textos simples, sem itens vazios
  -- (impede que alguém grave conteúdo estranho direto pela API, por fora do site)
  new.agendamentos := public.limpar_agendamentos(new.agendamentos);
  if tg_op = 'INSERT' then
    if v_preservar then
      new.created_at       := coalesce(new.created_at, now());
      new.updated_at       := coalesce(new.updated_at, new.created_at);
    else
      new.created_at       := now();
      new.created_by       := v_uid;
      new.created_by_email := v_email;
      new.updated_at       := new.created_at;
      new.updated_by       := v_uid;
      new.updated_by_email := v_email;
    end if;
  else  -- UPDATE
    if not v_preservar then
      new.created_at       := old.created_at;         -- data de criação nunca muda
      new.created_by       := old.created_by;
      new.created_by_email := old.created_by_email;
      new.updated_at       := clock_timestamp();      -- também detecta duas pessoas editando a mesma ficha
      new.updated_by       := v_uid;
      new.updated_by_email := v_email;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_touch_patient   on public.patients;   -- gatilho da versão anterior
drop function if exists public.touch_patient();
drop trigger if exists trg_auditar_patient on public.patients;
create trigger trg_auditar_patient before insert or update on public.patients
  for each row execute function public.auditar_patient();

-- Fichas antigas: padroniza os agendamentos (sem mudar datas/autores de alteração)
do $$ begin
  perform set_config('app.preservar_auditoria', 'on', true);
  update public.patients set agendamentos = agendamentos
   where agendamentos is distinct from public.limpar_agendamentos(agendamentos);
  perform set_config('app.preservar_auditoria', 'off', true);
end $$;

-- Para fichas antigas: descobre o e-mail de quem criou/alterou a partir do login (auth.users)
do $$ begin
  if to_regclass('auth.users') is not null then
    perform set_config('app.preservar_auditoria', 'on', true);
    update public.patients p set created_by_email = lower(u.email)
      from auth.users u where p.created_by_email is null and u.id = p.created_by;
    update public.patients p set updated_by_email = lower(u.email)
      from auth.users u where p.updated_by_email is null and u.id = p.updated_by;
    perform set_config('app.preservar_auditoria', 'off', true);
  end if;
exception when insufficient_privilege then
  raise notice 'Sem permissão para ler auth.users: fichas antigas ficam sem o autor (as novas registram normalmente).';
end $$;


-- ---------------------------------------------------------------------
-- 3. ESPECIALIDADES E MÉDICOS (um registro por linha)
-- ---------------------------------------------------------------------
create table if not exists public.especialidades (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null check (btrim(nome) <> ''),
  criado_em timestamptz not null default now()
);
create unique index if not exists especialidades_nome_key on public.especialidades (lower(nome));

create table if not exists public.medicos (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null check (btrim(nome) <> ''),
  especialidade text not null default '',
  criado_em     timestamptz not null default now()
);
create unique index if not exists medicos_nome_key on public.medicos (lower(nome));

-- Lista inicial (só entra se a tabela estiver vazia)
insert into public.especialidades (nome)
select x from unnest(array[
  'Cabeça e Pescoço','Cirurgia Oncológica','Cuidados Paliativos','Dermatologia / Pele',
  'Digestivo Alto','Digestivo Baixo','Endoscopia','Exames de Imagem','Ginecologia Oncológica',
  'Hematologia','Mastologia','Neuro-oncologia','Oncologia Clínica','Oncologia Pediátrica',
  'Ortopedia Oncológica','Prevenção','Quimioterapia','Radioterapia','Sarcoma','Tórax','Urologia'
]) as x
where not exists (select 1 from public.especialidades);


-- ---------------------------------------------------------------------
-- 4. CONFIGURAÇÕES DO SISTEMA (uma única linha) — regra dos alertas
--    alerta_dias: com quantos dias de antecedência o alerta dispara
--    alerta_modo: 'exato'     → alerta só no dia que faltam exatamente N dias
--                 'ate_o_dia' → alerta todos os dias, de N dias antes até o dia da consulta
-- ---------------------------------------------------------------------
create table if not exists public.configuracoes (
  id             smallint primary key default 1 check (id = 1),
  alerta_dias    integer not null default 2 check (alerta_dias between 0 and 60),
  alerta_modo    text not null default 'exato' check (alerta_modo in ('exato', 'ate_o_dia')),
  atualizado_em  timestamptz not null default now(),
  atualizado_por text
);
insert into public.configuracoes (id) values (1) on conflict (id) do nothing;

create or replace function public.auditar_configuracoes() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.id             := 1;
  new.atualizado_em  := now();
  new.atualizado_por := nullif(lower(coalesce(auth.jwt() ->> 'email', '')), '');
  return new;
end $$;
drop trigger if exists trg_auditar_configuracoes on public.configuracoes;
create trigger trg_auditar_configuracoes before update on public.configuracoes
  for each row execute function public.auditar_configuracoes();


-- ---------------------------------------------------------------------
-- 5. FUNÇÕES USADAS PELO SITE (cada uma roda inteira ou não roda nada)
-- ---------------------------------------------------------------------

-- Corrige o nome de uma especialidade na lista, nos médicos e em todos os agendamentos (admin)
create or replace function public.renomear_especialidade(p_antigo text, p_novo text)
returns void language plpgsql security invoker set search_path = '' as $$
declare v_novo text := btrim(coalesce(p_novo, ''));
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem alterar os cadastros' using errcode = '42501';
  end if;
  if v_novo = '' then raise exception 'O nome não pode ficar vazio'; end if;
  update public.especialidades set nome = v_novo where nome = p_antigo;
  update public.medicos set especialidade = v_novo where especialidade = p_antigo;
  update public.patients p set agendamentos = (
      select coalesce(jsonb_agg(case when a ->> 'spec' = p_antigo
                                     then jsonb_set(a, '{spec}', to_jsonb(v_novo)) else a end
                                order by t.ord), '[]'::jsonb)
      from jsonb_array_elements(p.agendamentos) with ordinality as t(a, ord))
  where p.agendamentos @> jsonb_build_array(jsonb_build_object('spec', p_antigo));
end $$;

-- Corrige nome/especialidade de um médico na lista e em todos os agendamentos (admin)
create or replace function public.renomear_medico(p_antigo text, p_novo text, p_especialidade text default null)
returns void language plpgsql security invoker set search_path = '' as $$
declare v_novo text := btrim(coalesce(p_novo, ''));
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem alterar os cadastros' using errcode = '42501';
  end if;
  if v_novo = '' then raise exception 'O nome não pode ficar vazio'; end if;
  update public.medicos
     set nome = v_novo,
         especialidade = coalesce(btrim(p_especialidade), especialidade)
   where nome = p_antigo;
  if v_novo is distinct from p_antigo then
    update public.patients p set agendamentos = (
        select coalesce(jsonb_agg(case when a ->> 'doctor' = p_antigo
                                       then jsonb_set(a, '{doctor}', to_jsonb(v_novo)) else a end
                                  order by t.ord), '[]'::jsonb)
        from jsonb_array_elements(p.agendamentos) with ordinality as t(a, ord))
    where p.agendamentos @> jsonb_build_array(jsonb_build_object('doctor', p_antigo));
  end if;
end $$;

-- Restaura um backup (admin). Se qualquer parte falhar, NADA é alterado.
-- Preserva as datas de criação/alteração e os autores gravados no arquivo.
create or replace function public.restaurar_backup(
  p_pacientes jsonb, p_especialidades jsonb default null, p_medicos jsonb default null)
returns integer language plpgsql security invoker set search_path = '' as $$
declare n integer;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem restaurar backups' using errcode = '42501';
  end if;
  if jsonb_typeof(p_pacientes) is distinct from 'array' then
    raise exception 'Backup inválido: lista de pacientes ausente';
  end if;

  perform set_config('app.preservar_auditoria', 'on', true);
  delete from public.patients where true;
  insert into public.patients (pid, name, city, estado, phone, agendamentos, obs, status,
                               created_at, created_by_email, updated_at, updated_by_email, created_by, updated_by)
  select coalesce(x ->> 'pid', ''),
         btrim(x ->> 'name'),
         coalesce(x ->> 'city', ''),
         case when x ->> 'estado' in ('SE','AL','PE','BA') then x ->> 'estado' else 'SE' end,
         coalesce(x ->> 'phone', ''),
         public.limpar_agendamentos(x -> 'agendamentos'),
         coalesce(x ->> 'obs', ''),
         case when x ->> 'status' in ('Ativo','Atendido','Óbito') then x ->> 'status' else 'Ativo' end,
         coalesce(public.ts_ou_nulo(x ->> 'created_at'), now()),
         nullif(lower(btrim(coalesce(x ->> 'created_by_email', ''))), ''),
         coalesce(public.ts_ou_nulo(x ->> 'updated_at'), public.ts_ou_nulo(x ->> 'created_at'), now()),
         nullif(lower(btrim(coalesce(x ->> 'updated_by_email', ''))), ''),
         null, null   -- não atribui ao admin que restaurou fichas que ele não criou
  from jsonb_array_elements(p_pacientes) as x
  where jsonb_typeof(x) = 'object' and coalesce(btrim(x ->> 'name'), '') <> '';
  get diagnostics n = row_count;
  perform set_config('app.preservar_auditoria', 'off', true);

  if jsonb_typeof(p_especialidades) = 'array' then
    delete from public.especialidades where true;
    insert into public.especialidades (nome)
    select distinct on (lower(btrim(v))) btrim(v)
    from jsonb_array_elements_text(p_especialidades) as v
    where btrim(v) <> ''
    order by lower(btrim(v));
  end if;

  if jsonb_typeof(p_medicos) = 'array' then
    delete from public.medicos where true;
    insert into public.medicos (nome, especialidade)
    select distinct on (lower(btrim(m ->> 'name'))) btrim(m ->> 'name'), coalesce(btrim(m ->> 'spec'), '')
    from jsonb_array_elements(p_medicos) as m
    where jsonb_typeof(m) = 'object' and coalesce(btrim(m ->> 'name'), '') <> ''
    order by lower(btrim(m ->> 'name'));
  end if;

  return n;
end $$;

-- Importação de planilha (admin). Recebe pacientes já organizados pelo site:
--   [{pid, name, city, estado, phone, status, obs, agendamentos:[{date, spec, doctor}]}]
-- Regras:
--   • procura o paciente pelo ID; sem ID (ou ID ainda não cadastrado), pelo nome + WhatsApp;
--   • paciente novo → é cadastrado;
--   • paciente que já existe → p_existentes = 'acrescentar': entram só os agendamentos que
--     ainda não existem (mesma data + especialidade) e os campos que estavam em branco;
--     nada que a equipe já preencheu é apagado. p_existentes = 'ignorar': não mexe nele;
--   • especialidades e médicos novos entram nas listas de cadastro.
-- Importar o mesmo arquivo duas vezes não duplica nada.
create or replace function public.importar_pacientes(p_pacientes jsonb, p_existentes text default 'acrescentar')
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  x jsonb; v_id uuid; v_name text; v_pid text; v_phone text; v_city text; v_obs text;
  v_ag jsonb; v_add jsonb;
  o_ag jsonb; o_city text; o_phone text; o_obs text; o_pid text;
  n_ins integer := 0; n_upd integer := 0; n_igual integer := 0; n_ign integer := 0;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem importar planilhas' using errcode = '42501';
  end if;
  if jsonb_typeof(p_pacientes) is distinct from 'array' then raise exception 'Lista de pacientes inválida'; end if;
  if coalesce(p_existentes, '') not in ('acrescentar', 'ignorar') then
    raise exception 'Opção inválida para pacientes existentes: %', p_existentes;
  end if;

  for x in select value from jsonb_array_elements(p_pacientes) loop
    v_name := btrim(coalesce(x ->> 'name', ''));
    if jsonb_typeof(x) <> 'object' or v_name = '' then n_ign := n_ign + 1; continue; end if;
    v_pid   := btrim(coalesce(x ->> 'pid', ''));
    v_phone := regexp_replace(coalesce(x ->> 'phone', ''), '\D', '', 'g');
    v_city  := btrim(coalesce(x ->> 'city', ''));
    v_obs   := btrim(coalesce(x ->> 'obs', ''));
    v_ag    := public.limpar_agendamentos(x -> 'agendamentos');

    -- 1º pelo ID; 2º pelo nome (+ WhatsApp, quando os dois têm), só entre fichas sem ID
    v_id := null;
    if v_pid <> '' then
      select id into v_id from public.patients
       where pid <> '' and pid = v_pid order by created_at limit 1;
    end if;
    if v_id is null then
      select id into v_id from public.patients
       where public.sem_acento(name) = public.sem_acento(v_name)
         and (v_pid = '' or coalesce(pid, '') = '')
         and (v_phone = '' or coalesce(phone, '') = '' or phone = v_phone)
       order by created_at limit 1;
    end if;

    if v_id is null then
      insert into public.patients (pid, name, city, estado, phone, agendamentos, obs, status)
      values (v_pid, v_name, v_city,
              case when x ->> 'estado' in ('SE','AL','PE','BA') then x ->> 'estado' else 'SE' end,
              v_phone, v_ag, v_obs,
              case when x ->> 'status' in ('Ativo','Atendido','Óbito') then x ->> 'status' else 'Ativo' end);
      n_ins := n_ins + 1;
    elsif p_existentes = 'ignorar' then
      n_ign := n_ign + 1;
    else
      select agendamentos, coalesce(city, ''), coalesce(phone, ''), coalesce(obs, ''), coalesce(pid, '')
        into o_ag, o_city, o_phone, o_obs, o_pid
        from public.patients where id = v_id for update;
      select coalesce(jsonb_agg(a order by t.o), '[]'::jsonb) into v_add
        from jsonb_array_elements(v_ag) with ordinality as t(a, o)
       where not exists (select 1 from jsonb_array_elements(o_ag) b
                          where coalesce(b ->> 'date', '') = coalesce(a ->> 'date', '')
                            and public.sem_acento(b ->> 'spec') = public.sem_acento(a ->> 'spec'));
      if jsonb_array_length(v_add) > 0 or (o_city = '' and v_city <> '') or (o_phone = '' and v_phone <> '')
         or (o_obs = '' and v_obs <> '') or (o_pid = '' and v_pid <> '') then
        update public.patients set
          agendamentos = o_ag || v_add,
          city  = case when o_city  = '' then v_city  else city  end,
          phone = case when o_phone = '' then v_phone else phone end,
          obs   = case when o_obs   = '' then v_obs   else obs   end,
          pid   = case when o_pid   = '' then v_pid   else pid   end
        where id = v_id;
        n_upd := n_upd + 1;
      else
        n_igual := n_igual + 1;
      end if;
    end if;
  end loop;

  -- especialidades e médicos que ainda não estavam nas listas
  insert into public.especialidades (nome)
  select distinct on (lower(s)) s
  from (select btrim(a ->> 'spec') as s
          from jsonb_array_elements(p_pacientes) as item,
               jsonb_array_elements(public.limpar_agendamentos(item -> 'agendamentos')) as a) q
  where s <> '' and not exists (select 1 from public.especialidades e where lower(e.nome) = lower(q.s))
  order by lower(s)
  on conflict do nothing;

  insert into public.medicos (nome, especialidade)
  select distinct on (lower(d)) d, s
  from (select btrim(a ->> 'doctor') as d, btrim(a ->> 'spec') as s
          from jsonb_array_elements(p_pacientes) as item,
               jsonb_array_elements(public.limpar_agendamentos(item -> 'agendamentos')) as a) q
  where d <> '' and not exists (select 1 from public.medicos m where lower(m.nome) = lower(q.d))
  order by lower(d), (s = '')
  on conflict do nothing;

  return jsonb_build_object('inseridos', n_ins, 'atualizados', n_upd, 'sem_alteracao', n_igual, 'ignorados', n_ign);
end $$;

-- Dados do Dashboard numa única chamada, calculados DENTRO do banco
-- (o site recebe só os totais, poucos KB, por maior que seja o cadastro).
--   p_estado / p_status / p_especialidade: filtros (vazio = todos)
--   p_dias: quantos dias no gráfico diário · p_semanas: quantas semanas no semanal
--   p_tz: fuso horário usado para decidir "que dia" foi cada cadastro
create or replace function public.dashboard_resumo(
  p_estado text default null, p_status text default null, p_especialidade text default null,
  p_dias integer default 30, p_semanas integer default 12, p_tz text default 'America/Maceio')
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  v_tz      text := coalesce(nullif(btrim(p_tz), ''), 'America/Maceio');
  v_esp     text := nullif(btrim(coalesce(p_especialidade, '')), '');
  v_sem_esp boolean;
  v_hoje date; v_ini_dia date; v_ini_sem date; v_desde timestamptz;
  v_total bigint; v_hoje_n bigint; v_7d bigint; v_30d bigint;
  v_status jsonb; v_espec jsonb; v_dia jsonb; v_sem jsonb;
begin
  if not public.is_equipe() then raise exception 'Usuário sem permissão' using errcode = '42501'; end if;
  begin
    v_hoje := (now() at time zone v_tz)::date;
  exception when others then
    v_tz := 'America/Maceio'; v_hoje := (now() at time zone v_tz)::date;
  end;
  p_estado  := nullif(btrim(coalesce(p_estado, '')), '');
  p_status  := nullif(btrim(coalesce(p_status, '')), '');
  v_sem_esp := v_esp = '(sem especialidade)';
  p_dias    := least(greatest(coalesce(p_dias, 30), 7), 366);
  p_semanas := least(greatest(coalesce(p_semanas, 12), 4), 104);
  v_ini_dia := v_hoje - (p_dias - 1);
  v_ini_sem := date_trunc('week', v_hoje::timestamp)::date - 7 * (p_semanas - 1);
  v_desde   := (least(v_ini_dia, v_ini_sem, v_hoje - 29))::timestamp at time zone v_tz;

  -- (a) uma leitura só: total, situação (Ativo/Atendido/Óbito) e novos cadastros
  select count(*) filter (where p_status is null or status = p_status),
         count(*) filter (where (p_status is null or status = p_status)
                            and created_at >= v_hoje::timestamp at time zone v_tz),
         count(*) filter (where (p_status is null or status = p_status)
                            and created_at >= (v_hoje - 6)::timestamp at time zone v_tz),
         count(*) filter (where (p_status is null or status = p_status)
                            and created_at >= (v_hoje - 29)::timestamp at time zone v_tz),
         jsonb_build_object('Ativo',    count(*) filter (where status = 'Ativo'),
                            'Atendido', count(*) filter (where status = 'Atendido'),
                            'Óbito',    count(*) filter (where status = 'Óbito'))
    into v_total, v_hoje_n, v_7d, v_30d, v_status
    from public.patients
   where (p_estado is null or estado = p_estado)
     and (v_esp is null
          or (v_sem_esp and cardinality(especialidades_lista) = 0)
          or (not v_sem_esp and especialidades_lista @> array[v_esp]));

  -- (b) pacientes por especialidade (quem tem 2 especialidades conta nas 2).
  --     Ignora o filtro de especialidade: o gráfico mostra todas e destaca a escolhida.
  select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'n', n) order by n desc, nome), '[]'::jsonb)
    into v_espec
    from (select coalesce(s, '(sem especialidade)') as nome, count(*) as n
            from public.patients p
            left join lateral unnest(p.especialidades_lista) as s on true
           where (p_estado is null or p.estado = p_estado)
             and (p_status is null or p.status = p_status)
           group by 1) e;

  -- (c) novos cadastros por dia e por semana — lê só os cadastros recentes (índice em created_at)
  with recentes as materialized (
    select (created_at at time zone v_tz)::date as dia
      from public.patients
     where created_at >= v_desde
       and (p_estado is null or estado = p_estado)
       and (p_status is null or status = p_status)
       and (v_esp is null
            or (v_sem_esp and cardinality(especialidades_lista) = 0)
            or (not v_sem_esp and especialidades_lista @> array[v_esp]))
  )
  select (select jsonb_agg(jsonb_build_object('d', g::date, 'n', coalesce(c.n, 0)) order by g)
            from generate_series(v_ini_dia::timestamp, v_hoje::timestamp, interval '1 day') g
            left join (select dia, count(*) n from recentes where dia >= v_ini_dia group by dia) c
              on c.dia = g::date),
         (select jsonb_agg(jsonb_build_object('s', g::date, 'n', coalesce(c.n, 0)) order by g)
            from generate_series(v_ini_sem::timestamp, v_hoje::timestamp, interval '7 days') g
            left join (select date_trunc('week', dia::timestamp)::date as sem, count(*) n
                         from recentes where dia >= v_ini_sem group by 1) c
              on c.sem = g::date)
    into v_dia, v_sem;

  return jsonb_build_object(
    'gerado_em', now(), 'hoje', v_hoje, 'fuso', v_tz,
    'total', v_total, 'novos_hoje', v_hoje_n, 'novos_7d', v_7d, 'novos_30d', v_30d,
    'por_status', v_status, 'por_especialidade', v_espec,
    'por_dia', coalesce(v_dia, '[]'::jsonb), 'por_semana', coalesce(v_sem, '[]'::jsonb));
end $$;


-- ---------------------------------------------------------------------
-- 6. SEGURANÇA (RLS) — quem pode o quê, garantido pelo próprio banco
--    • pacientes: equipe vê, cadastra e edita; só administrador exclui
--    • especialidades/médicos: equipe vê; só administrador cadastra/altera/apaga
--    • configurações: equipe vê; só administrador altera
--    • equipe: ninguém acessa direto (só pelas funções acima)
-- ---------------------------------------------------------------------
-- limpeza das versões anteriores deste script
drop policy if exists "logados_patients"      on public.patients;
drop policy if exists "equipe_patients"       on public.patients;
drop policy if exists "equipe_especialidades" on public.especialidades;
drop policy if exists "equipe_medicos"        on public.medicos;
drop table  if exists public.app_settings;

alter table public.patients       enable row level security;
alter table public.especialidades enable row level security;
alter table public.medicos        enable row level security;
alter table public.configuracoes  enable row level security;

drop policy if exists "pacientes_ver"           on public.patients;
drop policy if exists "pacientes_cadastrar"     on public.patients;
drop policy if exists "pacientes_editar"        on public.patients;
drop policy if exists "pacientes_excluir_admin" on public.patients;
create policy "pacientes_ver"           on public.patients for select to authenticated using ((select public.is_equipe()));
create policy "pacientes_cadastrar"     on public.patients for insert to authenticated with check ((select public.is_equipe()));
create policy "pacientes_editar"        on public.patients for update to authenticated
  using ((select public.is_equipe())) with check ((select public.is_equipe()));
create policy "pacientes_excluir_admin" on public.patients for delete to authenticated using ((select public.is_admin()));

drop policy if exists "especialidades_ver"   on public.especialidades;
drop policy if exists "especialidades_admin" on public.especialidades;
create policy "especialidades_ver"   on public.especialidades for select to authenticated using ((select public.is_equipe()));
create policy "especialidades_admin" on public.especialidades for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists "medicos_ver"   on public.medicos;
drop policy if exists "medicos_admin" on public.medicos;
create policy "medicos_ver"   on public.medicos for select to authenticated using ((select public.is_equipe()));
create policy "medicos_admin" on public.medicos for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

drop policy if exists "configuracoes_ver"   on public.configuracoes;
drop policy if exists "configuracoes_admin" on public.configuracoes;
create policy "configuracoes_ver"   on public.configuracoes for select to authenticated using ((select public.is_equipe()));
create policy "configuracoes_admin" on public.configuracoes for update to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- permissões explícitas: visitantes sem login (anon) não acessam nada
revoke all on public.patients, public.especialidades, public.medicos, public.equipe, public.configuracoes from anon;
revoke all on public.equipe, public.configuracoes from authenticated;
grant select, insert, update, delete on public.patients, public.especialidades, public.medicos to authenticated;
grant select, update on public.configuracoes to authenticated;

-- funções: só usuários logados chamam (e cada uma confere o perfil por dentro)
revoke execute on function
  public.is_equipe(), public.is_admin(), public.meu_perfil(), public.equipe_nomes(), public.listar_equipe(),
  public.salvar_membro(text, text, text), public.remover_membro(text),
  public.renomear_especialidade(text, text), public.renomear_medico(text, text, text),
  public.restaurar_backup(jsonb, jsonb, jsonb), public.importar_pacientes(jsonb, text),
  public.dashboard_resumo(text, text, text, integer, integer, text),
  public.sem_acento(text), public.lista_especialidades(jsonb), public.limpar_agendamentos(jsonb), public.ts_ou_nulo(text)
from public, anon;
grant execute on function
  public.is_equipe(), public.is_admin(), public.meu_perfil(), public.equipe_nomes(), public.listar_equipe(),
  public.salvar_membro(text, text, text), public.remover_membro(text),
  public.renomear_especialidade(text, text), public.renomear_medico(text, text, text),
  public.restaurar_backup(jsonb, jsonb, jsonb), public.importar_pacientes(jsonb, text),
  public.dashboard_resumo(text, text, text, integer, integer, text),
  public.sem_acento(text), public.lista_especialidades(jsonb), public.limpar_agendamentos(jsonb), public.ts_ou_nulo(text)
to authenticated;
-- tornar_admin: SÓ pelo SQL Editor (ninguém consegue se promover pelo site)
revoke execute on function public.tornar_admin(text, text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 7. TEMPO REAL: alterações aparecem na hora para todos os usuários
-- ---------------------------------------------------------------------
do $$ begin
  begin alter publication supabase_realtime add table public.patients;       exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.especialidades; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.medicos;        exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.configuracoes;  exception when duplicate_object then null; end;
end $$;


-- ---------------------------------------------------------------------
-- 8. RESULTADO: mostra a equipe cadastrada e o perfil de cada um.
--    Se ninguém aparecer como "admin", rode (com o SEU e-mail):
--      select public.tornar_admin('seu-email@exemplo.com', 'Seu Nome');
-- ---------------------------------------------------------------------
select email, nome, papel from public.equipe order by (papel = 'admin') desc, email;
