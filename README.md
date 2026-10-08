# Gestão Logística e Atendimento — Hospital de Amor (versão 3)

## Arquivos
| Arquivo | Para quê | Vai para o GitHub? |
|---|---|---|
| `index.html` | o sistema (HTML, CSS e JavaScript, comentados) | sim |
| `logo.png` | logo (tela de login e menu) | sim |
| `config.js` | endereço e chave do seu Supabase (não mudou na v3) | sim |
| `supabase.sql` | tabelas, perfis, auditoria, segurança (RLS), funções e tempo real | não (roda só no Supabase) |
| `README.md` | este passo a passo | opcional |

---

## ATUALIZAR UM SISTEMA QUE JÁ ESTÁ NO AR (v2 → v3)
Faça nesta ordem. Leva uns 10 minutos e **nenhum paciente é apagado**.

1. **Backup antes de tudo:** no sistema atual, *Cadastros e backup → Baixar backup (.json)*.
2. **Banco:** Supabase → **SQL Editor → New query** → cole **todo** o novo `supabase.sql` → **Run**.
   No fim aparece a lista da equipe com a coluna `papel`. Todos começam como `usuario`.
3. **Defina o(s) administrador(es)** — passo obrigatório. Ainda no SQL Editor, rode (com o seu e-mail):
   ```sql
   select public.tornar_admin('seu-email@exemplo.com', 'Seu Nome');
   ```
   Repita para cada administrador. Essa função **só funciona aqui no SQL Editor** — ninguém consegue se promover pelo site.
4. **Segurança do login (confira uma vez):** em *Authentication → Sign In / Providers*, deixe **“Allow new users to sign up” DESLIGADO** e, em *Email*, **“Confirm email” LIGADO**. O acesso é liberado pelo e-mail: com cadastro aberto, alguém poderia criar uma conta com um e-mail que você já incluiu na equipe mas cujo login ainda não foi criado.
5. **Site:** no GitHub, substitua o `index.html` pelo novo (*Add file → Upload files* → *Commit changes*). O `config.js` e o `logo.png` continuam os mesmos.
6. Abra o site, entre e confira: no topo aparece **Administrador**, e no menu surge o grupo **Administração** (Cadastros, Usuários, Alertas, Importar planilha, Backup).
   Se o navegador mostrar a versão antiga, recarregue com **Ctrl+F5**.

### O que o `supabase.sql` muda no banco
| Item | O que faz |
|---|---|
| `equipe.papel` (`admin` / `usuario`) | perfil de acesso de cada pessoa |
| `is_admin()`, `meu_perfil()`, `equipe_nomes()` | o site descobre o perfil de quem entrou e o nome de quem alterou cada ficha |
| `listar_equipe()`, `salvar_membro()`, `remover_membro()` | aba **Usuários** (só admin). Impede tirar o último administrador e remover o próprio acesso |
| `tornar_admin()` | define administradores pelo SQL Editor |
| `patients.created_by_email`, `updated_by_email` | **auditoria**: quem cadastrou e quem fez a última alteração (com `created_at` e `updated_at`) |
| gatilho `trg_auditar_patient` | o próprio banco preenche data e autor; o site não consegue falsificar. Data de criação nunca muda |
| `patients.especialidades_lista` | coluna calculada sozinha pelo banco, usada pelo Dashboard |
| índices em `created_at`, `pid`, nome e especialidades | consultas rápidas mesmo com dezenas de milhares de pacientes |
| tabela `configuracoes` | regra dos alertas (dias de antecedência e modo), com quem alterou e quando |
| `dashboard_resumo()` | todos os números do Dashboard numa consulta só, calculada no banco |
| `importar_pacientes()` | importação de planilha (só admin), sem duplicar |
| políticas RLS novas | ver tabela abaixo |

