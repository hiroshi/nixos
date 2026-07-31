require "rails_helper"

RSpec.describe KubernetesClient do
  describe "#build_uri" do
    it "addresses core resources under /api/v1, scoped to their namespace" do
      uri = described_class.new.build_uri("ConfigMap", "tenant-agent", namespace: "tenant-demo")

      expect(uri.path).to eq("/api/v1/namespaces/tenant-demo/configmaps/tenant-agent")
    end

    it "addresses grouped resources under /apis/<group>/<version>" do
      expect(described_class.new.build_uri("Deployment", "claude-code", namespace: "tenant-demo").path)
        .to eq("/apis/apps/v1/namespaces/tenant-demo/deployments/claude-code")
      expect(described_class.new.build_uri("RoleBinding", "claude-code-edit", namespace: "tenant-demo").path)
        .to eq("/apis/rbac.authorization.k8s.io/v1/namespaces/tenant-demo/rolebindings/claude-code-edit")
    end

    it "does not scope a cluster-scoped resource to a namespace" do
      expect(described_class.new.build_uri("Namespace", "tenant-demo").path)
        .to eq("/api/v1/namespaces/tenant-demo")
    end

    it "appends query parameters" do
      uri = described_class.new.build_uri("Namespace", "tenant-demo", query: { propagationPolicy: "Background" })

      expect(uri.query).to eq("propagationPolicy=Background")
    end

    # A kind the template renders but the table doesn't know would otherwise be
    # silently addressed at a wrong (or nonsense) path.
    it "refuses a kind it has no route for" do
      expect { described_class.new.build_uri("Secret", "whatever", namespace: "tenant-demo") }
        .to raise_error(KubernetesClient::Error, /unsupported kind/)
    end

    it "refuses a namespaced resource with no namespace" do
      expect { described_class.new.build_uri("ConfigMap", "tenant-agent") }
        .to raise_error(KubernetesClient::Error, /no namespace/)
    end
  end
end
