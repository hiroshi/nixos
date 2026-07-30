# One tenant == one Kubernetes namespace holding that tenant's own claude-code
# pod, ServiceAccount and PVC. This record is bookkeeping only: the namespace is
# the source of truth, and the live state of the pod comes from
# TenantAgentClient rather than from `status` here.
class Tenant < ApplicationRecord
  NAMESPACE_PREFIX = "tenant-".freeze
  # An RFC 1123 label, minus the prefix this class adds. Kubernetes caps the
  # whole namespace name at 63 characters.
  NAME_FORMAT = /\A[a-z0-9]([-a-z0-9]*[a-z0-9])?\z/
  MAX_NAME_LENGTH = 63 - NAMESPACE_PREFIX.length

  STATUSES = %w[provisioning active deleting failed].freeze

  validates :name,
    presence: true,
    uniqueness: true,
    length: { maximum: MAX_NAME_LENGTH },
    format: {
      with: NAME_FORMAT,
      message: "は英小文字・数字・ハイフンのみ、先頭と末尾は英数字にしてください"
    }
  validates :status, inclusion: { in: STATUSES }

  normalizes :name, with: ->(name) { name.to_s.strip.downcase }

  # Prefixing every tenant namespace makes collisions with system namespaces
  # (default, kube-system, monitoring, topolvm-system, ...) structurally
  # impossible, so no denylist has to be maintained.
  def namespace
    "#{NAMESPACE_PREFIX}#{name}"
  end

  def agent
    TenantAgentClient.new(namespace)
  end

  def provisioner
    TenantProvisioner.new(self)
  end
end
