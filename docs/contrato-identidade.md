# Contrato do serviço de identidade

Este documento é o contrato entre o serviço de identidade (este repositório) e quem o consome. Hoje o único consumidor é a API de revenda ([fiap-soat-revenda-veiculos](https://github.com/Caina-Climaco/fiap-soat-revenda-veiculos)), mas qualquer front-end ou serviço que precise autenticar compradores e funcionários usa as mesmas regras.

O que está aqui é **o que pode ser usado de fora**. Qualquer outra coisa (nomes de pods, o banco `keycloak-db`, o Secret de administração, a estrutura interna do realm) é detalhe de implementação e pode mudar sem aviso.

O contrato é verificado automaticamente:

- no CI, pelo job `qualidade` (regras `jq` sobre `keycloak/realm-revenda.json`) e pelo job `realm` (testes contra um Keycloak real no docker compose);
- no CD, pelos mesmos testes contra o Keycloak implantado no cluster.

Os testes estão em [`tests/test_realm.py`](../tests/test_realm.py). O resumo também é o output `contrato` do Terraform (`infra/terraform/outputs.tf`), mostrado pelo script 04 ao final.

## 1. Emissor e descoberta

| Item | Valor |
|---|---|
| Protocolo | OpenID Connect / OAuth 2.0 |
| Realm | `revenda` |
| Issuer (`iss`) | `http://localhost:8180/realms/revenda` |
| Discovery | `{issuer}/.well-known/openid-configuration` |
| Autorização | `{issuer}/protocol/openid-connect/auth` |
| Token | `{issuer}/protocol/openid-connect/token` |
| Autocadastro | Link "Registre-se" na tela de login, ou `{issuer}/protocol/openid-connect/registrations` |
| Conta do titular | `{issuer}/account` |

**O issuer é fixo.** O Keycloak roda com `KC_HOSTNAME=http://localhost:8180`, então o `iss` é sempre `http://localhost:8180/realms/revenda`, seja o token obtido pelo navegador, por um container na rede docker `kind` ou por um pod no cluster. O consumidor deve comparar o `iss` com esse valor exato.

Endereços de acesso ao mesmo Keycloak:

| De onde | Endereço base |
|---|---|
| Navegador e host (Windows) | `http://localhost:8180` (porta só em `127.0.0.1`) |
| Pods do cluster | `http://keycloak.identidade.svc.cluster.local:8080` |
| Containers na rede docker `kind` (runners do CD) | `http://revenda-control-plane:30180` (NodePort) |
| Containers do docker compose da API (opção sem cluster) | `http://host.docker.internal:8180` |

Como `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true`, as URLs de backchannel do discovery (por exemplo, `jwks_uri`) acompanham o host usado na requisição; o issuer, não.

## 2. Chaves de assinatura (JWKS)

| Item | Valor |
|---|---|
| Algoritmo | **RS256** |
| JWKS para consumidores no cluster | `http://keycloak.identidade.svc.cluster.local:8080/realms/revenda/protocol/openid-connect/certs` |
| JWKS no host | `http://localhost:8180/realms/revenda/protocol/openid-connect/certs` |

Regras para o consumidor:

- validar a assinatura escolhendo a chave pelo `kid` do cabeçalho do token, apenas com `alg = RS256` e `use = sig`;
- manter o JWKS em cache e buscá-lo de novo quando aparecer um `kid` desconhecido (as chaves podem ser rotacionadas e, se a identidade for recriada do zero, o realm ganha chaves novas);
- nunca aceitar `alg = none` nem algoritmos simétricos.

## 3. Access token

### 3.1 Validação esperada

O consumidor deve exigir, no mínimo:

| Claim | Regra |
|---|---|
| assinatura | RS256, chave do JWKS acima |
| `iss` | igual a `http://localhost:8180/realms/revenda` |
| `exp` | no futuro (o realm emite access tokens de 5 minutos; esse prazo é configuração, não garantia) |
| `aud` | contém `revenda-api`. Pode ser uma string ou uma lista com outros valores: verifique **pertencimento**, não igualdade |
| `azp` | opcionalmente, restrito aos clients que o consumidor aceita (a API aceita, por padrão, `revenda-swagger` e `revenda-e2e`) |

### 3.2 Claims garantidas

| Claim | Conteúdo |
|---|---|
| `sub` | Identificador do usuário no Keycloak (UUID). Estável enquanto a conta existir. É o **único** identificador da pessoa que o consumidor deve guardar |
| `realm_access.roles` | Lista de papéis de realm; contém `cliente` e/ou `gestor` (seção 4) |
| `iss`, `aud`, `azp`, `exp`, `iat` | Como acima |

Outras claims técnicas podem aparecer (`jti`, `typ`, `scope`, `sid`, `acr`, `allowed-origins`, `resource_access`, entre outras) e **não fazem parte do contrato**.

### 3.3 Claims que nunca vêm no token

Nos clients `revenda-swagger` e `revenda-e2e`, os escopos `profile` e `email` são apenas **opcionais**. Com `scope=openid` (o que o Swagger UI e os testes pedem), o access token **não** contém:

`email`, `name`, `given_name`, `family_name`, `preferred_username`, `cpf`, `telefone`.

Isso é minimização de dados (LGPD): o token circula pela API, pelos logs e pelo navegador, e não precisa identificar a pessoa. O CI barra a volta de `profile`/`email` aos escopos padrão e os testes verificam a ausência dessas claims nos tokens do gestor e de um cliente recém-cadastrado.

Um front-end que precise mostrar o nome do usuário pode pedir `scope=openid profile email` explicitamente; nesse caso o token traz nome e e-mail, e esse consumidor passa a tratar dado pessoal. CPF e telefone não são mapeados para nenhum token.

## 4. Papéis

| Papel (realm) | Quem tem | Semântica |
|---|---|---|
| `cliente` | Todo usuário que se cadastra (faz parte de `default-roles-revenda`); também todo usuário criado pela Admin API | Comprador cadastrado: pode comprar |
| `gestor` | Só quem recebe o papel explicitamente; no ambiente local, o usuário seed `gestor.loja` | Funcionário da loja: cadastra e edita veículos e consulta vendas |

- O `gestor.loja` tem **só** o papel `gestor` (sem `cliente`); o Job `keycloak-reconciliar` reaplica isso sempre que roda (quando a senha do gestor, o segredo do client técnico ou o Deployment do Keycloak mudam).
- As regras de negócio sobre os papéis (por exemplo, "gestor não compra, mesmo que tenha também `cliente`") são responsabilidade do consumidor.
- Papéis de client (`resource_access`) não fazem parte do contrato.

### Usuário seed

| Item | Valor |
|---|---|
| Username | `gestor.loja` |
| E-mail | `gestor@revenda.local` |
| Papel | `gestor` |
| Senha | Secret `identidade/keycloak-gestor`, chave `GESTOR_PASSWORD` (seção 6) |

## 5. Clients e fluxos

| Client | Tipo | Fluxos habilitados | Para quê | Ambiente |
|---|---|---|---|---|
| `revenda-swagger` | Público | Authorization Code + PKCE (`S256`) | Login e autocadastro pelo navegador (Swagger UI da API, front-ends) | Todos |
| `revenda-api` | Confidencial, sem nenhum fluxo | Nenhum | Existe só para dar nome à audiência `revenda-api` | Todos |
| `revenda-e2e` | Público | Password grant (*direct access grants*) | Tokens de usuários nos testes automatizados | **Só local** |
| `revenda-e2e-admin` | Confidencial | Client credentials | Conta de serviço que cria, consulta e apaga usuários do realm `revenda` nos testes da API | **Só local** |

Detalhes do `revenda-swagger`:

- redirect URI: `http://localhost:8080/docs/oauth2-redirect`;
- web origin: `http://localhost:8080`;
- post-logout redirect: `http://localhost:8080/docs`;
- mapper de audiência: `revenda-api` no access token.

O `revenda-e2e` tem o mesmo mapper de audiência. Um novo front-end com outra URL precisa de um redirect URI próprio, o que é uma mudança de contrato (seção 8).

Detalhes do `revenda-e2e-admin` ([ADR-004](adrs/ADR-004-client-tecnico-e2e.md)):

- a conta de serviço tem **apenas** `manage-users`, `view-users` e `query-users` do client `realm-management` do realm `revenda`;
- não lê clients nem segredos, não administra outros realms e não tem papéis de negócio;
- o token dele não contém a audiência `revenda-api`, então não serve para chamar a API;
- uso: `POST /realms/revenda/protocol/openid-connect/token` com `grant_type=client_credentials`, depois Admin API em `/admin/realms/revenda/users`.

## 6. Secrets de contrato

O Terraform deste repositório gera os valores e os publica como Secrets no namespace `identidade`. Dois deles são **contrato** com o CD da API, que os lê com `kubectl` para rodar os testes ponta a ponta:

| Secret | Chaves | Conteúdo | Quem lê |
|---|---|---|---|
| `identidade/keycloak-gestor` | `GESTOR_PASSWORD` | Senha do `gestor.loja` | CD da API (e2e); CD deste repositório (testes do realm) |
| `identidade/keycloak-e2e` | `E2E_ADMIN_CLIENT_ID` (`revenda-e2e-admin`), `E2E_ADMIN_CLIENT_SECRET` | Credenciais do client técnico | CD da API (e2e); CD deste repositório |

Os demais são **internos** e nunca são lidos de fora deste repositório:

| Secret | Chaves | Uso |
|---|---|---|
| `identidade/keycloak-admin` | `KC_BOOTSTRAP_ADMIN_USERNAME`, `KC_BOOTSTRAP_ADMIN_PASSWORD` | Admin do realm `master`: criado na primeira subida do Keycloak e usado só pelo Job `keycloak-reconciliar` (e pelo autor, no console) |
| `identidade/keycloak-db-credentials` | `KC_DB_USERNAME`, `KC_DB_PASSWORD` | Conexão do Keycloak com o `keycloak-db` |

Os valores dos Secrets de contrato e os do realm ficam sempre iguais: o Job `keycloak-reconciliar` redefine a senha do gestor e o segredo do client técnico a partir dos Secrets sempre que um deles (ou o Deployment do Keycloak) muda.

## 7. O que é só do ambiente local

Itens que existem para o ambiente de demonstração e não devem ir para produção:

| Item | Em produção |
|---|---|
| Client `revenda-e2e` (password grant) | Remover |
| Client `revenda-e2e-admin` | Remover (ou restringir a um ambiente de testes isolado) |
| Usuário seed `gestor.loja` com senha gerada | Gestores reais cadastrados por um processo administrativo |
| `sslRequired: none`, HTTP, `KC_HOSTNAME=http://localhost:8180` | TLS obrigatório e hostname público; o issuer muda e os consumidores precisam ser reconfigurados |
| Keycloak em `start-dev`, uma réplica | Modo `start`, cache distribuído, mais de uma réplica |
| Redirect URIs em `http://localhost:8080` | URLs reais dos front-ends |
| Recuperação de senha e verificação de e-mail desligadas | Ligar, com servidor SMTP |

## 8. Como o contrato muda

O contrato é tudo o que está nas seções 1 a 6. Qualquer mudança nele segue este caminho:

1. **PR neste repositório** com a mudança no `realm-revenda.json` (ou no Terraform), o teste correspondente em `tests/test_realm.py` (e a regra `jq` no `ci.yml`, se fizer sentido) e a atualização **deste documento**. O template de PR tem um item de checklist para isso.
2. **PR coordenado no repositório da API**, quando a API precisar se adaptar (por exemplo, nova audiência, novo papel, novo client aceito em `OIDC_AZP_PERMITIDOS`).
3. **Ordem de merge**: a identidade primeiro, a API depois. O CD da API roda o e2e contra a identidade já implantada.

**Compatibilidade.** Não há número de versão publicado; a versão do contrato é o commit da `main` deste repositório. Para não quebrar o consumidor:

- mudanças **aditivas** (novo papel, novo client, novo atributo opcional no perfil, nova chave num Secret) podem entrar a qualquer momento;
- mudanças **incompatíveis** (renomear ou remover papel, client, audiência ou chave de Secret; mudar o issuer; colocar dados pessoais no token) são feitas em duas etapas: primeiro se introduz o novo ao lado do antigo, a API migra, e só então um segundo PR remove o antigo;
- nomes de Secrets e de chaves não mudam sem esse processo, porque o CD da API depende deles.

**Atenção: o realm é importado só uma vez.** O Keycloak importa o `realm-revenda.json` com a estratégia `IGNORE_EXISTING`. O CD aplica o novo arquivo (o ConfigMap muda e o pod reinicia), mas **um realm já existente não é alterado**. Para que uma mudança no realm chegue ao ambiente:

- recrie a identidade (`scripts\windows\05-destruir-ambiente.ps1` e depois `04-subir-ambiente.ps1`, ou o CD), perdendo os usuários cadastrados; ou
- aplique a mesma mudança pela Admin API ou pelo console.

O CI sempre testa o arquivo num realm novo; se o ambiente não for recriado, os testes do CD (que rodam contra o realm existente) apontam a divergência. As exceções são a senha do `gestor.loja` e o segredo do `revenda-e2e-admin`, que o Job `keycloak-reconciliar` reaplica a cada mudança.

## 9. Segurança

| Controle | Como |
|---|---|
| Banco da identidade isolado | NetworkPolicy `keycloak-db-somente-keycloak`: o `keycloak-db` só aceita conexões TCP na porta 5432 de pods com `app=keycloak` no namespace `identidade`. O Service é `ClusterIP`, sem NodePort e sem porta no host. No docker compose, o banco fica numa rede `internal`, sem rota para fora |
| Portas só locais | Os `extraPortMappings` do kind e o `ports` do compose publicam o Keycloak só em `127.0.0.1:8180`; nada é exposto na rede local |
| Segredos gerados | Todas as senhas e o segredo do client técnico vêm de `random_password` do Terraform e vivem só no state (fora do repositório, em `%USERPROFILE%\.revenda\identidade.tfstate`) e nos Secrets. Nenhuma saída do Terraform contém senha. No CI, segredos efêmeros gerados a cada execução e mascarados no log ([ADR-002](adrs/ADR-002-segredos-terraform-state-externo.md)) |
| Placeholders no realm | O `realm-revenda.json` versionado só tem `${GESTOR_PASSWORD}` e `${E2E_ADMIN_CLIENT_SECRET}`; o CI falha se um valor literal aparecer no lugar deles. Trivy procura segredos em todo PR |
| Admin do `master` confinado | O Secret `keycloak-admin` é usado só pelo Job `keycloak-reconciliar`, dentro deste namespace. Nenhum consumidor recebe credencial de administração: o e2e da API usa o `revenda-e2e-admin`, com privilégio mínimo ([ADR-004](adrs/ADR-004-client-tecnico-e2e.md)) |
| Proteção do login | Proteção contra força bruta (10 falhas, espera crescente até 15 minutos), política de senha, e-mail único |
| Containers endurecidos | Keycloak, `keycloak-db` e o Job rodam sem root, sem escalada de privilégio, sem capabilities, com seccomp `RuntimeDefault` e sem o token da service account do Kubernetes montado; banco e Job com sistema de arquivos somente leitura |
| Mínimo no token | Seção 3.3 |

**Verificando a NetworkPolicy.** Um pod sem o rótulo `app=keycloak` não alcança o banco (o comando deve **falhar** por tempo esgotado):

```bash
kubectl -n identidade run teste-np --rm -it --image=postgres:16.15-alpine --restart=Never -- \
  pg_isready -h keycloak-db -p 5432 -t 3
```

O caminho permitido é exercitado pelo próprio Keycloak: se ele está pronto (`kubectl -n identidade get pods`), conectou ao banco.
