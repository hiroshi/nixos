require "json"
require "net/http"
require "uri"
require "yaml"

# A very small Kubernetes API client: enough to create, read and delete the
# handful of resource kinds a tenant is made of, and nothing else.
#
# Writes go through Server-Side Apply (PATCH with the apply-patch content type),
# which is what makes `provision!` idempotent in one request per object -- create
# if absent, reconcile if present -- without the client having to branch on
# existence or carry a resourceVersion.
#
# Credentials are the pod's own ServiceAccount, read from the well-known paths.
# The API server address is a DNS name rather than KUBERNETES_SERVICE_HOST on
# purpose: Thruster does not pass that variable through to the Rails process, so
# anything built from it works under `rails runner` and fails under a web
# request. The environment overrides below exist for running the portal outside
# the cluster, where none of these paths are present.
class KubernetesClient
  class Error < StandardError
    attr_reader :status

    def initialize(message, status: nil)
      super(message)
      @status = status
    end
  end

  SERVICE_ACCOUNT_DIR = "/var/run/secrets/kubernetes.io/serviceaccount".freeze

  API_SERVER = ENV.fetch("KUBERNETES_API_SERVER", "https://kubernetes.default.svc")
  TOKEN_FILE = ENV.fetch("KUBERNETES_TOKEN_FILE", "#{SERVICE_ACCOUNT_DIR}/token")
  CA_FILE = ENV.fetch("KUBERNETES_CA_FILE", "#{SERVICE_ACCOUNT_DIR}/ca.crt")

  FIELD_MANAGER = "tenant-portal".freeze
  APPLY_CONTENT_TYPE = "application/apply-patch+yaml".freeze

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 30

  Resource = Struct.new(:prefix, :plural, :namespaced)

  # Only the kinds lib/templates/tenant.yaml.erb renders. An unknown kind is a
  # bug in the template, not something to route dynamically via discovery.
  RESOURCES = {
    "Namespace" => Resource.new("/api/v1", "namespaces", false),
    "ServiceAccount" => Resource.new("/api/v1", "serviceaccounts", true),
    "ConfigMap" => Resource.new("/api/v1", "configmaps", true),
    "Service" => Resource.new("/api/v1", "services", true),
    "PersistentVolumeClaim" => Resource.new("/api/v1", "persistentvolumeclaims", true),
    "Deployment" => Resource.new("/apis/apps/v1", "deployments", true),
    "RoleBinding" => Resource.new("/apis/rbac.authorization.k8s.io/v1", "rolebindings", true)
  }.freeze

  # Server-Side Apply of one parsed manifest document.
  def apply(document)
    kind = document["kind"]
    name = document.dig("metadata", "name")
    namespace = document.dig("metadata", "namespace")

    uri = build_uri(
      kind, name,
      namespace: namespace,
      query: { fieldManager: FIELD_MANAGER, force: "true" }
    )
    request = Net::HTTP::Patch.new(uri)
    request["Content-Type"] = APPLY_CONTENT_TYPE
    request.body = document.to_yaml
    send_request(request)
  end

  # => the object as a Hash, or nil if it doesn't exist.
  def get(kind, name, namespace: nil)
    send_request(Net::HTTP::Get.new(build_uri(kind, name, namespace: namespace)), allow_missing: true)
  end

  # Deleting a namespace garbage-collects everything in it. Background
  # propagation returns as soon as the deletion is accepted -- namespace
  # termination outlives a web request.
  def delete(kind, name, namespace: nil)
    uri = build_uri(kind, name, namespace: namespace, query: { propagationPolicy: "Background" })
    send_request(Net::HTTP::Delete.new(uri), allow_missing: true)
  end

  def build_uri(kind, name, namespace: nil, query: nil)
    resource = RESOURCES.fetch(kind) { raise Error, "unsupported kind #{kind.inspect}" }
    if resource.namespaced && namespace.blank?
      raise Error, "#{kind} #{name} has no namespace"
    end

    # Built by joining rather than appending: `<<` onto RESOURCES' own strings
    # mutates the table in place, and every later request then addresses a path
    # with the previous one's namespace still glued onto the front.
    segments = [ resource.prefix ]
    segments << "namespaces/#{namespace}" if resource.namespaced
    segments << "#{resource.plural}/#{name}"

    uri = URI.join(API_SERVER, segments.join("/"))
    uri.query = URI.encode_www_form(query) if query.present?
    uri
  end

  private

  def send_request(request, allow_missing: false)
    request["Authorization"] = "Bearer #{token}"
    request["Accept"] = "application/json"

    response = http.request(request)
    body = parse(response.body)

    return nil if allow_missing && response.is_a?(Net::HTTPNotFound)
    return body if response.is_a?(Net::HTTPSuccess)

    # Failures come back as a Status object, whose message is far more useful
    # than the HTTP code alone ("namespaces is forbidden: User ... cannot ...").
    raise Error.new(body["message"].presence || "#{request.method} #{request.path} failed (#{response.code})",
      status: response.code.to_i)
  rescue Error
    raise
  rescue StandardError => e
    raise Error, "Kubernetes API unreachable: #{e.class}: #{e.message}"
  end

  def http
    uri = URI.parse(API_SERVER)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    if http.use_ssl?
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.ca_file = CA_FILE if File.exist?(CA_FILE)
    end
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http
  end

  # Read per request rather than caching: the projected ServiceAccount token is
  # rotated while the pod runs.
  def token
    File.read(TOKEN_FILE).strip
  rescue Errno::ENOENT
    raise Error, "no ServiceAccount token at #{TOKEN_FILE}"
  end

  def parse(body)
    JSON.parse(body.to_s)
  rescue JSON::ParserError
    {}
  end
end
