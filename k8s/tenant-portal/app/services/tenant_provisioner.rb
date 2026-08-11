require "erb"
require "yaml"

# Creates and deletes a tenant's Kubernetes resources by rendering
# lib/templates/tenant.yaml.erb and applying each document through
# KubernetesClient.
#
# The manifest stays a YAML template rather than Ruby hashes so it reads like
# every other manifest in this repo and can be diffed against them.
class TenantProvisioner
  class Error < StandardError; end

  TEMPLATE_PATH = Rails.root.join("lib/templates/tenant.yaml.erb")
  SUPERVISOR_PATH = Rails.root.join("agent/supervisor.py")
  MANAGED_BY_LABEL = "app.kubernetes.io/managed-by".freeze
  MANAGED_BY_VALUE = "tenant-portal".freeze

  # Every tenant runs the same claude-code image the default namespace runs, so
  # the tag is passed in rather than hardcoded (see deploy/Makefile).
  CLAUDE_CODE_IMAGE = ENV.fetch("CLAUDE_CODE_IMAGE", "ghcr.io/hiroshi/claude-code:latest")
  CAPACITY = ENV.fetch("TENANT_CAPACITY", "4")
  STORAGE_SIZE = ENV.fetch("TENANT_STORAGE_SIZE", "1Gi")

  Context = Struct.new(
    :namespace, :tenant_name, :image, :capacity, :storage_size, :supervisor_source, :api_server_ip,
    keyword_init: true
  ) do
    def render(template)
      ERB.new(template, trim_mode: "-").result(binding)
    end
  end

  def initialize(tenant, client: KubernetesClient.new)
    @tenant = tenant
    @client = client
  end

  def provision!
    ensure_namespace_available!
    # The namespace is the first document, so it exists before anything is
    # applied into it.
    documents.each { |document| @client.apply(document) }
  rescue KubernetesClient::Error => e
    raise Error, e.message
  end

  # Deleting the namespace garbage-collects the Deployment, Service, PVC (and
  # with it the TopoLVM logical volume), ServiceAccount and RoleBinding.
  def destroy!
    @client.delete("Namespace", @tenant.namespace)
  rescue KubernetesClient::Error => e
    raise Error, e.message
  end

  def namespace_exists?
    !namespace.nil?
  rescue KubernetesClient::Error => e
    raise Error, e.message
  end

  def documents
    YAML.load_stream(manifests)
  end

  def manifests
    Context.new(
      namespace: @tenant.namespace,
      tenant_name: @tenant.name,
      image: CLAUDE_CODE_IMAGE,
      capacity: CAPACITY,
      storage_size: STORAGE_SIZE,
      supervisor_source: SUPERVISOR_PATH.read,
      api_server_ip: api_server_ip
    ).render(TEMPLATE_PATH.read)
  end

  private

  def namespace
    @client.get("Namespace", @tenant.namespace)
  end

  # k3s exposes no pod for the API server; its real (node) address lives on the
  # core Endpoints object of the same name, in the default namespace, alongside
  # the `kubernetes` Service. Never hardcode this -- see the NetworkPolicy
  # comment in the template for why.
  def api_server_ip
    endpoints = @client.get("Endpoints", "kubernetes", namespace: "default")
    endpoints&.dig("subsets", 0, "addresses", 0, "ip") ||
      raise(Error, "could not determine the Kubernetes API server's address " \
        "(no addresses on the default/kubernetes Endpoints object)")
  end

  # Applying into a namespace this app didn't create would reconfigure whatever
  # else on the cluster owns it.
  def ensure_namespace_available!
    existing = namespace
    return if existing.nil?

    labels = existing.dig("metadata", "labels") || {}
    return if labels[MANAGED_BY_LABEL] == MANAGED_BY_VALUE

    raise Error, "namespace #{@tenant.namespace} already exists and is not managed by tenant-portal"
  end
end
