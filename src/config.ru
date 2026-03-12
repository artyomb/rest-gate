require 'sinatra'
require 'faraday'
require 'faraday/retry'
require 'faraday/net_http_persistent'
require 'stack-service-base'
require 'json'
require 'fileutils'
require 'securerandom'
require 'time'

StackServiceBase.rack_setup self

DEFAULT_UPSTREAM_PORT = 80
PROXY_MAP = ENV.fetch 'PROXY_MAP', '/test1:localhost:9293,/test2:localhost:9293' #"/prefix:host[:port]"
BASE_URL = ENV.fetch 'BASE_URL', 'http://localhost:9287'
REQUEST_RESPONSE_LOG_DIR = ENV.fetch('REQUEST_RESPONSE_LOG_DIR', File.expand_path('log/request_responses', __dir__))
REQUEST_RESPONSE_LOG_BODY_LIMIT = Integer(ENV.fetch('REQUEST_RESPONSE_LOG_BODY_LIMIT', '4096'), exception: false) || 4096
BINARY_CONTENT_TYPE_PATTERN = /octet-stream|x-protobuf|image|video|audio|font|pdf|zip/
BODYLESS_METHODS = %i[get head delete options].freeze
REQUEST_HEADERS_TO_SKIP = %w[host connection proxy-connection content-length accept-encoding].freeze
RESPONSE_HEADERS_TO_SKIP = %w[connection proxy-connection transfer-encoding content-length].freeze

def parse_proxy_map(proxy_map)
  proxy_map.gsub(/\s+/, '').split(',').to_h do |entry|
    prefix, host, port = entry.split(':', 3)
    [prefix, { host:, port: (port || DEFAULT_UPSTREAM_PORT).to_i }]
  end
end

configure do
  proxy_map = parse_proxy_map(PROXY_MAP)
  set :http_clients, proxy_map.transform_values {
    Faraday.new url: "http://#{_1.fetch(:host)}:#{_1.fetch(:port)}" do |f|
      f.request  :retry, max: 2, interval: 0.2, backoff_factor: 2
      f.options.timeout      = 15
      f.options.open_timeout = 10
      f.adapter :net_http_persistent, pool_size: 10, idle_timeout: 60
    end
  }
  set :request_response_log_dir, REQUEST_RESPONSE_LOG_DIR

  FileUtils.mkdir_p settings.request_response_log_dir
end

use Rack.middleware_klass do |env, app|
  status, headers, body = app.call(env)
  headers.delete('content-encoding')
  [status, headers, body]
end

%w[get post put delete head patch].each do |method|
  send method, '*', &-> { proxy_request }
end

helpers do
  def proxy_request
    prefix, client = settings.http_clients.find { |prefix, _| request.path_info.start_with?(prefix) }
    halt 404, "Proxy not found for path: #{request.path_info}" unless prefix && client

    method = request.request_method.downcase.to_sym
    request_headers = build_request_headers
    request_body = BODYLESS_METHODS.include?(method) ? nil : read_request_body
    target_path = [request.path_info.delete_prefix(prefix), request.query_string].reject(&:empty?).join('?')
    args = [method, target_path]
    args << request_body unless BODYLESS_METHODS.include?(method)
    args << request_headers

    response = client.send(*args)
    # response_body = render_response_body(response, client, prefix)
    response_body = response.body
    status response.status
    copy_headers_from_response(response.headers)
    body response_body

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
        upstream: client.build_url.to_s
      }
    }, response_body:, response_content_type: response.headers['content-type'])
  end

  def build_request_headers
    request.env.each_with_object('Accept-Encoding' => 'identity') do |(key, value), headers|
      next unless key.start_with?('HTTP_')
      header = key.delete_prefix('HTTP_').tr('_', '-').split('-').map(&:capitalize).join('-')
      headers[header] = value unless REQUEST_HEADERS_TO_SKIP.include?(header.downcase)
    end
  end

  def copy_headers_from_response(response_headers)
    response_headers.each do |name, value|
      headers[name] = value unless RESPONSE_HEADERS_TO_SKIP.include?(name.downcase)
    end
  end

  def read_request_body
    request.body.rewind
    request.body.read.tap { request.body.rewind }
  end

  def binary_content_type?(content_type) = content_type.to_s.match?(BINARY_CONTENT_TYPE_PATTERN)

  def body_for_log(body, content_type)
    body = body.to_s
    return if body.empty?
    return "[binary body omitted, #{body.bytesize} bytes]" if binary_content_type?(content_type)
    return body if body.bytesize <= REQUEST_RESPONSE_LOG_BODY_LIMIT

    "#{body.byteslice(0, REQUEST_RESPONSE_LOG_BODY_LIMIT)}...[truncated #{body.bytesize - REQUEST_RESPONSE_LOG_BODY_LIMIT} bytes]"
  end

  def append_request_response_log(entry, response_body:, response_content_type:)
    timestamp = Time.now.utc
    basename = "#{timestamp.strftime('%Y%m%dT%H%M%S%6N')}_#{SecureRandom.uuid}"
    save_binary_response_body(basename, response_body, response_content_type, entry[:response])
    File.write(File.join(settings.request_response_log_dir, "#{basename}.json"), JSON.pretty_generate(entry.merge(timestamp: timestamp.iso8601)))
    nil
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
end

run Sinatra::Application
