# Segredos gerados pelo Terraform (ADR-002). Os valores ficam apenas no state local (fora
# do repositorio) e nos Secrets do namespace identidade. Rotacao:
#   terraform apply -replace=random_password.<nome>
#
# Senhas de banco e do admin: so letras e digitos (seguras em URL, JDBC e shell).
# Senha do gestor e segredo do client e2e: entram no arquivo de realm por placeholder
# ${VAR}, que o Keycloak substitui no texto ANTES de interpretar o JSON; por isso os
# especiais permitidos excluem aspas, barra invertida, "$", "{" e "}".

resource "random_password" "keycloak_db" {
  length  = 32
  special = false
}

resource "random_password" "keycloak_admin" {
  length  = 24
  special = false
}

resource "random_password" "keycloak_gestor" {
  length           = 20
  special          = true
  override_special = "!#%*-_=+"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 1
}

resource "random_password" "e2e_admin_client" {
  length  = 40
  special = false
}

resource "kubernetes_secret_v1" "keycloak_db_credentials" {
  metadata {
    name      = "keycloak-db-credentials"
    namespace = kubernetes_namespace_v1.identidade.metadata[0].name
    labels    = local.rotulos_comuns
  }
  type = "Opaque"
  data = {
    KC_DB_USERNAME = "keycloak"
    KC_DB_PASSWORD = random_password.keycloak_db.result
  }
}

# Admin do realm master: usado SO dentro deste repositorio (Job de reconciliacao).
resource "kubernetes_secret_v1" "keycloak_admin" {
  metadata {
    name      = "keycloak-admin"
    namespace = kubernetes_namespace_v1.identidade.metadata[0].name
    labels    = local.rotulos_comuns
  }
  type = "Opaque"
  data = {
    KC_BOOTSTRAP_ADMIN_USERNAME = var.keycloak_admin_usuario
    KC_BOOTSTRAP_ADMIN_PASSWORD = random_password.keycloak_admin.result
  }
}

# Senha do usuario seed gestor.loja (contrato: lida pelo e2e da API).
resource "kubernetes_secret_v1" "keycloak_gestor" {
  metadata {
    name      = "keycloak-gestor"
    namespace = kubernetes_namespace_v1.identidade.metadata[0].name
    labels    = local.rotulos_comuns
  }
  type = "Opaque"
  data = {
    GESTOR_PASSWORD = random_password.keycloak_gestor.result
  }
}

# Client tecnico dos testes e2e (contrato: lido pelo CD da API). So cria e apaga usuarios
# do realm revenda; o admin do realm master nunca sai deste repositorio.
resource "kubernetes_secret_v1" "keycloak_e2e" {
  metadata {
    name      = "keycloak-e2e"
    namespace = kubernetes_namespace_v1.identidade.metadata[0].name
    labels    = local.rotulos_comuns
  }
  type = "Opaque"
  data = {
    E2E_ADMIN_CLIENT_ID     = "revenda-e2e-admin"
    E2E_ADMIN_CLIENT_SECRET = random_password.e2e_admin_client.result
  }
}
