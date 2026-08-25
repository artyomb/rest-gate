ENV['NO_RT_DEBUG'] ||= 'true'

require 'stack-service-base'
require 'sinatra'
require 'faraday'
require 'faraday/retry'
require 'faraday/net_http_persistent'
require 'json'
require 'fileutils'
require 'securerandom'
require 'time'
require 'uri'

DEFAULT_UPSTREAM_PORT = 80
PROXY_MAP = ENV.fetch 'PROXY_MAP', '/api:http://example.ru/base/path/api' # "/prefix:host[:port]" or "/prefix:https://host[:port]/base/path"
REQUEST_RESPONSE_LOG_DIR = ENV.fetch('REQUEST_RESPONSE_LOG_DIR', File.expand_path('log/request_responses', __dir__))
REQUEST_RESPONSE_LOG_BODY_LIMIT = Integer(ENV.fetch('REQUEST_RESPONSE_LOG_BODY_LIMIT', '0'), exception: false) || 0
REQUEST_RESPONSE_LOG_TTL_SECONDS = Integer(ENV.fetch('REQUEST_RESPONSE_LOG_TTL_SECONDS', '3600'), exception: false) || 3600
REQUEST_RESPONSE_LOG_CLEANUP_INTERVAL_SECONDS = Integer(ENV.fetch('REQUEST_RESPONSE_LOG_CLEANUP_INTERVAL_SECONDS', '300'), exception: false) || 300
RESTGATE_UI_ENABLED = ENV.fetch('RESTGATE_UI_ENABLED', 'true').downcase == 'true'
# Comma-separated N:{METHODS}+{QUERY:regexp}+{URL:regexp} rules; later matches take precedence.
RETENTION = ENV.fetch('RETENTION', '')
BINARY_CONTENT_TYPE_PATTERN = /octet-stream|x-protobuf|image|video|audio|font|pdf|zip/
BODYLESS_METHODS = %i[get head delete options].freeze
HOP_BY_HOP_HEADERS = %w[
  connection keep-alive proxy-authenticate proxy-authorization public te trailer transfer-encoding upgrade
].freeze
REQUEST_HEADERS_TO_SKIP = (HOP_BY_HOP_HEADERS + %w[host proxy-connection content-length accept-encoding]).freeze
RESPONSE_HEADERS_TO_SKIP = (HOP_BY_HOP_HEADERS + %w[proxy-connection content-length]).freeze

