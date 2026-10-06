# NetworkPolicy de entrada do banco do Keycloak (docs/contrato-identidade.md, secao Seguranca).
# O CNI padrao do kind (kindnet) aplica NetworkPolicy desde o kind v0.24; ver
# docs/contrato-identidade.md (secao Seguranca) para o teste de bloqueio.
#
# Somente regras de ENTRADA (policy_types = ["Ingress"]): a saida dos pods (DNS, JWKS,
# banco) nao e restringida.

# keycloak-db: aceita apenas o Keycloak (mesmo namespace). Nunca exposto ao host.
resource "kubernetes_network_policy_v1" "keycloak_db" {
  metadata {
    name      = "keycloak-db-somente-keycloak"
    namespace = kubernetes_namespace_v1.identidade.metadata[0].name
    labels    = local.rotulos_comuns
  }

  spec {
    pod_selector {
      match_labels = {
        app = "keycloak-db"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        pod_selector {
          match_labels = {
            app = "keycloak"
          }
        }
      }
      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }
}
