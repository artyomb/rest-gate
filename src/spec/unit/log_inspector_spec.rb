require 'fileutils'
require 'json'
require 'tmpdir'
require_relative '../spec_helper'
require_relative '../../log_inspector'

RSpec.describe RestGate::LogInspector do
  let(:directory) { Dir.mktmpdir('restgate-log-inspector') }
  let(:inspector) { described_class.new(directory) }

  after { FileUtils.remove_entry(directory) }

  def write_record(filename, path:, query: '', status: 200, duration: 10.0, body_file: nil, retention: nil)
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
    entry[:retention] = { definition: retention } if retention
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

  it 'combines retention filtering with path and query-presence statistics' do
    retention = '10:{ALL}+{QUERY:.*}+{URL:\A/objectfinder/api/items\z}'
    other_retention = '30:{GET}+{QUERY:id=.*}+{URL:.*}'
    write_record('20260814T080000000001_first.json', path: '/objectfinder/api/items', retention:)
    write_record(
      '20260814T080000000002_second.json',
      path: '/objectfinder/api/items',
      query: 'id=1',
      retention:
    )
    write_record(
      '20260814T080000000003_other.json',
      path: '/objectfinder/api/other',
      query: 'id=2',
      retention: other_retention
    )

    result = inspector.search('retention' => retention)

    expect(result.matched).to eq(2)
    expect(result.retentions).to contain_exactly(retention, other_retention)
    expect(result.retention_counts).to eq(retention => 2, other_retention => 1)
    expect(result.path_stats.map(&:to_h)).to eq([
      { path: '/objectfinder/api/items', total: 2, without_query: 1, with_query: 1 }
    ])
  end

  it 'attributes legacy records with the current retention matcher' do
    retention = '10:{ALL}+{QUERY:.*}+{URL:\A/objectfinder/api/items\z}'
    rules = [{ definition: retention }]
    matcher = ->(configured_rules, _method, _query, path) {
      configured_rules.first if path == '/objectfinder/api/items'
    }
    legacy_inspector = described_class.new(directory, retention_rules: rules, retention_matcher: matcher)
    write_record('20260814T080000000001_legacy.json', path: '/objectfinder/api/items')

    result = legacy_inspector.search('retention' => retention)

    expect(result.matched).to eq(1)
    expect(result.records.first.retention).to eq(retention)
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
