require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative '../support/rack_helper'

RSpec.describe 'Stored log inspector', type: :request do
  let(:directory) { Dir.mktmpdir('restgate-log-inspector-request') }
  let(:filename) { '20260814T080000000001_record.json' }
  let(:entry) do
    {
      request: {
        method: 'POST',
        path: '/objectfinder/api/search',
        target_path: '/api/search?id=42',
        query_string: 'id=42',
        headers: { 'Authorization' => 'secret-token', 'Accept' => 'application/json' },
        body: '{"query":"demo"}',
        ip: '192.0.2.1'
      },
      response: {
        status: 200,
        headers: { 'content-type' => 'application/json', 'Set-Cookie' => 'secret-cookie' },
        body: '{"result":true}'
      },
      proxy: { prefix: '/objectfinder', upstream: 'http://objectfinder:8080' },
      timing: { duration_ms: 12.5 },
      timestamp: '2026-08-14T08:00:00Z'
    }
  end

  around do |example|
    app_class = Sinatra::Application
    original_inspector = app_class.settings.log_inspector
    File.write(File.join(directory, filename), JSON.generate(entry))
    app_class.set :log_inspector, RestGate::LogInspector.new(directory)
    example.run
  ensure
    app_class.set :log_inspector, original_inspector
    FileUtils.remove_entry(directory)
  end

  it 'renders a searchable, non-cacheable log listing' do
    get '/_restgate', q: 'api search', status: '2xx'

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Stored request/response logs', '/objectfinder/api/search')
    expect(last_response.headers.fetch('Cache-Control')).to include('no-store')
    expect(last_response.headers.fetch('Content-Security-Policy')).to include("default-src 'self'")
  end

  it 'renders details with sensitive headers redacted by default' do
    get "/_restgate/logs/#{filename}"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('[redacted]')
    expect(last_response.body).not_to include('secret-token', 'secret-cookie')
    expect(last_response.body).to include('&quot;result&quot;: true')
  end

  it 'reveals sensitive headers only after an explicit request' do
    get "/_restgate/logs/#{filename}", reveal: '1'

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('secret-token', 'secret-cookie')
  end

  it 'serves viewer assets below the reserved UI prefix' do
    get '/_restgate/assets/restgate.css'

    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to start_with('text/css')
  end

  it 'protects the complete inspector when UI credentials are configured' do
    stub_const('RestGate::UI::USERNAME', 'viewer')
    stub_const('RestGate::UI::PASSWORD', 'test-password')

    get '/_restgate'
    expect(last_response.status).to eq(401)
    expect(last_response.headers.fetch('WWW-Authenticate')).to include('Basic')

    basic_authorize 'viewer', 'test-password'
    get '/_restgate'
    expect(last_response.status).to eq(200)
  end

  it 'does not load or proxy the inspector when it is disabled at boot' do
    script = <<~'RUBY'
      app, = Rack::Builder.parse_file('config.ru')
      abort 'UI implementation was loaded' if defined?(RestGate::UI)
      Sync do
        response = Rack::MockRequest.new(app).get('/_restgate')
        abort "Unexpected status: #{response.status}" unless response.status == 404
      end
      puts 'UI not loaded; prefix reserved'
    RUBY
    stdout, stderr, status = Open3.capture3(
      {
        'RESTGATE_UI_ENABLED' => 'false',
        'REQUEST_RESPONSE_LOG_DIR' => directory,
        'RUBYOPT' => nil
      },
      RbConfig.ruby, '-rbundler/setup', '-rrack', '-rasync', '-e', script,
      chdir: File.expand_path('../..', __dir__)
    )

    expect(status).to be_success, "#{stdout}\n#{stderr}"
    expect(stdout).to include('UI not loaded; prefix reserved')
  end
end
