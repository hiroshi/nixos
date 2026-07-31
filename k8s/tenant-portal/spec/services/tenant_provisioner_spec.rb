require "rails_helper"

RSpec.describe TenantProvisioner do
  let(:tenant) { Tenant.new(name: "demo") }
  let(:documents) { described_class.new(tenant).documents }

  describe "the rendered manifest" do
    it "renders every resource a tenant needs, the namespace first" do
      expect(documents.map { |doc| doc["kind"] }).to eq(
        %w[Namespace ServiceAccount RoleBinding PersistentVolumeClaim ConfigMap Deployment Service]
      )
    end

    it "keeps every resource inside the tenant's own namespace" do
      documents.drop(1).each do |doc|
        expect(doc.dig("metadata", "namespace")).to eq("tenant-demo"), "#{doc['kind']} escaped the namespace"
      end
    end

    it "grants the tenant edit inside its namespace only" do
      role_ref = documents.find { |doc| doc["kind"] == "RoleBinding" }["roleRef"]

      expect(role_ref).to include("kind" => "ClusterRole", "name" => "edit")
    end

    it "enforces the restricted pod security standard on the namespace" do
      expect(documents.first.dig("metadata", "labels", "pod-security.kubernetes.io/enforce"))
        .to eq("restricted")
    end

    it "gives the tenant container a security context that standard admits" do
      security_context = documents
        .find { |doc| doc["kind"] == "Deployment" }
        .dig("spec", "template", "spec", "containers", 0, "securityContext")

      expect(security_context["allowPrivilegeEscalation"]).to be(false)
      expect(security_context.dig("capabilities", "drop")).to eq([ "ALL" ])
    end

    # provision! refuses to touch a namespace without this label, so the
    # template and that check have to agree on it.
    it "labels the namespace with what provisioning checks for" do
      expect(documents.first.dig("metadata", "labels", described_class::MANAGED_BY_LABEL))
        .to eq(described_class::MANAGED_BY_VALUE)
    end

    # supervisor.py travels as a YAML block scalar, which is where a bad indent
    # would silently truncate it.
    it "ships supervisor.py verbatim in the ConfigMap" do
      config_map = documents.find { |doc| doc["kind"] == "ConfigMap" }

      expect(config_map.dig("data", "supervisor.py")).to eq(described_class::SUPERVISOR_PATH.read)
    end
  end

  describe "#provision!" do
    let(:client) { instance_double(KubernetesClient) }

    it "applies each document once the namespace is known to be free" do
      allow(client).to receive(:get).with("Namespace", "tenant-demo").and_return(nil)
      allow(client).to receive(:apply)

      described_class.new(tenant, client: client).provision!

      expect(client).to have_received(:apply).exactly(7).times
    end

    it "reconciles a namespace it created before" do
      allow(client).to receive(:get).and_return(
        { "metadata" => { "labels" => { described_class::MANAGED_BY_LABEL => described_class::MANAGED_BY_VALUE } } }
      )
      allow(client).to receive(:apply)

      expect { described_class.new(tenant, client: client).provision! }.not_to raise_error
    end

    it "refuses to apply into a namespace it does not own" do
      allow(client).to receive(:get).and_return({ "metadata" => { "labels" => { "app" => "something-else" } } })
      allow(client).to receive(:apply)

      expect { described_class.new(tenant, client: client).provision! }
        .to raise_error(TenantProvisioner::Error, /not managed by tenant-portal/)
      expect(client).not_to have_received(:apply)
    end

    # The controller reports failures by rescuing TenantProvisioner::Error; an
    # API error escaping as its own class would 500 instead.
    it "reports an API failure as its own error" do
      allow(client).to receive(:get).and_raise(KubernetesClient::Error.new("namespaces is forbidden"))

      expect { described_class.new(tenant, client: client).provision! }
        .to raise_error(TenantProvisioner::Error, /forbidden/)
    end
  end
end
