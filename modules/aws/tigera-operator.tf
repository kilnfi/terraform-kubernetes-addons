locals {
  tigera-operator = merge(
    local.helm_defaults,
    {
      name                   = local.helm_dependencies[index(local.helm_dependencies.*.name, "tigera-operator")].name
      chart                  = local.helm_dependencies[index(local.helm_dependencies.*.name, "tigera-operator")].name
      repository             = local.helm_dependencies[index(local.helm_dependencies.*.name, "tigera-operator")].repository
      chart_version          = local.helm_dependencies[index(local.helm_dependencies.*.name, "tigera-operator")].version
      namespace              = "tigera-operator"
      create_ns              = true
      manage_crds            = true
      native_crds            = false
      enabled                = false
      default_network_policy = true
    },
    var.tigera-operator
  )

  # helm template cannot discover cluster APIs, pass the MutatingAdmissionPolicy version per upstream docs
  calico-crds_minor_version = length(data.kubernetes_server_version.calico-crds) > 0 ? tonumber(replace(data.kubernetes_server_version.calico-crds[0].minor, "+", "")) : 0
  calico-crds_api_versions = (
    local.calico-crds_minor_version >= 36 ? ["admissionregistration.k8s.io/v1/MutatingAdmissionPolicy"] :
    local.calico-crds_minor_version >= 34 ? ["admissionregistration.k8s.io/v1beta1/MutatingAdmissionPolicy"] :
    []
  )

  values_tigera-operator = <<-VALUES
    installation:
      kubernetesProvider: EKS
    VALUES
}

resource "kubernetes_namespace" "tigera-operator" {
  count = local.tigera-operator["enabled"] && local.tigera-operator["create_ns"] ? 1 : 0

  metadata {
    labels = {
      name                               = local.tigera-operator["namespace"]
      "${local.labels_prefix}/component" = "tigera-operator"
    }

    name = local.tigera-operator["namespace"]
  }
}

data "kubernetes_server_version" "calico-crds" {
  count = local.tigera-operator["enabled"] && local.tigera-operator["manage_crds"] && local.tigera-operator["native_crds"] ? 1 : 0
}

# CRD charts exceed the 1MB Helm release secret limit, so render them and apply server side as upstream docs do
# https://docs.tigera.io/calico/latest/getting-started/kubernetes/helm
data "helm_template" "calico-crds" {
  count        = local.tigera-operator["enabled"] && local.tigera-operator["manage_crds"] ? 1 : 0
  repository   = local.tigera-operator["repository"]
  name         = format("%s-crds", local.tigera-operator["name"])
  chart        = local.tigera-operator["native_crds"] ? "projectcalico.org.v3" : "crd.projectcalico.org.v1"
  version      = local.tigera-operator["chart_version"]
  namespace    = local.tigera-operator["namespace"]
  api_versions = local.calico-crds_api_versions
}

data "kubectl_file_documents" "calico-crds" {
  count   = local.tigera-operator["enabled"] && local.tigera-operator["manage_crds"] ? 1 : 0
  content = data.helm_template.calico-crds[0].manifest
}

resource "kubectl_manifest" "calico-crds" {
  for_each          = local.tigera-operator["enabled"] && local.tigera-operator["manage_crds"] ? { for v in data.kubectl_file_documents.calico-crds[0].documents : lower(join("/", compact([yamldecode(v).apiVersion, yamldecode(v).kind, yamldecode(v).metadata.name]))) => v } : {}
  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
}

# Drop the former Helm release from state without uninstalling it: uninstall would delete every Calico CRD and CR
removed {
  from = helm_release.calico-crds

  lifecycle {
    destroy = false
  }
}

resource "helm_release" "tigera-operator" {
  count                 = local.tigera-operator["enabled"] ? 1 : 0
  repository            = local.tigera-operator["repository"]
  name                  = local.tigera-operator["name"]
  chart                 = local.tigera-operator["chart"]
  version               = local.tigera-operator["chart_version"]
  timeout               = local.tigera-operator["timeout"]
  force_update          = local.tigera-operator["force_update"]
  recreate_pods         = local.tigera-operator["recreate_pods"]
  wait                  = local.tigera-operator["wait"]
  atomic                = local.tigera-operator["atomic"]
  cleanup_on_fail       = local.tigera-operator["cleanup_on_fail"]
  dependency_update     = local.tigera-operator["dependency_update"]
  disable_crd_hooks     = local.tigera-operator["disable_crd_hooks"]
  disable_webhooks      = local.tigera-operator["disable_webhooks"]
  render_subchart_notes = local.tigera-operator["render_subchart_notes"]
  replace               = local.tigera-operator["replace"]
  reset_values          = local.tigera-operator["reset_values"]
  reuse_values          = local.tigera-operator["reuse_values"]
  skip_crds             = local.tigera-operator["skip_crds"]
  verify                = local.tigera-operator["verify"]
  values = [
    local.values_tigera-operator,
    local.tigera-operator["extra_values"]
  ]
  namespace = local.tigera-operator["create_ns"] ? kubernetes_namespace.tigera-operator.*.metadata.0.name[count.index] : local.tigera-operator["namespace"]

  depends_on = [
    kubectl_manifest.calico-crds,
    kubectl_manifest.prometheus-operator_crds,
  ]
}

resource "kubernetes_network_policy" "tigera-operator_default_deny" {
  count = local.tigera-operator["create_ns"] && local.tigera-operator["enabled"] && local.tigera-operator["default_network_policy"] ? 1 : 0

  metadata {
    name      = "${kubernetes_namespace.tigera-operator.*.metadata.0.name[count.index]}-default-deny"
    namespace = kubernetes_namespace.tigera-operator.*.metadata.0.name[count.index]
  }

  spec {
    pod_selector {
    }
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy" "tigera-operator_allow_namespace" {
  count = local.tigera-operator["create_ns"] && local.tigera-operator["enabled"] && local.tigera-operator["default_network_policy"] ? 1 : 0

  metadata {
    name      = "${kubernetes_namespace.tigera-operator.*.metadata.0.name[count.index]}-allow-namespace"
    namespace = kubernetes_namespace.tigera-operator.*.metadata.0.name[count.index]
  }

  spec {
    pod_selector {
    }

    ingress {
      from {
        namespace_selector {
          match_labels = {
            name = kubernetes_namespace.tigera-operator.*.metadata.0.name[count.index]
          }
        }
      }
    }

    policy_types = ["Ingress"]
  }
}
