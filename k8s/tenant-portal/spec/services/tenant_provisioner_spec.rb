require "rails_helper"

RSpec.describe TenantProvisioner do
  let(:tenant) { Tenant.new(name: "demo") }
  let(:api_server_endpoints) do
    { "subsets" => [ { "addresses" => [ { "ip" => "203.0.113.10" } ] } ] }
  end
  let(:client) do
    instance_double(KubernetesClient, get: nil).tap do |c|
      allow(c).to receive(:get).with("Endpoints", "kubernetes", namespace: "default")
        .and_return(api_server_endpoints)
    end
  end
  let(:documents) { described_class.new(tenant, client: client).documents }

  describe "the rendered manifest" do
    it "renders every resource a tenant needs, the namespace first" do
      expect(documents.map { |doc| doc["kind"] }).to eq(
        %w[Namespace ServiceAccount RoleBinding PersistentVolumeClaim ConfigMap Deployment Service NetworkPolicy]
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

    # remote-control names a new session's workspace after the pod hostname;
    # without this it'd default to the pod-template-hash name.
    it "names the pod after the tenant's namespace" do
      hostname = documents
        .find { |doc| doc["kind"] == "Deployment" }
        .dig("spec", "template", "spec", "hostname")

      expect(hostname).to eq("tenant-demo")
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

    it "restricts ingress to the portal pod on 8080" do
      ingress = documents.find { |doc| doc["kind"] == "NetworkPolicy" }.dig("spec", "ingress", 0)

      expect(ingress.dig("from", 0, "podSelector", "matchLabels", "app")).to eq("tenant-portal")
      expect(ingress.dig("ports", 0, "port")).to eq(8080)
    end

    it "builds the API server egress rule from the discovered address, never a hardcoded one" do
      egress = documents.find { |doc| doc["kind"] == "NetworkPolicy" }.dig("spec", "egress")
      api_rule = egress.find { |rule| rule.dig("ports", 0, "port") == 6443 }

      expect(api_rule.dig("to", 0, "ipBlock", "cidr")).to eq("203.0.113.10/32")
    end

    it "excludes standard private address space from the outbound-everything rule, not a site-specific LAN" do
      egress = documents.find { |doc| doc["kind"] == "NetworkPolicy" }.dig("spec", "egress")
      outbound_rule = egress.find { |rule| rule.dig("to", 0, "ipBlock", "cidr") == "0.0.0.0/0" }

      expect(outbound_rule.dig("to", 0, "ipBlock", "except")).to contain_exactly(
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"
      )
    end
  end

  describe "#provision!" do
    let(:client) { instance_double(KubernetesClient) }

    it "applies each document once the namespace is known to be free" do
      allow(client).to receive(:get).with("Namespace", "tenant-demo").and_return(nil)
      allow(client).to receive(:get).with("Endpoints", "kubernetes", namespace: "default")
        .and_return(api_server_endpoints)
      allow(client).to receive(:apply)

      described_class.new(tenant, client: client).provision!

      expect(client).to have_received(:apply).exactly(8).times
    end

    it "reconciles a namespace it created before" do
      allow(client).to receive(:get).and_return(
        { "metadata" => { "labels" => { described_class::MANAGED_BY_LABEL => described_class::MANAGED_BY_VALUE } } }
      )
      allow(client).to receive(:get).with("Endpoints", "kubernetes", namespace: "default")
        .and_return(api_server_endpoints)
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
