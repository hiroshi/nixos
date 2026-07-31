require "rails_helper"

# Typed explicitly: rails_helper leaves infer_spec_type_from_file_location!
# commented out, as rspec-rails generates it.
RSpec.describe "Tenants", type: :request do
  let(:credentials) do
    ActionController::HttpAuthentication::Basic.encode_credentials(
      ApplicationController::PORTAL_USERNAME, ApplicationController::PORTAL_PASSWORD
    )
  end

  # This app can create namespaces, so an unauthenticated route is a real
  # incident, not a cosmetic one.
  it "refuses unauthenticated requests" do
    get tenants_path

    expect(response).to have_http_status(:unauthorized)
  end

  it "serves the tenant list once authenticated" do
    get tenants_path, headers: { "HTTP_AUTHORIZATION" => credentials }

    expect(response).to have_http_status(:ok)
  end

  # The kubelet probes it, and Rails::HealthController does not inherit
  # ApplicationController's basic auth.
  it "leaves the health check open" do
    get rails_health_check_path

    expect(response).to have_http_status(:ok)
  end
end
