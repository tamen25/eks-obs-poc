variable "namespace" {
  description = "Namespace to run in (the privileged agents namespace: it needs a writable hostPath)."
  type        = string
}

variable "image" {
  description = "Image with sh, inotifywait (inotify-tools) and GNU find. Build it from images/log-keeper and push it to your registry."
  type        = string

  validation {
    condition     = can(regex("^[^\\s:@]+(:[^\\s@]+)?(@sha256:[a-f0-9]{64})?$", var.image)) && !endswith(var.image, ":latest")
    error_message = "image must be a repository reference with a pinned tag or digest (not :latest)."
  }
}

variable "ttl_minutes" {
  description = "Minutes a kept file survives after the kubelet deletes the original. This is how long a shipper has to finish it."
  type        = number
}

variable "max_orphan_mb" {
  description = "Cap on disk used by kept files whose original is gone; the oldest are dropped first."
  type        = number
}

variable "resources" {
  description = "Container resource requests and limits."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
}
