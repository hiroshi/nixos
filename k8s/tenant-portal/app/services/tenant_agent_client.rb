require "json"
require "net/http"

# Talks to a tenant pod's supervisor (agent/supervisor.py) over the tenant's
# ClusterIP Service. The supervisor owns the interactive `claude auth login` /
# `claude remote-control` processes; this portal only reads its phase and hands
# it the OAuth code the user pasted.
#
# Being unreachable is normal, not exceptional: the pod is still being
# scheduled, pulling the image, or restarting. All of that surfaces as the
# "unavailable" phase.
class TenantAgentClient
  class AgentError < StandardError; end

  URL_TEMPLATE = ENV.fetch(
    "TENANT_AGENT_URL_TEMPLATE",
    "http://claude-code.%{namespace}.svc.cluster.local:8080"
  )
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 5

  # Phases reported by the supervisor, plus "unavailable" for "no answer yet".
  UNAVAILABLE = "unavailable".freeze

  def initialize(namespace)
    @base_url = format(URL_TEMPLATE, namespace: namespace)
  end

  # => { "phase" => ..., "auth_url" => ..., "session_url" => ..., "error" => ...,
  #      "awaiting_code" => bool }
  def status
    body = request(Net::HTTP::Get.new(uri_for("/status")))
    return unavailable unless body.is_a?(Hash)

    body
  rescue StandardError => e
    Rails.logger.info("tenant agent unreachable: #{e.class}: #{e.message}")
    unavailable
  end

  # => [ok, message]
  def submit_code(code)
    post = Net::HTTP::Post.new(uri_for("/code"))
    post["Content-Type"] = "application/json"
    post.body = JSON.generate(code: code)
    request(post)
    [ true, nil ]
  rescue AgentError => e
    [ false, e.message ]
  rescue StandardError => e
    [ false, "エージェントに接続できませんでした (#{e.class})" ]
  end

  private

  def unavailable
    { "phase" => UNAVAILABLE }
  end

  def uri_for(path)
    URI.join(@base_url, path)
  end

  def request(request)
    uri = request.uri
    response = Net::HTTP.start(
      uri.hostname, uri.port, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT
    ) { |http| http.request(request) }

    parsed = begin
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      {}
    end

    unless response.is_a?(Net::HTTPSuccess)
      raise AgentError, parsed["error"].presence || "agent returned #{response.code}"
    end

    parsed
  end
end
