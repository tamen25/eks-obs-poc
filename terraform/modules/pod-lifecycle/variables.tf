variable "namespace" {
  description = "Namespace to run in. The node agent must collect from it."
  type        = string
}

variable "image" {
  description = "Image with kubectl, jq and sh, pinned by tag or digest."
  type        = string

  validation {
    condition     = !endswith(var.image, ":latest") && can(regex("[:@]", var.image))
    error_message = "image must carry a pinned tag or digest (not :latest)."
  }
}

variable "resources" {
  description = "Container resource requests and limits."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
}
