require 'falcon/server'
require 'async/http/endpoint'
require 'net/http'
require 'socket'
require_relative '../support/rack_helper'
require_relative '../../client_idle_timeout'

RSpec.describe RestGate::ClientIdleTimeout do
  around do |example|
    original_seconds = described_class.seconds || 60
    described_class.install!(0.15)
    example.run
  ensure
    described_class.install!(original_seconds)
  end

  def with_server(application = ->(_) { [200, { 'content-length' => '2' }, ['ok']] })
    listener = TCPServer.new('127.0.0.1', 0)
    port = listener.local_address.ip_port
    endpoint = Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}")
    server = Falcon::Server.new(Falcon::Server.rack_middleware(application, cache: false), endpoint)
    accepted_ports = []
    server_task = Async::Task.current.async do |task|
      loop do
        socket = listener.accept
        accepted_ports << socket.remote_address.ip_port
        task.async(socket) { |_, peer| server.accept(peer, peer.remote_address) }
      end
    end

    yield port, accepted_ports
  ensure
    server_task&.stop
    listener&.close
  end

  def with_client(port)
    client = Net::HTTP.new('127.0.0.1', port, nil)
    client.read_timeout = 2
    client.max_retries = 0
    client.start { yield client }
  end

  def read_response(socket)
    Async::Task.current.with_timeout(2) do
      status = socket.gets
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(':', 2)
        headers[name.downcase] = value.strip
      end
      [status, socket.read(Integer(headers.fetch('content-length')))]
    end
  end

  def request = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"

  it 'validates the idle limit and allows zero to disable it' do
    described_class.install!('0')
    expect(described_class.seconds).to eq(0)
    described_class.install!('0.25')
    expect(described_class.seconds).to eq(0.25)

    ['', 'invalid', -1, Float::INFINITY, Float::NAN].each do |value|
      expect { described_class.install!(value) }.to raise_error(ArgumentError, /CLIENT_IDLE_TIMEOUT_SECONDS/)
    end
  end

  it 'keeps frequent requests on one connection and resets the idle deadline' do
    with_server do |port, accepted_ports|
      with_client(port) do |client|
        4.times do
          expect(client.get('/').body).to eq('ok')
          sleep 0.08
        end
        expect(accepted_ports.size).to eq(1)
      end
    end
  end

  it 'closes an idle connection with EOF instead of an HTTP error' do
    with_server do |port|
      socket = TCPSocket.new('127.0.0.1', port)
      socket.write(request)
      expect(read_response(socket)).to eq(["HTTP/1.1 200 OK\r\n", 'ok'])
      expect(Async::Task.current.with_timeout(2) { socket.read(1) }).to be_nil
    ensure
      socket&.close
    end
  end

  it 'lets a pooled client reconnect after expiry without retrying a request' do
    with_server do |port, accepted_ports|
      with_client(port) do |client|
        expect(client.get('/').body).to eq('ok')
        sleep 0.3
        expect(client.get('/').body).to eq('ok')
        expect(accepted_ports.size).to eq(2)
      end
    end
  end

  it 'does not expire a connection during long backend processing' do
    application = ->(_) do
      sleep 0.3
      [200, { 'content-length' => '2' }, ['ok']]
    end
    with_server(application) do |port, accepted_ports|
      with_client(port) do |client|
        2.times { expect(client.get('/').body).to eq('ok') }
        expect(accepted_ports.size).to eq(1)
      end
    end
  end

  it 'does not expire a connection during slow response delivery' do
    application = ->(_) do
      body = Enumerator.new do |output|
        output << 'first'
        sleep 0.3
        output << 'second'
      end
      [200, {}, body]
    end
    with_server(application) do |port|
      with_client(port) { |client| expect(client.get('/').body).to eq('firstsecond') }
    end
  end

  it 'does not expire an active request while its body is being uploaded' do
    application = ->(env) do
      body = env.fetch('rack.input').read
      [200, { 'content-length' => body.bytesize.to_s }, [body]]
    end
    with_server(application) do |port|
      socket = TCPSocket.new('127.0.0.1', port)
      socket.write("POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\n\r\nabc")
      sleep 0.3
      socket.write('def')
      expect(read_response(socket)).to eq(["HTTP/1.1 200 OK\r\n", 'abcdef'])
    ensure
      socket&.close
    end
  end

  it 'ends the idle deadline as soon as the first request byte arrives' do
    with_server do |port|
      socket = TCPSocket.new('127.0.0.1', port)
      socket.write('G')
      sleep 0.3
      socket.write(request.byteslice(1..))
      expect(read_response(socket)).to eq(["HTTP/1.1 200 OK\r\n", 'ok'])
    ensure
      socket&.close
    end
  end

  it 'preserves buffered pipelined requests' do
    with_server do |port, accepted_ports|
      socket = TCPSocket.new('127.0.0.1', port)
      socket.write(request * 2)
      2.times { expect(read_response(socket)).to eq(["HTTP/1.1 200 OK\r\n", 'ok']) }
      expect(accepted_ports.size).to eq(1)
    ensure
      socket&.close
    end
  end

  it 'retains the previous unlimited idle wait when disabled' do
    described_class.install!(0)
    with_server do |port, accepted_ports|
      with_client(port) do |client|
        expect(client.get('/').body).to eq('ok')
        sleep 0.3
        expect(client.get('/').body).to eq('ok')
        expect(accepted_ports.size).to eq(1)
      end
    end
  end
end
