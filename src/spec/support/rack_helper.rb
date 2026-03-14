require 'stack-service-base/logging'
require 'rack/test'
require 'async/rspec'
require 'rack/builder'

module Rack::Test::AppHelper
  def app = RSpec.configuration.app
end

RSpec.configure do |config|
  config.include Rack::Test::AppHelper, type: :request
  config.include Rack::Test::Methods, type: :request
  config.include_context Async::RSpec::Reactor
  config.add_setting :app

  # Tag anything under /integration as :integration
  # config.define_derived_metadata(file_path: %r{/spec/integration/}) { |m| m[:type] = :integration }

  # ensure this only runs for request specs; avoid leaking into other types
  config.before(type: :request) do
    header 'Host', 'localhost'
  end

  # Load Rack app only once when first integration test runs
  config.before(:suite) do
    if RSpec.world.filtered_examples.values.flatten.any? { |e| e.metadata[:type] == :request }
      ENV['RUBYOPT'] = [ENV['RUBYOPT'], 'ruby-debug-ide'].compact.join(' ')
      rack_app, = Rack::Builder.parse_file(File.expand_path("../../config.ru", __dir__))
      RSpec.configuration.app = rack_app
    end
  end
end
