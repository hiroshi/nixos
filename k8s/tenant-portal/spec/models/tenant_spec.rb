require "rails_helper"

RSpec.describe Tenant do
  it "puts the name behind a fixed prefix to form the namespace" do
    expect(described_class.new(name: "demo").namespace).to eq("tenant-demo")
  end

  it "normalizes the name before validating it" do
    tenant = described_class.new(name: "  DEMO ")

    expect(tenant).to be_valid
    expect(tenant.name).to eq("demo")
  end

  # The namespace has to be an RFC 1123 label, and Kubernetes caps the whole
  # name (prefix included) at 63 characters.
  it "rejects names that would not be a valid namespace" do
    [ "-demo", "demo-", "de_mo", "de mo", "デモ", "a" * (Tenant::MAX_NAME_LENGTH + 1) ].each do |name|
      tenant = described_class.new(name: name)

      expect(tenant).not_to be_valid, "expected #{name.inspect} to be rejected"
      expect(tenant.errors[:name]).to be_present
    end
  end

  it "accepts a name that fills the remaining length budget" do
    expect(described_class.new(name: "a" * Tenant::MAX_NAME_LENGTH)).to be_valid
  end

  it "rejects a duplicate name" do
    described_class.create!(name: "demo")

    expect(described_class.new(name: "demo")).not_to be_valid
  end
end
