terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.50"
    }
  }
}
