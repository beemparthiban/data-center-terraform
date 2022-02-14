locals {
  product_name = "bitbucket"

  helm_chart_repository        = "https://atlassian.github.io/data-center-helm-charts"
  bitbucket_helm_chart_version = var.bitbucket_configuration["helm_version"]

  bitbucket_software_resources = {
    "minHeap" : var.bitbucket_configuration["min_heap"]
    "maxHeap" : var.bitbucket_configuration["max_heap"]
    "cpu" : var.bitbucket_configuration["cpu"]
    "mem" : var.bitbucket_configuration["mem"]
    "reservedCodeCache" : var.bitbucket_configuration["reserved_code_cache"]
  }

  rds_instance_name = format("atlas-%s-%s-db", var.environment_name, local.product_name)

  # if the domain wasn't provided we will start bitbucket with LoadBalancer service without ingress configuration
  use_domain          = length(var.ingress) == 1
  product_domain_name = local.use_domain ? "${local.product_name}.${var.ingress[0].ingress.domain}" : null

  # ingress settings for bitbucket service
  ingress_with_domain = yamlencode({
    ingress = {
      create = "true"
      host   = local.product_domain_name
    }
  })

  service_as_loadbalancer = yamlencode({
    bitbucket = {
      service = {
        type = "LoadBalancer"
      }
    }
    ingress = {
      https = false
    }
  })

  ingress_settings = local.use_domain ? local.ingress_with_domain : local.service_as_loadbalancer
}