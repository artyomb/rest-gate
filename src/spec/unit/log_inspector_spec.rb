require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../spec_helper'
require_relative '../../log_inspector'

RSpec.describe RestGate::LogInspector do
  let(:directory) { Dir.mktmpdir('restgate-log-inspector') }
  let(:inspector) { described_class.new(directory) }

  after { FileUtils.remove_entry(directory) }

  def write_record(filename, path:, query: '', status: 200, duration: 10.0, body_file: nil)
    entry = {
      request: { method: 'GET', path:, query_string: query, headers: {}, body: nil },
      response: {
        status:,
        headers: { 'content-type' => 'application/json' },
        body: '{}',
        body_file:
      }.compact,
      proxy: { prefix: '/objectfinder', upstream: 'http://objectfinder:8080' },
      timing: { duration_ms: duration },
      timestamp: '2026-08-14T08:00:00Z'
    }
    File.write(File.join(directory, filename), JSON.generate(entry))
  end

  it 'searches, filters, sorts, and paginates cached summaries' do
    write_record('20260814T080000000001_first.json', path: '/objectfinder/api/first', query: 'id=1', duration: 5)
    write_record('20260814T080000000002_second.json', path: '/objectfinder/api/second', status: 503, duration: 25)

    result = inspector.search('q' => 'objectfinder api', 'status' => 'errors', 'sort' => 'duration_desc')

    expect(result.total).to eq(2)
    expect(result.matched).to eq(1)
    expect(result.records.first.path).to eq('/objectfinder/api/second')
    expect(result.errors).to eq(1)
    expect(result.methods).to eq(['GET'])
    expect(result.prefixes).to eq(['/objectfinder'])
  end

  it 'refreshes changed files and reports invalid JSON without failing the listing' do
    filename = '20260814T080000000001_record.json'
    write_record(filename, path: '/objectfinder/api/first')
    expect(inspector.search.records.first.path).to eq('/objectfinder/api/first')

    File.write(File.join(directory, filename), '{invalid')
    result = inspector.search

    expect(result.records.first).to be_invalid
    expect(result.errors).to eq(1)
  end

  it 'allows only the binary attachment referenced by the selected JSON record' do
    filename = '20260814T080000000001_record.json'
    attachment = '20260814T080000000001_record.png'
    write_record(filename, path: '/objectfinder/image', body_file: attachment)
    File.binwrite(File.join(directory, attachment), 'image')

    detail = inspector.find(filename)

    expect(inspector.attachment(detail)).to eq(File.join(directory, attachment))
    expect { inspector.raw_path('../record.json') }.to raise_error(described_class::NotFound)

    detail.entry['response']['body_file'] = 'unrelated.png'
    expect { inspector.attachment(detail) }.to raise_error(described_class::NotFound)
  end
end
