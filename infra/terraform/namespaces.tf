locals {
  rotulos_comuns = {
    "app.kubernetes.io/part-of"    = "revenda-identidade"
    "app.kubernetes.io/managed-by" = "terraform"
  }
}

# Contexto Identidade e Acesso (Keycloak e o seu banco): os dados pessoais dos compradores
# ficam so aqui. Este repositorio nao conhece o namespace da API (revenda); a API so
# consome o contrato publico do realm (docs/contrato-identidade.md).
resource "kubernetes_namespace_v1" "identidade" {
  metadata {
    name   = "identidade"
    labels = local.rotulos_comuns
  }
}
