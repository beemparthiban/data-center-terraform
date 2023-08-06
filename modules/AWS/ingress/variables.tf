variable "ingress_domain" {
  description = "Domain name for the ingress controller"
  type        = string
  default     = null
}

variable "enable_https_ingress" {
  description = "If true, Nginx controller will listen on 443 as well."
  type        = bool
}

variable "enable_ssh_tcp" {
  description = "If true, TCP will be enabled at ingress controller level."
  type        = bool
  default     = false
}

variable "load_balancer_access_ranges" {
  description = "List of allowed CIDRs that can access the load balancer."
  type        = list(string)
  validation {
    condition = alltrue([
    for cidr in var.load_balancer_access_ranges : can(regex("^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])/([0-9]|1[0-9]|2[0-9]|3[0-2])$", cidr))])
    error_message = "Invalid CIDR. Valid format is a list of '<IPv4>/[0-32]' e.g: [\"10.0.0.0/18\"]."
  }
}

variable "vpc" {
  description = "VPC module that hosts the products."
  type        = any
}

variable "additional_namespaces" {
  description = "List of additional namespaces to create."
  type        = list(string)
  default     = []
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9\\-]{1,38}$", var.cluster_name))
    error_message = "Invalid EKS cluster name. Valid name is up to 38 characters starting with an alphabet and followed by the combination of alphanumerics and '-'."
  }
}

variable "vpc_cidr" {
  description = "The CIDR block of the VPC"
  type        = string
}
