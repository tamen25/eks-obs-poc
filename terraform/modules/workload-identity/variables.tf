variable "name" {
  description = "IAM role name."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster the workload runs in."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of the EKS cluster. Pod Identity trust is limited to this cluster."
  type        = string
}

variable "mode" {
  description = <<-EOT
    How pods get the role:
      irsa         - IAM Roles for Service Accounts. Needs the cluster's OIDC provider in IAM.
      pod_identity - EKS Pod Identity. Needs the eks-pod-identity-agent add-on on the cluster.
  EOT
  type        = string

  validation {
    condition     = contains(["irsa", "pod_identity"], var.mode)
    error_message = "mode must be \"irsa\" or \"pod_identity\"."
  }
}

variable "oidc_provider_arn" {
  description = "IAM OIDC provider ARN of the cluster. Required for irsa."
  type        = string
  default     = null
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster (https://oidc.eks...). Required for irsa."
  type        = string
  default     = null
}

variable "namespace" {
  description = "Namespace of the service account."
  type        = string
}

variable "service_account" {
  description = "Service account name the role is bound to."
  type        = string
}

variable "policy_json" {
  description = "Inline policy document for the role."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the role, if the account requires one."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}
