require "json"
require "tmpdir"
require "uri"
require_relative "../support/rack_helper"

FakeUpstreamResponse = Struct.new(:status, :headers, :body)

class FakeProxyClient
  attr_reader :calls

  def initialize(response)
    @response = response
  end

  def send(*args)
    @calls = args
    @response
  end

  def build_url = URI("https://upstream.test")
end

RSpec.describe "Request and response logging", type: :request do
  let(:upstream_response) do
    FakeUpstreamResponse.new(
      201,
      { "content-type" => "application/json", "x-upstream" => "true" },
      '{"url":"https://upstream.test/api/items"}'
    )
  end

  let(:client) { FakeProxyClient.new(upstream_response) }
  let(:log_dir) { Dir.mktmpdir("request_response_logs") }

  around do |example|
    app_class = Sinatra::Application
    original_clients = app_class.settings.http_clients
    original_log_dir = app_class.settings.request_response_log_dir
    original_log_ttl = app_class.settings.request_response_log_ttl_seconds
    original_cleanup_interval = app_class.settings.request_response_log_cleanup_interval_seconds
    original_last_cleanup_at = app_class.settings.request_response_log_last_cleanup_at

    app_class.set :http_clients, { "/proxy" => client }
    app_class.set :request_response_log_dir, log_dir
    app_class.set :request_response_log_ttl_seconds, 3600
    app_class.set :request_response_log_cleanup_interval_seconds, 300
    app_class.set :request_response_log_last_cleanup_at, Time.at(0)

    example.run
  ensure
    app_class.set :http_clients, original_clients
    app_class.set :request_response_log_dir, original_log_dir
    app_class.set :request_response_log_ttl_seconds, original_log_ttl
    app_class.set :request_response_log_cleanup_interval_seconds, original_cleanup_interval
    app_class.set :request_response_log_last_cleanup_at, original_last_cleanup_at
    FileUtils.remove_entry(log_dir)
  end

  it "writes request and response to a dedicated log file" do
    header "X-Trace-Id", "trace-123"

    post "/proxy/api/items?draft=true", '{"name":"demo"}', { "CONTENT_TYPE" => "application/json" }

    expect(last_response.status).to eq(201)
    expect(last_response.body).to eq('{"url":"https://upstream.test/api/items"}')
    expect(client.calls[0..2]).to eq([
      :post,
      "/api/items?draft=true",
      '{"name":"demo"}'
    ])
    expect(client.calls[3]).to include("X-Trace-Id" => "trace-123", "Accept-Encoding" => "identity")

    log_files = Dir.children(log_dir)
    expect(log_files.size).to eq(1)
    expect(log_files.first).to end_with(".json")

    entry = JSON.parse(File.read(File.join(log_dir, log_files.first)))

    expect(entry.dig("request", "method")).to eq("POST")
    expect(entry.dig("request", "path")).to eq("/proxy/api/items")
    expect(entry.dig("request", "target_path")).to eq("/api/items?draft=true")
    expect(entry.dig("request", "headers")).to include("X-Trace-Id" => "trace-123", "Accept-Encoding" => "identity")
    expect(entry.dig("request", "body")).to eq('{"name":"demo"}')
    expect(entry.dig("response", "status")).to eq(201)
    expect(entry.dig("response", "headers")).to include("content-type" => "application/json")
    expect(entry.dig("response", "body")).to eq('{"url":"https://upstream.test/api/items"}')
    expect(entry.dig("proxy", "prefix")).to eq("/proxy")
    expect(entry.dig("proxy", "upstream")).to eq("https://upstream.test")
    expect(entry.fetch("timestamp")).to be_a(String)
  end

  it "stores binary responses in a sibling file and references it from json" do
    binary_body = "\x89PNG\r\n\x1A\nbinary-image".b
    client = FakeProxyClient.new(FakeUpstreamResponse.new(200, { "content-type" => "image/png" }, binary_body))
    Sinatra::Application.set :http_clients, { "/proxy" => client }

    get "/proxy/assets/logo.png"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to eq(binary_body)

    log_files = Dir.children(log_dir).sort
    expect(log_files.size).to eq(2)

    json_file = log_files.find { _1.end_with?(".json") }
    binary_file = log_files.find { _1.end_with?(".png") }
    expect(json_file).not_to be_nil
    expect(binary_file).not_to be_nil
    expect(File.binread(File.join(log_dir, binary_file))).to eq(binary_body)

    entry = JSON.parse(File.read(File.join(log_dir, json_file)))

    expect(entry.dig("response", "body")).to eq("[binary body saved, #{binary_body.bytesize} bytes]")
    expect(entry.dig("response", "body_file")).to eq(binary_file)
  end

  it "removes expired log files before writing new ones" do
    app_class = Sinatra::Application
    app_class.set :request_response_log_ttl_seconds, 3600
    app_class.set :request_response_log_cleanup_interval_seconds, 0
    app_class.set :request_response_log_last_cleanup_at, Time.at(0)

    stale_json = File.join(log_dir, "stale.json")
    stale_binary = File.join(log_dir, "stale.png")
    File.write(stale_json, "{}")
    File.binwrite(stale_binary, "old")
    old_time = Time.now - 7200
    File.utime(old_time, old_time, stale_json)
    File.utime(old_time, old_time, stale_binary)

    get "/proxy/index"

    log_files = Dir.children(log_dir)
    expect(log_files).not_to include("stale.json", "stale.png")
    expect(log_files.count { _1.end_with?(".json") }).to eq(1)
  end
end
