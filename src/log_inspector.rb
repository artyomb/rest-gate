require 'json'
require 'thread'
require 'time'

module RestGate
  class LogInspector
    DEFAULT_PAGE_SIZE = 50
    PAGE_SIZES = [25, 50, 100].freeze
    SAFE_JSON_FILENAME = /\A[0-9A-Za-z._-]+\.json\z/
    SAFE_ATTACHMENT_FILENAME = /\A[0-9A-Za-z._-]+\z/

    Record = Struct.new(
      :filename,
      :timestamp,
      :method,
      :path,
      :query,
      :status,
      :duration_ms,
      :upstream,
      :prefix,
      :retention,
      :content_type,
      :body_file,
      :bytes,
      :error,
      keyword_init: true
    ) do
      def invalid? = !error.nil?

      def display_path
        return path.to_s if query.to_s.empty?

        "#{path}?#{query}"
      end

      def search_text
        [method, display_path, status, upstream, prefix, retention, content_type, filename].compact.join(' ').downcase
      end
    end

    PathStat = Struct.new(:path, :total, :without_query, :with_query, keyword_init: true)

    Result = Struct.new(
      :records,
      :total,
      :matched,
      :errors,
      :bytes,
      :latest_at,
      :methods,
      :prefixes,
      :retentions,
      :retention_counts,
      :path_stats,
      :page,
      :pages,
      :per_page,
      keyword_init: true
    )

    Detail = Struct.new(:record, :entry, :path, keyword_init: true)

    class NotFound < StandardError; end
    class Unreadable < StandardError; end

    def initialize(directory, retention_rules: [], retention_matcher: nil)
      @directory = File.expand_path(directory)
      @retention_rules = retention_rules
      @retention_matcher = retention_matcher
      @mutex = Mutex.new
      @cache = {}
    end

    def search(filters = {})
      records = refresh_records
      filtered = filter_records(records, filters)
      ordered = sort_records(filtered, filters['sort'])
      per_page = normalize_page_size(filters['per_page'])
      pages = [(ordered.length.to_f / per_page).ceil, 1].max
      page = [[positive_integer(filters['page'], 1), 1].max, pages].min

      Result.new(
        records: ordered.slice((page - 1) * per_page, per_page) || [],
        total: records.length,
        matched: ordered.length,
        errors: records.count { _1.invalid? || _1.status.to_i >= 400 },
        bytes: records.sum(&:bytes),
        latest_at: records.filter_map(&:timestamp).max,
        methods: records.filter_map(&:method).uniq.sort,
        prefixes: records.filter_map(&:prefix).reject(&:empty?).uniq.sort,
        retentions: available_retentions(records),
        retention_counts: records.filter_map(&:retention).tally,
        path_stats: path_statistics(filtered),
        page:,
        pages:,
        per_page:
      )
    end

    def find(filename)
      path = json_path(filename)
      entry = JSON.parse(File.read(path))
      Detail.new(record: record_from(entry, filename, File.stat(path)), entry:, path:)
    rescue JSON::ParserError => e
      raise Unreadable, "Stored JSON is invalid: #{e.message}"
    rescue Errno::ENOENT
      raise NotFound, "Stored log was not found: #{filename}"
    end

    def raw_path(filename) = json_path(filename)

    def attachment(detail)
      filename = detail.entry.dig('response', 'body_file').to_s
      raise NotFound, 'This record has no binary response attachment' if filename.empty?
      raise NotFound, 'Invalid binary response attachment name' unless SAFE_ATTACHMENT_FILENAME.match?(filename)

      expected_prefix = "#{File.basename(detail.record.filename, '.json')}."
      raise NotFound, 'Binary response attachment does not belong to this record' unless filename.start_with?(expected_prefix)

      path = File.join(@directory, filename)
      raise NotFound, 'Binary response attachment was not found' unless File.file?(path)

      path
    end

    private

    def refresh_records
      @mutex.synchronize do
        filenames = Dir.children(@directory).select { SAFE_JSON_FILENAME.match?(_1) }
        filename_index = filenames.to_h { [_1, true] }
        @cache.delete_if { |filename, _| !filename_index.key?(filename) }

        filenames.each do |filename|
          path = File.join(@directory, filename)
          stat = File.stat(path)
          signature = [stat.mtime.to_f, stat.size]
          next if @cache.dig(filename, :signature) == signature

          @cache[filename] = { signature:, record: record_from_file(path, filename, stat) }
        rescue Errno::ENOENT
          @cache.delete(filename)
        end

        @cache.values.map { _1.fetch(:record) }
      end
    rescue Errno::ENOENT
      []
    end

    def record_from_file(path, filename, stat)
      record_from(JSON.parse(File.read(path)), filename, stat)
    rescue JSON::ParserError => e
      Record.new(
        filename:,
        timestamp: timestamp_from_filename(filename) || stat.mtime,
        bytes: stat.size,
        error: e.message
      )
    end

    def record_from(entry, filename, stat)
      method = entry.dig('request', 'method').to_s.upcase
      path = entry.dig('request', 'path').to_s
      query = entry.dig('request', 'query_string').to_s
      body_file = entry.dig('response', 'body_file').to_s
      Record.new(
        filename:,
        timestamp: parse_timestamp(entry['timestamp']) || timestamp_from_filename(filename) || stat.mtime,
        method:,
        path:,
        query:,
        status: integer_or_nil(entry.dig('response', 'status')),
        duration_ms: float_or_nil(entry.dig('timing', 'duration_ms')),
        upstream: entry.dig('proxy', 'upstream').to_s,
        prefix: entry.dig('proxy', 'prefix').to_s,
        retention: retention_definition(entry, method, query, path),
        content_type: entry.dig('response', 'headers', 'content-type').to_s,
        body_file: body_file.empty? ? nil : body_file,
        bytes: stat.size + attachment_size(body_file),
        error: nil
      )
    end

    def filter_records(records, filters)
      terms = filters['q'].to_s.downcase.split
      method = filters['method'].to_s.upcase
      prefix = filters['prefix'].to_s
      status = filters['status'].to_s
      query = filters['query'].to_s
      retention = filters['retention'].to_s

      records.select do |record|
        terms.all? { record.search_text.include?(_1) } &&
          (method.empty? || record.method == method) &&
          (prefix.empty? || record.prefix == prefix) &&
          status_matches?(record, status) &&
          query_matches?(record, query) &&
          (retention.empty? || record.retention == retention)
      end
    end

    def retention_definition(entry, method, query, path)
      stored = entry.dig('retention', 'definition').to_s
      return stored unless stored.empty?
      return unless @retention_matcher

      @retention_matcher.call(@retention_rules, method, query, path)&.fetch(:definition)
    end

    def available_retentions(records)
      configured = @retention_rules.map { _1[:definition].to_s }.reject(&:empty?)
      stored = records.filter_map(&:retention).uniq
      configured + (stored - configured).sort
    end

    def path_statistics(records)
      counts = Hash.new { |hash, path| hash[path] = { total: 0, without_query: 0, with_query: 0 } }
      records.each do |record|
        next if record.path.to_s.empty?

        count = counts[record.path]
        count[:total] += 1
        count[record.query.to_s.empty? ? :without_query : :with_query] += 1
      end

      counts.map do |path, count|
        PathStat.new(path:, **count)
      end.sort_by { [-_1.total, _1.path] }
    end

    def status_matches?(record, filter)
      return true if filter.empty?
      return record.invalid? if filter == 'invalid'
      return record.invalid? || record.status.to_i >= 400 if filter == 'errors'

      filter.match?(/\A[1-5]xx\z/) && record.status.to_i / 100 == filter.to_i
    end

    def query_matches?(record, filter)
      return true if filter.empty?
      return !record.query.to_s.empty? if filter == 'present'
      return record.query.to_s.empty? if filter == 'empty'

      false
    end

    def sort_records(records, sort)
      case sort
      when 'oldest'
        records.sort_by { [timestamp_number(_1), _1.filename] }
      when 'duration_desc'
        records.sort_by { [-(_1.duration_ms || -1), -timestamp_number(_1)] }
      when 'status_desc'
        records.sort_by { [-(_1.status || -1), -timestamp_number(_1)] }
      else
        records.sort_by { [-timestamp_number(_1), _1.filename] }
      end
    end

    def json_path(filename)
      raise NotFound, 'Invalid stored log name' unless SAFE_JSON_FILENAME.match?(filename.to_s)

      path = File.join(@directory, filename)
      raise NotFound, "Stored log was not found: #{filename}" unless File.file?(path)

      path
    end

    def attachment_size(filename)
      return 0 if filename.empty? || !SAFE_ATTACHMENT_FILENAME.match?(filename)

      File.size(File.join(@directory, filename))
    rescue Errno::ENOENT
      0
    end

    def parse_timestamp(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def timestamp_from_filename(filename)
      value = filename[/\A(\d{8}T\d{12})_/, 1]
      Time.strptime(value, '%Y%m%dT%H%M%S%6N').utc if value
    rescue ArgumentError
      nil
    end

    def timestamp_number(record) = record.timestamp&.to_f || 0
    def integer_or_nil(value) = Integer(value, exception: false)
    def float_or_nil(value) = Float(value, exception: false)

    def positive_integer(value, fallback)
      parsed = Integer(value, exception: false)
      parsed&.positive? ? parsed : fallback
    end

    def normalize_page_size(value)
      parsed = positive_integer(value, DEFAULT_PAGE_SIZE)
      PAGE_SIZES.include?(parsed) ? parsed : DEFAULT_PAGE_SIZE
    end
  end
end
