class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # This app can create namespaces and bind RBAC, so it must never be reachable
  # unauthenticated. Missing credentials is a boot-time crash in production
  # rather than a silently open portal; locally it falls back to a dev password.
  #
  # Basic auth is the interim measure -- see this directory's README for the
  # plan to move the public deployment behind something better.
  PORTAL_USERNAME = ENV.fetch("PORTAL_USERNAME", "admin")
  PORTAL_PASSWORD = ENV.fetch("PORTAL_PASSWORD") do
    if Rails.env.local?
      "portal"
    else
      raise "PORTAL_PASSWORD must be set (see deploy/Makefile's `secret` target)"
    end
  end

  # Rails::HealthController does not inherit from this class, so /up stays
  # reachable for the kubelet probes.
  http_basic_authenticate_with name: PORTAL_USERNAME, password: PORTAL_PASSWORD
end
