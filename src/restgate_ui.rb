require 'digest'
require 'json'
require 'uri'
require_relative 'log_inspector'

module RestGate
  module UI
    USERNAME = ENV.fetch('RESTGATE_UI_USERNAME', '')
    PASSWORD = ENV.fetch('RESTGATE_UI_PASSWORD', '')
    BODY_PREVIEW_BYTES = Integer(ENV.fetch('RESTGATE_UI_BODY_PREVIEW_BYTES', '200000'), exception: false) || 200_000
    FILTER_KEYS = %w[q method prefix status query sort per_page page].freeze
    SENSITIVE_HEADERS = /\A(?:authorization|cookie|set-cookie|proxy-authorization|x-api-key|api-key)\z/i
    ASSETS = {
      'restgate.css' => ['text/css', File.expand_path('public/restgate.css', __dir__)],
      'restgate.js' => ['application/javascript', File.expand_path('public/restgate.js', __dir__)],
      'theme_plugin.js' => ['application/javascript', File.expand_path('public/theme_plugin.js', __dir__)]
    }.freeze

    if USERNAME.empty? != PASSWORD.empty?
      raise ArgumentError, 'RESTGATE_UI_USERNAME and RESTGATE_UI_PASSWORD must be configured together'
    end

    class AuthorizationRedactor
      AUTHORIZATION_ENV = 'restgate.ui.authorization'

      def initialize(app) = @app = app

      def call(env)
        authorization = env.delete('HTTP_AUTHORIZATION') if env['PATH_INFO'].to_s.start_with?('/_restgate')
        env[AUTHORIZATION_ENV] = authorization if authorization
        @app.call(env)
      ensure
        env['HTTP_AUTHORIZATION'] = authorization if authorization
        env.delete(AUTHORIZATION_ENV)
      end
    end

    def self.register_middleware(app)
      app.use AuthorizationRedactor
    end
  end
end

configure do
  set :log_inspector, RestGate::LogInspector.new(REQUEST_RESPONSE_LOG_DIR)
end

before '/_restgate*' do
  halt 404 unless RESTGATE_UI_ENABLED
  protect_restgate_ui!
  cache_control :no_store
  headers 'Content-Security-Policy' => "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'",
          'Referrer-Policy' => 'same-origin',
          'X-Content-Type-Options' => 'nosniff',
          'X-Frame-Options' => 'DENY',
          'X-Robots-Tag' => 'noindex, nofollow'
end

get '/_restgate/assets/:filename' do
  type, path = RestGate::UI::ASSETS[params['filename']]
  halt 404 unless path && File.file?(path)

  content_type type
  send_file path
end

get '/_restgate' do
  @filters = RestGate::UI::FILTER_KEYS.to_h { [_1, params[_1].to_s] }
  @result = settings.log_inspector.search(@filters)
  slim :restgate_logs, layout: :restgate_layout
end

get '/_restgate/logs/:filename/raw' do
  path = settings.log_inspector.raw_path(params['filename'])
  send_file path, filename: params['filename'], disposition: 'attachment', type: 'application/json'
rescue RestGate::LogInspector::NotFound => e
  halt 404, e.message
end

get '/_restgate/logs/:filename/body' do
  detail = settings.log_inspector.find(params['filename'])
  path = settings.log_inspector.attachment(detail)
  content_type detail.record.content_type unless detail.record.content_type.empty?
  send_file path, filename: File.basename(path), disposition: 'inline'
rescue RestGate::LogInspector::NotFound, RestGate::LogInspector::Unreadable => e
  halt 404, e.message
end

get '/_restgate/logs/:filename' do
  @detail = settings.log_inspector.find(params['filename'])
  @reveal_sensitive = params['reveal'] == '1'
  @request_headers = restgate_visible_headers(@detail.entry.dig('request', 'headers'))
  @response_headers = restgate_visible_headers(@detail.entry.dig('response', 'headers'))
  @request_body = restgate_body_view(@detail.entry.dig('request', 'body'))
  @response_body = restgate_body_view(@detail.entry.dig('response', 'body'))
  @query_params = restgate_query_pairs(@detail.entry.dig('request', 'query_string'))
  @raw_entry = restgate_visible_entry(@detail.entry)
  slim :restgate_log, layout: :restgate_layout
rescue RestGate::LogInspector::NotFound => e
  halt 404, e.message
rescue RestGate::LogInspector::Unreadable => e
  halt 422, e.message
end

