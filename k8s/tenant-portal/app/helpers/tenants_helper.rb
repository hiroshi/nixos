module TenantsHelper
  PHASE_LABELS = {
    TenantAgentClient::UNAVAILABLE => "起動待ち",
    "logging_in" => "ログイン待ち",
    "starting" => "起動中",
    "running" => "稼働中"
  }.freeze

  # Phases that change on their own, i.e. the page should keep polling.
  TRANSITIONAL_PHASES = [ TenantAgentClient::UNAVAILABLE, "logging_in", "starting" ].freeze

  def phase_label(phase)
    PHASE_LABELS.fetch(phase, phase)
  end

  def transitional_phase?(phase)
    TRANSITIONAL_PHASES.include?(phase)
  end
end
