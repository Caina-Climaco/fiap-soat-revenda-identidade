# Versoes do Terraform e dos providers (docs/ci-cd.md).
# Sem provider de cluster: o kind e criado pela CLI kind (infra/kind/cluster.yaml, ADR-003).
# Os dois providers abaixo sao assinados (Authenticode) pela HashiCorp e rodam com o
# Smart App Control do Windows 11 ligado.
# As restricoes "~>" aceitam apenas correcoes/minors compativeis; o arquivo
# .terraform.lock.hcl (gerado no primeiro `terraform init`) deve ser versionado.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    # Namespaces, Secrets, ConfigMap, StatefulSets, Deployment, Services e NetworkPolicies
    # (recursos tipados *_v1; a serie 3.x deprecou os recursos sem sufixo).
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.3"
    }
    # Senhas e segredo do client e2e (ADR-002).
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # State local FORA do repositorio. O caminho vem na inicializacao (configuracao parcial):
  #   terraform init -backend-config="path=$USERPROFILE/.revenda/identidade.tfstate"
  # O state contem os segredos gerados em texto claro (ADR-002): nunca versionar.
  backend "local" {}
}