module Retention
  module_function

  def parse(value)
    value = value.to_s.strip
    return [].freeze if value.empty?

    value.split(/,(?=\s*\d+:\{)/).map do |definition|
      definition = definition.strip
      match = definition.match(/\A(\d+):\{([^{}]+)\}\+\{QUERY:(.*)\}\+\{URL:(.*)\}\z/)
      raise ArgumentError, "Invalid RETENTION rule: #{definition}" unless match

      methods = match[2].split(',').map { _1.strip.upcase }
      valid_methods = methods == ['ALL'] || (!methods.include?('ALL') && methods.all? { _1.match?(/\A[A-Z]+\z/) })
      raise ArgumentError, "Invalid RETENTION rule: #{definition}" unless match[1].to_i.positive? && valid_methods

      {
        definition:,
        limit: match[1].to_i,
        methods: methods == ['ALL'] ? nil : methods.freeze,
        query: Regexp.new(match[3]),
        url: Regexp.new(match[4])
      }.freeze
    rescue RegexpError => e
      raise ArgumentError, "Invalid RETENTION regex in #{definition}: #{e.message}"
    end.freeze
  end

  def match(rules, method, query, url)
    rules.reverse_each.find do |rule|
      (rule[:methods].nil? || rule[:methods].include?(method)) &&
        rule[:query].match?(query) &&
        rule[:url].match?(url)
    end
  end
end

RETENTION_RULES = Retention.parse(RETENTION)

if RESTGATE_UI_ENABLED
  require_relative 'restgate_ui'
end

# StackServiceBase appends trace IDs to 5xx bodies after Sinatra calculates Content-Length.
use Rack.middleware_klass do |env, app|
  status, headers, body = app.call(env)
  headers.delete('content-length') if status.to_i >= 500
  [status, headers, body]
end
use Rack::TempfileReaper
use Rack.middleware_klass do |env, app|
  input = Rack::RewindableInput.new(env['rack.input']) if env['rack.input']
  env['rack.input'] = input if input
  app.call(env)
ensure
  input&.close
end
RestGate::UI.register_middleware(self) if RESTGATE_UI_ENABLED
StackServiceBase.rack_setup self

def parse_proxy_map(proxy_map)
  proxy_map.gsub(/\s+/, '').split(',').reject(&:empty?).to_h { parse_proxy_map_entry(_1) }
end

def parse_proxy_map_entry(entry)
  prefix, upstream = entry.split(':', 2)
  raise ArgumentError, "Invalid PROXY_MAP entry: #{entry}" if prefix.to_s.empty? || upstream.to_s.empty?

  [prefix, parse_upstream_target(upstream)]
end

def parse_upstream_target(upstream)
  return parse_url_upstream_target(upstream) if upstream.include?('://')

  host, port = upstream.split(':', 2)
  port = (port || DEFAULT_UPSTREAM_PORT).to_i

  {
    scheme: 'http',
    host:,
    port:,
    path_prefix: '',
    url: "http://#{host}:#{port}"
  }
end

def parse_url_upstream_target(upstream)
  uri = URI.parse(upstream)
  raise ArgumentError, "Invalid upstream URL in PROXY_MAP: #{upstream}" if uri.scheme.to_s.empty? || uri.host.to_s.empty?

  {
    scheme: uri.scheme,
    host: uri.host,
    port: uri.port,
    path_prefix: normalize_upstream_path_prefix(uri.path),
    url: uri.to_s.sub(%r{/$}, '')
  }
end

def normalize_upstream_path_prefix(path)
  path = path.to_s
  return '' if path.empty? || path == '/'

  "/#{path}".gsub(%r{/+}, '/').sub(%r{/$}, '')
end

class RetentionStore
  def initialize(directory, rules = nil)
    @directory = directory
    @mutex = Mutex.new
    build_index(rules) if rules&.any?
  end

  def log_objects_exceeding_limit(rule, json_path, body_file, rules)
    @mutex.synchronize do
      build_index(rules) unless @rules.equal?(rules)
      objects = @objects_by_rule.fetch(rule)
      objects.select! { File.file?(_1.first) }
      objects << log_object(json_path, body_file) unless objects.any? { _1.first == json_path }
      objects.sort_by!(&:first)
      objects.shift([objects.length - rule[:limit], 0].max)
    end
  end

  private

  def build_index(rules)
    @rules = rules
    @objects_by_rule = rules.to_h { [_1, []] }

    Dir.children(@directory).sort.each do |filename|
      next unless filename.end_with?(".json")

      path = File.join(@directory, filename)
      entry = JSON.parse(File.read(path))
      rule = Retention.match(
        rules,
        entry.dig("request", "method").to_s,
        entry.dig("request", "query_string").to_s,
        entry.dig("request", "path").to_s
      )
      next unless rule

      @objects_by_rule.fetch(rule) << log_object(path, entry.dig("response", "body_file"))
    rescue JSON::ParserError, Errno::ENOENT
      next
    end
  end

  def log_object(json_path, body_file)
    return [json_path] if body_file.to_s.empty?

    filename = File.basename(body_file.to_s)
    basename = File.basename(json_path, ".json")
    return [json_path] unless filename.start_with?("#{basename}.")

    [json_path, File.join(@directory, filename)]
  end
end

configure do
  proxy_map = parse_proxy_map(PROXY_MAP)
  set :http_clients, proxy_map.transform_values {
    {
      path_prefix: _1.fetch(:path_prefix),
      url: _1.fetch(:url),
      connection: Faraday.new(url: "#{_1.fetch(:scheme)}://#{_1.fetch(:host)}:#{_1.fetch(:port)}") do |f|
        f.request  :retry, max: 2, interval: 0.2, backoff_factor: 2
        f.options.timeout      = 15
        f.options.open_timeout = 10
        f.adapter :net_http_persistent, pool_size: 10, idle_timeout: 60
      end
    }
  }
  set :request_response_log_dir, REQUEST_RESPONSE_LOG_DIR
  set :request_response_log_ttl_seconds, REQUEST_RESPONSE_LOG_TTL_SECONDS
  set :request_response_log_cleanup_interval_seconds, REQUEST_RESPONSE_LOG_CLEANUP_INTERVAL_SECONDS
  set :request_response_log_last_cleanup_at, Time.at(0)
  set :retention_rules, RETENTION_RULES

  FileUtils.mkdir_p settings.request_response_log_dir
  set :retention_store, RetentionStore.new(REQUEST_RESPONSE_LOG_DIR, settings.retention_rules)
end

use Rack.middleware_klass do |env, app|
  status, headers, body = app.call(env)
  headers.delete('content-encoding')
  [status, headers, body]
end

unless RESTGATE_UI_ENABLED
  get '/_restgate*' do
    halt 404
  end
end

%w[get post put delete head patch].each do |method|
  send method, '*', &-> { proxy_request }
end

helpers do
  def proxy_request
    prefix, upstream = settings.http_clients
                               .select { |path_prefix, _| request.path_info.start_with?(path_prefix) }
                               .max_by { |path_prefix, _| path_prefix.length }
    halt 404, "Proxy not found for path: #{request.path_info}" unless prefix && upstream

    method = request.request_method.downcase.to_sym
    request_headers = build_request_headers
    request_body = BODYLESS_METHODS.include?(method) ? nil : read_request_body
    client = upstream.fetch(:connection)
    target_path = build_target_path(prefix, upstream.fetch(:path_prefix))
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = client.run_request(method, target_path, request_body, request_headers)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(3)
    # response_body = render_response_body(response, client, prefix)
    response_body = response.body
    status response.status
    copy_headers_from_response(response.headers)
    body response_body

    otl_span("restgate.persist_request_response") do
      append_request_response_log({
        request: {
          method: request.request_method,
          path: request.path_info,
          target_path: target_path,
          query_string: request.query_string,
          headers: request_headers,
          body: body_for_log(request_body, request.content_type),
          ip: request.ip
        },
        response: {
          status: response.status,
          headers: response.headers,
          body: body_for_log(response_body, response.headers['content-type'])
        },
        proxy: {
          prefix: prefix,
          upstream: upstream.fetch(:url)
        },
        timing: {
          duration_ms: duration_ms
        }
      }, response_body:, response_content_type: response.headers['content-type'])
    end
  end

  def build_target_path(prefix, upstream_path_prefix)
    request_path = request.path_info.delete_prefix(prefix)
    request_path = '/' if request_path.empty?
    request_path = "/#{request_path}" unless request_path.start_with?('/')

    [ "#{upstream_path_prefix}#{request_path}", request.query_string ].reject(&:empty?).join('?')
  end

  def build_request_headers
    headers = request.env.each_with_object({}) do |(key, value), result|
      next unless key.start_with?('HTTP_')
      header = key.delete_prefix('HTTP_').tr('_', '-').split('-').map(&:capitalize).join('-')
      result[header] = value
    end
    skipped_headers = header_names_to_skip(headers, REQUEST_HEADERS_TO_SKIP)
    headers.reject! { |name, _| skipped_headers.include?(name.downcase) }
    headers['Accept-Encoding'] = 'identity'

    content_type = request.env['CONTENT_TYPE'].to_s
    headers['Content-Type'] = content_type unless content_type.empty?
    headers
  end

  def copy_headers_from_response(response_headers)
    skipped_headers = header_names_to_skip(response_headers, RESPONSE_HEADERS_TO_SKIP)
    response_headers.each do |name, value|
      headers[name] = value unless skipped_headers.include?(name.downcase)
    end
  end

  def header_names_to_skip(source_headers, defaults)
    connection = source_headers.find { |name, _| name.to_s.casecmp?('connection') }&.last
    defaults | connection.to_s.split(',').map { _1.strip.downcase }.reject(&:empty?)
  end

  def read_request_body
    body = request.body
    return '' unless body

    body.rewind if body.respond_to?(:rewind)
    body.read.to_s.tap { body.rewind if body.respond_to?(:rewind) }
  rescue EOFError
    halt 400, 'Request body stream ended unexpectedly'
  end

  def binary_content_type?(content_type) = content_type.to_s.match?(BINARY_CONTENT_TYPE_PATTERN)

  def body_for_log(body, content_type)
    body = body.to_s
    return if body.empty?
    return "[binary body omitted, #{body.bytesize} bytes]" if binary_content_type?(content_type)
    return body if REQUEST_RESPONSE_LOG_BODY_LIMIT <= 0
    return body if body.bytesize <= REQUEST_RESPONSE_LOG_BODY_LIMIT

    "#{body.byteslice(0, REQUEST_RESPONSE_LOG_BODY_LIMIT)}...[truncated #{body.bytesize - REQUEST_RESPONSE_LOG_BODY_LIMIT} bytes]"
  end

  def append_request_response_log(entry, response_body:, response_content_type:)
    retention_rule = matching_retention_rule(
      request.request_method, request.query_string, request.path_info
    )
    return if settings.retention_rules.any? && !retention_rule

    cleanup_expired_log_files_if_needed unless retention_rule

    timestamp = Time.now.utc
    basename = "#{timestamp.strftime('%Y%m%dT%H%M%S%6N')}_#{SecureRandom.uuid}"
    entry[:retention] = {
      definition: retention_rule[:definition],
      limit: retention_rule[:limit]
    } if retention_rule
    save_binary_response_body(basename, response_body, response_content_type, entry[:response])
    json_path = File.join(settings.request_response_log_dir, "#{basename}.json")
    File.write(json_path, JSON.pretty_generate(entry.merge(timestamp: timestamp.iso8601)))
    enforce_retention(retention_rule, json_path, entry.dig(:response, :body_file)) if retention_rule
    nil
  end

  def matching_retention_rule(method, query, url)
    Retention.match(settings.retention_rules, method, query, url)
  end

  def save_binary_response_body(basename, body, content_type, response_entry)
    body = body.to_s
    return unless binary_content_type?(content_type) && !body.empty?

    relative_path = "#{basename}#{binary_extension(content_type)}"
    File.binwrite(File.join(settings.request_response_log_dir, relative_path), body)
    response_entry[:body] = "[binary body saved, #{body.bytesize} bytes]"
    response_entry[:body_file] = relative_path
  end

  def binary_extension(content_type)
    subtype = content_type.to_s.split(';').first.to_s.split('/').last.to_s.downcase
    return '.bin' if subtype.empty? || subtype == 'octet-stream'
    return '.jpg' if subtype == 'jpeg'
    return '.pb' if subtype == 'x-protobuf'

    ".#{subtype.gsub(/[^a-z0-9.-]/, '_')}"
  end

  def cleanup_expired_log_files_if_needed
    ttl = settings.request_response_log_ttl_seconds
    return if ttl <= 0

    now = Time.now
    return if now - settings.request_response_log_last_cleanup_at < settings.request_response_log_cleanup_interval_seconds

    settings.request_response_log_last_cleanup_at = now
    delete_logs_older_than(now - ttl)
  end

  def delete_logs_older_than(cutoff_time)
    Dir.children(settings.request_response_log_dir).each do |filename|
      path = File.join(settings.request_response_log_dir, filename)
      next unless File.file?(path)
      next unless File.mtime(path) < cutoff_time

      File.delete(path)
    rescue Errno::ENOENT
      next
    end
  end

  def enforce_retention(rule, json_path, body_file)
    otl_span("restgate.enforce_retention") do
      settings.retention_store
              .log_objects_exceeding_limit(rule, json_path, body_file, settings.retention_rules)
              .each { delete_log_object(_1) }
    end
  end

  def delete_log_object(paths)
    paths.each { File.delete(_1) }
  rescue Errno::ENOENT
    nil
  end
end

run Sinatra::Application
