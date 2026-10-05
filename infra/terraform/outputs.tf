# Nenhuma saida contem senha (nem como sensitive): os valores ficam so no state e nos
# Secrets do cluster. Para ler um segredo, use os comandos em `comandos_segredos`.

output "cluster" {
  description = "Nome do cluster kind e contexto do kubectl."
  value = {
    nome            = var.cluster_nome
    contexto        = local.kube_contexto
    kubeconfig_path = local.kubeconfig_path
    config_kind     = "infra/kind/cluster.yaml"
  }
}

# Contrato publicado para os consumidores (docs/contrato-identidade.md).
output "contrato" {
  description = "O que a API (e qualquer outro consumidor) precisa saber da identidade."
  value = {
    realm             = "revenda"
    oidc_issuer       = "http://localhost:8180/realms/revenda"
    oidc_discovery    = "http://localhost:8180/realms/revenda/.well-known/openid-configuration"
    oidc_jwks_interno = "http://keycloak.identidade.svc.cluster.local:8080/realms/revenda/protocol/openid-connect/certs"
    audiencia         = "revenda-api"
    papeis            = ["cliente", "gestor"]
    client_swagger    = "revenda-swagger"
    clients_e2e       = ["revenda-e2e", "revenda-e2e-admin"]
  }
}

output "urls" {
  description = "Enderecos locais (apenas 127.0.0.1)."
  value = {
    keycloak               = "http://localhost:8180"
    keycloak_admin_console = "http://localhost:8180/admin/"
    conta_do_cliente       = "http://localhost:8180/realms/revenda/account"
    cadastro_de_cliente    = "http://localhost:8180/realms/revenda/account (link 'Registre-se' na tela de login)"
  }
}

output "secrets" {
  description = "Secrets criados (namespace/nome => chaves)."
  # Lista estatica: referenciar `data` dos Secrets tornaria a saida sensivel.
  value = {
    "identidade/keycloak-db-credentials" = ["KC_DB_USERNAME", "KC_DB_PASSWORD"]
    "identidade/keycloak-admin"          = ["KC_BOOTSTRAP_ADMIN_USERNAME", "KC_BOOTSTRAP_ADMIN_PASSWORD"]
    "identidade/keycloak-gestor"         = ["GESTOR_PASSWORD"]
    "identidade/keycloak-e2e"            = ["E2E_ADMIN_CLIENT_ID", "E2E_ADMIN_CLIENT_SECRET"]
  }
  depends_on = [
    kubernetes_secret_v1.keycloak_db_credentials,
    kubernetes_secret_v1.keycloak_admin,
    kubernetes_secret_v1.keycloak_gestor,
    kubernetes_secret_v1.keycloak_e2e,
  ]
}

output "comandos_segredos" {
  description = "Como ler os segredos com kubectl (Git Bash/Linux; no PowerShell, decodifique com [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(...)))."
  value = {
    senha_gestor   = "kubectl -n identidade get secret keycloak-gestor -o jsonpath='{.data.GESTOR_PASSWORD}' | base64 -d"
    admin_keycloak = "kubectl -n identidade get secret keycloak-admin -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d"
  }
}

output "comandos_uteis" {
  description = "Atalhos para a demonstracao."
  value = {
    pods          = "kubectl -n identidade get pods -o wide"
    psql_keycloak = "kubectl -n identidade exec -it statefulset/keycloak-db -- psql -U keycloak -d keycloak"
    logs_keycloak = "kubectl -n identidade logs deployment/keycloak --tail=100"
  }
}