### Quem pode o quê (garantido pelo banco, não só pela tela)
| | Usuário padrão | Administrador |
|---|---|---|
| Painel, Dashboard, Relatórios | ✓ | ✓ |
| Ver, cadastrar e editar pacientes | ✓ | ✓ |
| Excluir paciente | — | ✓ |
| Cadastros (especialidades e médicos) | só usa a lista | ✓ |
| Usuários e permissões | — | ✓ |
| Alertas (regra de antecedência) | — | ✓ |
| Importar planilha | — | ✓ |
| Backup e restauração | — | ✓ |

Mesmo que alguém tente pelo console do navegador, o banco recusa o que o perfil não permite.

---

## INSTALAÇÃO DO ZERO (projeto novo)
1. https://supabase.com → **New project**.
2. **SQL Editor → New query** → cole todo o `supabase.sql` → **Run**.
3. **Authentication → Sign In / Providers**: desligue **“Allow new users to sign up”** e mantenha **“Confirm email”** ligado.
4. **Authentication → Users → Add user → Create new user** com o seu e-mail (marque *Auto Confirm User*).
5. No SQL Editor: `select public.tornar_admin('seu-email@exemplo.com', 'Seu Nome');`
6. Preencha o `config.js` (botão **Connect** do projeto): *Project URL* → `SUPABASE_URL`; *Publishable key* (`sb_publishable_...`) → `SUPABASE_KEY`. Nunca use a *Secret key* / *service_role*.
7. GitHub → novo repositório → envie `index.html`, `logo.png`, `config.js` → **Settings → Pages** → *Deploy from a branch*, `main`, `/ (root)`.
8. **Authentication → URL Configuration**: *Site URL* e *Redirect URLs* = endereço do GitHub Pages.
9. Entre no site e cadastre a equipe pela aba **Usuários**.

---

## Como usar as novidades
**Dashboard** (todos) — filtros por estado, situação, especialidade e período. Mostra pacientes por especialidade (clique numa barra para abrir a lista daqueles pacientes em Relatórios), situação (Ativo/Atendido/Óbito) e novos cadastros por dia e por semana. Cada gráfico tem **Ver em tabela**. Atualiza sozinho quando alguém cadastra ou altera um paciente. Quem tem duas especialidades conta nas duas.

**Usuários** (admin) — inclua a pessoa e crie o login dela logo em seguida. *Incluir pessoa* libera o acesso; a pessoa também precisa de login em *Supabase → Authentication → Users → Add user* (mesmo e-mail, senha provisória, *Auto Confirm User*). A lista mostra se o login já foi criado e o último acesso. Mudar o perfil vale na hora (a pessoa vê as abas novas ao voltar para o sistema).

**Alertas** (admin) — escolha com quantos dias de antecedência o alerta dispara e como:
- *Só no dia exato*: aparece só quando faltam exatamente N dias (era o comportamento antigo, com 2 dias);
- *Todos os dias até a consulta*: entra quando faltam N dias e fica até o dia (ninguém perde o aviso).
A tela mostra quantos pacientes estariam em alerta hoje antes de salvar. Vale na hora para todos.

**Importar planilha** (admin) — `.xlsx` ou `.csv`, primeira linha com os nomes das colunas (*ID, Nome do Paciente, Cidade, Número do WhatsApp, Data do Agendamento, Especialidade*; opcionais: *Médico, Status, Observações, Estado (UF)*). Use **Baixar modelo**.
- Uma linha por agendamento; o mesmo ID em várias linhas vira um paciente com vários agendamentos.
- Médico, status e observações em branco são aceitos (status em branco = Ativo).
- Estado: coluna *Estado*, ou pelo DDD do WhatsApp, ou o estado escolhido na tela.
- Mostra a **prévia** (novos, já cadastrados, erros) e só grava depois de confirmar. Reimportar o mesmo arquivo não duplica nada.
- Linhas com erro (sem nome, data impossível) ficam de fora e podem ser baixadas para corrigir.
- `.xls` antigo: abra no Excel e salve como `.xlsx` ou CSV.