helpers do
  def protect_restgate_ui!
    return unless restgate_ui_protected?

    authentication = Rack::Auth::Basic::Request.new(
      'HTTP_AUTHORIZATION' => request.env[RestGate::UI::AuthorizationRedactor::AUTHORIZATION_ENV]
    )
    valid = authentication.provided? && authentication.basic? && authentication.credentials &&
            secure_value_match?(authentication.credentials[0], RestGate::UI::USERNAME) &&
            secure_value_match?(authentication.credentials[1], RestGate::UI::PASSWORD)
    return if valid

    response['WWW-Authenticate'] = 'Basic realm="Rest Gate logs"'
    halt 401, 'Authentication is required to inspect stored Rest Gate logs'
  end

  def restgate_ui_protected?
    !RestGate::UI::USERNAME.empty? && !RestGate::UI::PASSWORD.empty?
  end

  def secure_value_match?(actual, expected)
    Rack::Utils.secure_compare(
      Digest::SHA256.hexdigest(actual.to_s),
      Digest::SHA256.hexdigest(expected.to_s)
    )
  end

  def restgate_list_url(overrides = {})
    values = RestGate::UI::FILTER_KEYS.to_h { [_1, @filters&.fetch(_1, '').to_s] }
    overrides.each { |key, value| values[key.to_s] = value.to_s }
    values.delete_if { |_, value| value.empty? }
    query = Rack::Utils.build_query(values)
    query.empty? ? '/_restgate' : "/_restgate?#{query}"
  end

  def restgate_detail_url(filename, overrides = {})
    values = { 'back' => restgate_back_url }
    values['reveal'] = '1' if @reveal_sensitive
    overrides.each do |key, value|
      value.to_s.empty? ? values.delete(key.to_s) : values[key.to_s] = value.to_s
    end
    "/_restgate/logs/#{filename}?#{Rack::Utils.build_query(values)}"
  end

  def restgate_record_url(filename)
    query = Rack::Utils.build_query('back' => restgate_list_url)
    "/_restgate/logs/#{filename}?#{query}"
  end

  def restgate_back_url
    candidate = params['back'].to_s
    return candidate if candidate.match?(%r{\A/_restgate(?:\?[^#]*)?\z})

    '/_restgate'
  end

  def restgate_visible_headers(headers)
    (headers || {}).sort.to_h do |name, value|
      visible = @reveal_sensitive || !RestGate::UI::SENSITIVE_HEADERS.match?(name) ? value : '[redacted]'
      [name, visible]
    end
  end

  def restgate_visible_entry(entry)
    entry.merge(
      'request' => entry.fetch('request', {}).merge('headers' => restgate_visible_headers(entry.dig('request', 'headers'))),
      'response' => entry.fetch('response', {}).merge('headers' => restgate_visible_headers(entry.dig('response', 'headers')))
    )
  end

  def restgate_body_view(body)
    return { text: '', bytes: 0, truncated: false, empty: true } if body.nil? || body == ''

    source = body.is_a?(String) ? body : JSON.generate(body)
    formatted = JSON.pretty_generate(JSON.parse(source))
    restgate_truncated_text(formatted, source.bytesize)
  rescue JSON::ParserError, JSON::GeneratorError
    restgate_truncated_text(source.to_s, source.to_s.bytesize)
  end

  def restgate_truncated_text(text, original_bytes)
    limit = [RestGate::UI::BODY_PREVIEW_BYTES, 0].max
    truncated = limit.positive? && text.bytesize > limit
    preview = truncated ? text.byteslice(0, limit).to_s.scrub : text.to_s.scrub
    { text: preview, bytes: original_bytes, truncated:, empty: false }
  end

  def restgate_query_pairs(query)
    return [] if query.to_s.empty?

    URI.decode_www_form(query.to_s)
  rescue ArgumentError
    [['Raw query', query.to_s]]
  end

  def restgate_timestamp(value)
    value&.utc&.strftime('%Y-%m-%d %H:%M:%S.%L UTC') || 'Unknown'
  end

  def restgate_bytes(value)
    number = value.to_i
    return "#{number} B" if number < 1024
    return format('%.1f KB', number / 1024.0) if number < 1024 * 1024

    format('%.1f MB', number / (1024.0 * 1024))
  end

  def restgate_duration(value)
    value.nil? ? '—' : format('%.1f ms', value)
  end

  def restgate_status_tone(status)
    return 'invalid' unless status
    return 'success' if status < 400
    return 'warning' if status < 500

    'danger'
  end
end