**Auditoria** — na ficha: *Cadastrado em … por …* e *Última alteração em … por …*. Nas listas dos estados: colunas **Cadastro** e **Última alteração**. Em Relatórios: colunas *Cadastrado em/por*, *Alterado em/por* e agrupamento *Quem cadastrou*. Fichas antigas recebem o autor automaticamente quando o login ainda existe.

**Formulários** — os campos não mostram mais o histórico de digitação do navegador. A sugestão de **cidade** que continua aparecendo é do próprio sistema (cidades já cadastradas), para manter a grafia igual. Se o Chrome ainda oferecer um *endereço salvo*, é o preenchimento de endereços do navegador: *Configurações → Preenchimento automático → Endereços*.

---

## No dia a dia
- **Tirar alguém do sistema:** aba **Usuários → lixeira**. Se quiser, apague também o login em *Authentication → Users*.
- **Senhas:** cada pessoa troca a própria em **Alterar senha**. *Esqueci minha senha* exige SMTP próprio (*Authentication → SMTP*); sem isso, o administrador apaga e recria o login com senha provisória.
- **Topo da tela:** bolinha verde = atualizando sozinho; amarela = reconectando; vermelha = sem internet.
- **Plano gratuito do Supabase:** pausa após 7 dias sem uso (dados mantidos; *Resume project*).
- Baixe o **backup** com frequência (aba Backup). Ele guarda também quem cadastrou/alterou cada ficha e quando, e a restauração preserva essas informações.

---

## Para quem for mexer no código
Seções do `index.html` (procure pelos títulos `/* ===== ... ===== */`): SUPABASE, PERFIL DE ACESSO E EQUIPE, REGRA DOS ALERTAS, BIBLIOTECAS, SEM SUGESTÕES DO NAVEGADOR, ABAS, PAINEL, DASHBOARD, CADASTROS, BACKUP, USUÁRIOS, ALERTAS, IMPORTAR PLANILHA, FICHA DO PACIENTE, LOGIN / SESSÃO.
```js
// perfil e equipe
const { data: perfil } = await sb.rpc("meu_perfil");            // {email, nome, papel} ou null
await sb.rpc("listar_equipe");                                  // só admin
await sb.rpc("salvar_membro", { p_email, p_nome, p_papel });    // "admin" | "usuario"
await sb.rpc("remover_membro", { p_email });

// dashboard (tudo calculado no banco)
await sb.rpc("dashboard_resumo", { p_estado, p_status, p_especialidade, p_dias: 30, p_semanas: 12, p_tz: "America/Maceio" });

// regra dos alertas
await sb.from("configuracoes").select("*").eq("id", 1).maybeSingle();
await sb.from("configuracoes").update({ alerta_dias: 5, alerta_modo: "ate_o_dia" }).eq("id", 1).select().maybeSingle();

// importação (lotes de 250; cada lote grava inteiro ou nada)
await sb.rpc("importar_pacientes", { p_pacientes: [{ pid, name, city, estado, phone, status, obs, agendamentos: [{ date, spec, doctor }] }], p_existentes: "acrescentar" });

// pacientes (auditoria é preenchida pelo banco)
await sb.from("patients").select("*").order("name").order("id").range(0, 999);
await sb.from("patients").update(dados).eq("id", id).eq("updated_at", versaoAberta).select("id"); // detecta edição simultânea
await sb.from("patients").delete().eq("id", id).select("id");   // 0 linhas = sem permissão (não é admin)
```
Bibliotecas carregadas só quando a tela precisa, com verificação de integridade (SRI): **Chart.js 4.4.1** (Dashboard) e **read-excel-file 9.3.8** (ler `.xlsx`). Sem internet para baixá-las, o Dashboard mostra os números em tabelas e a importação continua aceitando CSV.

## Privacidade (LGPD)
São dados de saúde (dado pessoal sensível). Mantenha o cadastro público desligado, dê perfil de administrador só a quem precisa, use senhas fortes, remova o acesso de quem sair da equipe e guarde os backups e planilhas importadas em local seguro.
