# Rest Gate

Rest Gate is a lightweight HTTP reverse proxy for development and diagnostic environments. It forwards requests to one or more upstream services and can persist selected request/response pairs as JSON for later investigation.

The service is useful when an existing application must continue working normally while a controlled subset of its traffic is recorded. Requests that are not selected for storage are still proxied.

## Contents

- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Proxy mapping](#proxy-mapping)
- [Request and response logging](#request-and-response-logging)
- [Stored log inspector](#stored-log-inspector)
- [Paths behind Traefik](#paths-behind-traefik-or-another-reverse-proxy)
- [Header behavior](#header-behavior)
- [Stored object format](#stored-object-format)
- [Health and diagnostics](#health-and-diagnostics)
- [Development](#development)
- [Security and operational considerations](#security-and-operational-considerations)

## Features

- Routes requests to upstream services by path prefix.
- Removes a configured public prefix and optionally prepends an upstream base path.
- Preserves query strings, request bodies, response bodies, status codes, and end-to-end headers.
- Supports `GET`, `POST`, `PUT`, `DELETE`, `HEAD`, and `PATCH`.
- Uses persistent upstream HTTP connections with retry and timeout settings.
- Stores request/response metadata and textual bodies in JSON files.
- Stores binary response bodies in sidecar files.
- Supports time-based retention for all traffic or count-based retention for selected traffic.
- Provides a read-only, searchable web interface for stored traffic at `/_restgate`.
- Exposes `/healthcheck` through `stack-service-base`.

## Request flow

For every proxied request, Rest Gate:

1. Selects the longest matching prefix from `PROXY_MAP`.
2. Removes that prefix from the incoming path.
3. Prepends the upstream base path, if one is configured.
4. Forwards the method, query string, body, and end-to-end headers.
5. Returns the upstream status, headers, and body to the caller.
6. Stores the request/response pair when the active retention mode requires it.

Rest Gate buffers request and response bodies in memory. It is intended primarily for development and diagnostics rather than high-volume streaming traffic.

## Quick start

### Requirements

- Ruby 3.4.4, or Docker with Docker Compose.
- Network access from Rest Gate to the configured upstream service.

### Run locally

```bash
cd src
bundle install
PROXY_MAP='/:http://localhost:8080' \
REQUEST_RESPONSE_LOG_DIR='./log/request_responses' \
bundle exec rackup -o 0.0.0.0 -p 7000 -s falcon
```

Verify the service:

```bash
curl http://localhost:7000/healthcheck
curl http://localhost:7000/api/example
```

### Run with Docker Compose

The repository includes a build configuration in `docker/docker-compose.yml`:

```bash
docker compose \
  --env-file docker/.env \
  -f docker/docker-compose.yml \
  up --build
```

The container listens on port `7000`. A practical Compose service configuration looks like this:

```yaml
services:
  rest_gate:
    build:
      context: ./src
      dockerfile: ../docker/ruby/Dockerfile
    ports:
      - "7000:7000"
    environment:
      PROXY_MAP: "/:http://aeromap:8080"
      RETENTION: '100:{ALL}+{QUERY:.*}+{URL:\A/api/AeroData/search\z}'
      REQUEST_RESPONSE_LOG_DIR: "/app/log/request_responses"
    volumes:
      - ./request_responses:/app/log/request_responses
```

The upstream hostname must be resolvable inside the container network.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `PROXY_MAP` | `/api:http://example.ru/base/path/api` | Comma-separated mapping of incoming path prefixes to upstream targets. |
| `REQUEST_RESPONSE_LOG_DIR` | `src/log/request_responses` locally; `/app/log/request_responses` in the image | Directory used for JSON records and binary response sidecars. Created at startup. |
| `REQUEST_RESPONSE_LOG_BODY_LIMIT` | `0` | Maximum number of bytes stored for a textual body. `0` or a negative value means unlimited. |
| `REQUEST_RESPONSE_LOG_TTL_SECONDS` | `3600` | Maximum file age in time-based mode. `0` or a negative value disables expiry. |
| `REQUEST_RESPONSE_LOG_CLEANUP_INTERVAL_SECONDS` | `300` | Minimum interval between directory scans in time-based mode. |
| `RETENTION` | empty | Count-based retention rules. When set, it also acts as the storage allowlist. |
| `RESTGATE_UI_ENABLED` | `true` | Enables the stored-log inspector at `/_restgate`. When disabled, its implementation and index are not loaded. |
| `RESTGATE_UI_USERNAME` | empty | Optional HTTP Basic username for the inspector and its downloads. Configure together with the password. |
| `RESTGATE_UI_PASSWORD` | empty | Optional HTTP Basic password for the inspector and its downloads. Configure together with the username. |
| `RESTGATE_UI_BODY_PREVIEW_BYTES` | `200000` | Maximum request or response body bytes rendered on a detail page. `0` or a negative value means unlimited. |
| `PORT` | `7000` in the Docker image | Listening port used by the image command. |

Invalid `PROXY_MAP` entries, malformed `RETENTION` rules, invalid retention regular expressions, and an incomplete UI username/password pair while the UI is enabled cause startup to fail with an explanatory error.

## Proxy mapping

### Syntax

```text
PROXY_MAP="/incoming-prefix:upstream,/another-prefix:upstream"
```

An upstream can use either format:

```text
host[:port]
http[s]://host[:port][/base/path]
```

When the scheme is omitted, Rest Gate uses HTTP and port `80` by default.

### Examples

Preserve the complete path:

```text
PROXY_MAP=/:http://aeromap:8080
```

```text
/api/select -> http://aeromap:8080/api/select
```

Remove a public prefix:

```text
PROXY_MAP=/my/prefix:http://aeromap:8080
```

```text
/my/prefix/api/select -> http://aeromap:8080/api/select
```

Remove a public prefix and add an upstream base path:

```text
PROXY_MAP=/gateway:https://api.example.test/base
```

```text
/gateway/items?id=1 -> https://api.example.test/base/items?id=1
```

Route multiple prefixes:

```text
PROXY_MAP=/my/prefix:http://arinc:8080,/my/prefix2:http://arinc2:8080
```

The longest matching prefix wins. Prefix matching is textual rather than segment-aware, so `/api` also matches `/api-v2`; choose prefixes carefully when their names overlap.

## Request and response logging

Rest Gate has two retention modes.

### Time-based mode

Time-based mode is active when `RETENTION` is empty.

- Every proxied request is stored.
- Files older than `REQUEST_RESPONSE_LOG_TTL_SECONDS` are removed.
- Cleanup runs as part of request processing, not as a background job.
- Directory scans are throttled by `REQUEST_RESPONSE_LOG_CLEANUP_INTERVAL_SECONDS`.

Use a dedicated log directory because time-based cleanup removes any regular file in that directory once it is older than the configured TTL.

Example with five-minute retention:

```yaml
environment:
  RETENTION: ""
  REQUEST_RESPONSE_LOG_TTL_SECONDS: "300"
  REQUEST_RESPONSE_LOG_CLEANUP_INTERVAL_SECONDS: "30"
```

### Count-based selective mode

Count-based mode is active when `RETENTION` contains one or more rules.

- Only requests matching a rule are stored.
- Unmatched requests are still forwarded without being stored.
- Every rule has an independent object limit.
- When a rule exceeds its limit, its oldest stored object is removed.
- A JSON record and its binary response sidecar count as one stored object and are removed together.
- Every new JSON record stores the exact winning retention rule and its count limit for later inspection.
- Time-based cleanup is not used for matched records in this mode.

### `RETENTION` syntax

```text
N:{METHODS}+{QUERY:regexp}+{URL:regexp}
```

Multiple rules are separated by commas:

```text
10:{ALL}+{QUERY:.*}+{URL:.*},20:{GET,POST}+{QUERY:.*}+{URL:\A/api/.*}
```

Fields:

| Field | Meaning |
| --- | --- |
| `N` | Positive number of stored objects retained for this rule. |
| `METHODS` | `ALL` or a comma-separated list such as `GET,POST`. |
| `QUERY` | Ruby regular expression matched against the raw query string without the leading `?`. It is an empty string when no query is present. |
| `URL` | Ruby regular expression matched against the incoming `request.path_info`. |

When several rules match, the last matching rule takes precedence. Put general rules first and more specific rules later.

Store up to ten objects for `/api/select` and any subpath, regardless of method or query:

```text
10:{ALL}+{QUERY:.*}+{URL:\A/api/select(?:/.*)?\z}
```

Use different limits for general traffic and requests containing both query parameters in any order:

```text
10:{ALL}+{QUERY:.*}+{URL:\A/api/select(?:/.*)?\z},30:{ALL}+{QUERY:(?=.*(?:\A|&)SectionCode=E(?:&|\z))(?=.*(?:\A|&)SubsectionCode=R(?:&|\z)).*}+{URL:\A/api/select(?:/.*)?\z}
```

Regular expressions operate on the raw query string. Values may still be percent-encoded, and parameter order is significant unless the expression explicitly handles different orders, for example with lookaheads as shown above.

## Stored log inspector

Open `http://<rest-gate-host>:<port>/_restgate` to inspect the files in `REQUEST_RESPONSE_LOG_DIR`. The interface is read-only: it does not delete records, replay requests, or change retention state.

The list page provides:

- free-text search across method, path, raw query, status, upstream, proxy prefix, retention rule, content type, and filename;
- method, proxy-prefix, status-family, query-presence, and exact retention-rule filters, with the current stored size shown for every retention bucket;
- per-path statistics for the complete filtered subset, including total, no-query, and with-query counts;
- newest, oldest, slowest, and highest-status sorting;
- selectable pagination, a manual refresh action, and optional 15-second auto-refresh;
- total record, storage-size, and error summaries;
- a usable responsive view for both desktop and smaller screens.

All filters use AND semantics and path statistics are calculated before pagination, so the statistics and record list always describe the same selected subset. Search terms are case-insensitive and are also combined with AND semantics. For example, `POST SectionCode=E aeromap` only shows records whose indexed metadata contains all three terms. The inspector caches parsed summaries and refreshes only added, changed, or removed files. Proxy requests do not scan the log directory merely because the UI is enabled.

Records written by this version retain their original winning rule even if `RETENTION` later changes. For older JSON files without retention metadata, the inspector attributes a rule using the current `RETENTION` configuration when one matches.

Opening a record shows the incoming and upstream paths, decoded query parameters, headers, request and response bodies, status, duration, proxy metadata, and attributed retention rule. JSON bodies are formatted for reading. Large text bodies are previewed according to `RESTGATE_UI_BODY_PREVIEW_BYTES`; the original stored JSON remains available as a download. Binary response sidecars can be opened from the same detail page.

Sensitive request and response headers are hidden by default in rendered pages. The user may explicitly reveal them. Raw JSON downloads are exact stored files and are therefore never redacted.

### Protecting access

Configure both credentials to enable HTTP Basic authentication for every inspector page, asset, raw download, and binary body:

```yaml
environment:
  RESTGATE_UI_ENABLED: "true"
  RESTGATE_UI_USERNAME: "restgate"
  RESTGATE_UI_PASSWORD: "use-a-secret-from-your-deployment-system"
  RESTGATE_UI_BODY_PREVIEW_BYTES: "200000"
```

If only one credential is supplied, Rest Gate refuses to start instead of silently exposing an unprotected page. Disable the complete interface with `RESTGATE_UI_ENABLED=false` when it is not required. In that mode, `restgate_ui.rb` and `log_inspector.rb` are not required, no file index is created, and the reserved `/_restgate` prefix returns `404` instead of falling through to an upstream proxy.

For inspector requests, the Basic `Authorization` header is withheld from the shared Stack Service Base header logger. This safeguard is limited to the reserved UI prefix and does not change header forwarding or logging for proxied application requests.

The application reserves `/_restgate` and all of its subpaths before the wildcard proxy route, so inspector requests are neither forwarded upstream nor stored as captured traffic. Traefik must still route that prefix to the Rest Gate container. If the existing router only selects application API prefixes, add a dedicated higher-priority router whose rule is equivalent to:

```text
Host(`rest.example.test`) && PathPrefix(`/_restgate`)
```

No path-replacement middleware is needed for this route. If the host's existing router already sends every path to Rest Gate, no additional ingress rule is necessary.

### Escaping rules in configuration files

Shell single quotes and YAML single-quoted scalars preserve regex backslashes:

```bash
RETENTION='100:{ALL}+{QUERY:.*}+{URL:\A/api/select\z}'
```

```yaml
RETENTION: '100:{ALL}+{QUERY:.*}+{URL:\A/api/select\z}'
```

Dry Stack `.drs` files are Ruby. Inside a Ruby double-quoted value, escape every regex backslash:

```ruby
env RETENTION: "100:{ALL}+{QUERY:.*}+{URL:\\A/api/select\\z}"
```

Without the doubled backslashes, Ruby turns `\A` and `\z` into `A` and `z` before Dry Stack generates Compose YAML.

## Paths behind Traefik or another reverse proxy

`RETENTION` matches the path that Rest Gate actually receives. If Traefik applies `ReplacePathRegex` before forwarding to Rest Gate, retention rules must use the rewritten path.

Path rewriting can therefore be owned by either layer:

- Prefer Traefik when routing and path replacement are already centralized there.
- Use a non-root `PROXY_MAP` prefix when Rest Gate itself should remove the public prefix.
- Avoid applying the same prefix replacement in both places.

Example:

```text
Client path:          /ani1/api/AeroData/search
Traefik replacement: /api/AeroData/search
Rest Gate receives:  /api/AeroData/search
PROXY_MAP:            /:http://aeromap:8080
RETENTION URL regex:  \A/api/AeroData/search\z
```

## Header behavior

End-to-end request headers are forwarded for all supported methods, including:

- `Authorization`
- `Cookie`
- `Accept`
- `Content-Type`
- `Forwarded` and `X-Forwarded-*`
- tracing and application-specific headers

Transport-managed request headers are intentionally not copied unchanged:

| Header | Behavior |
| --- | --- |
| `Host` | Generated from the upstream target. Use `X-Forwarded-Host` for the original public host. |
| `Content-Length` | Recalculated by the HTTP client from the forwarded body. |
| `Connection`, `Proxy-Connection` | Not forwarded. |
| `Accept-Encoding` | Set to `identity` to avoid compressed-response inconsistencies. |

For responses, connection/framing headers are regenerated by the server rather than copied directly.

## Stored object format

JSON filenames contain a UTC timestamp and a UUID:

```text
20260811T104501123456_52a0dc58-84bf-42a2-bac8-e07ba782f884.json
```

Each file has this structure:

```json
{
  "request": {
    "method": "GET",
    "path": "/api/select",
    "target_path": "/api/select?SectionCode=E",
    "query_string": "SectionCode=E",
    "headers": {
      "Authorization": "Bearer ...",
      "Accept-Encoding": "identity"
    },
    "body": null,
    "ip": "192.0.2.10"
  },
  "response": {
    "status": 200,
    "headers": {
      "content-type": "application/json"
    },
    "body": "{\"result\":[]}"
  },
  "proxy": {
    "prefix": "/",
    "upstream": "http://aeromap:8080"
  },
  "timing": {
    "duration_ms": 12.345
  },
  "timestamp": "2026-08-11T10:45:01Z"
}
```

Text bodies larger than `REQUEST_RESPONSE_LOG_BODY_LIMIT` are truncated when the limit is positive. Binary request bodies are represented by an omission placeholder in JSON. Binary response bodies are written to a sibling file and referenced through `response.body_file`.

Recognized binary content types include octet streams, protobuf, images, video, audio, fonts, PDFs, and ZIP data.

## Upstream HTTP behavior

Each upstream receives a persistent Faraday connection configured with:

- request timeout: 15 seconds;
- connection timeout: 10 seconds;
- up to 2 retries with exponential backoff where Faraday's retry policy allows it;
- connection pool size: 10;
- persistent-connection idle timeout: 60 seconds.

There is no response cache or fallback upstream. An upstream connection failure is returned through the application's normal error handling.

## Health and diagnostics

```bash
curl http://localhost:7000/healthcheck
```

Expected response:

```json
{
  "Status": "Healthy"
}
```

For a proxy smoke test, call a known upstream endpoint through Rest Gate and confirm:

1. The status and body match a direct upstream request.
2. Authentication, cookies, and forwarding headers reach the upstream.
3. A JSON record appears only when the active retention mode selects the request.
4. The record contains the expected incoming path and generated upstream target path.

## Development

Install dependencies and run the complete test suite:

```bash
cd src
bundle install
bundle exec rspec
```

Alternative Rake commands:

```bash
bundle exec rake test
bundle exec rake coverage
```

Check Ruby syntax:

```bash
ruby -c config.ru
```

Run the service locally in the same mode used by a normal RubyMine launch:

```bash
bundle exec rackup -o 127.0.0.1 -p 9292 config.ru
```

Rest Gate sets `NO_RT_DEBUG=true` before loading Stack Service Base. This disables that gem's automatic Chrome debug server, whose `SocketTrace` wrapper in version `0.0.104` is incompatible with the `Addrinfo` passed by the Ruby 3.3 debugger. It does not disable RubyMine's debugger: Shift+F9 still supplies and controls `ruby-debug-ide` independently.

## Repository layout

```text
.
├── docker/
│   ├── docker-compose.yml
│   └── ruby/Dockerfile
├── src/
│   ├── config.ru
│   ├── log_inspector.rb
│   ├── restgate_ui.rb
│   ├── public/
│   ├── Gemfile
│   ├── spec/
│   └── views/
└── README.md
```

`src/config.ru` contains the proxy, retention, and persistence implementation. It conditionally loads `src/restgate_ui.rb`, which owns all inspector configuration, middleware, routes, and rendering helpers. `src/log_inspector.rb` owns the cached file index and search behavior. Request-level behavior is covered primarily by `src/spec/integration/request_response_logging_spec.rb` and `src/spec/integration/log_inspector_spec.rb`.

## Security and operational considerations

- Stored JSON includes request and response headers and may therefore contain authorization tokens, cookies, personal data, or other secrets.
- Stored files are not redacted. The inspector hides common credential headers in rendered pages by default, but explicitly revealed views and raw downloads contain their original values.
- Protect `/_restgate` with `RESTGATE_UI_USERNAME` and `RESTGATE_UI_PASSWORD` and with the deployment network's normal access controls before exposing it outside a trusted development environment.
- Restrict access to the log directory and use a dedicated persistent volume when records must survive container replacement.
- Define narrow `RETENTION` URL rules so unrelated endpoints are forwarded without being recorded.
- Use `REQUEST_RESPONSE_LOG_BODY_LIMIT` to prevent unexpectedly large textual log files.
- Monitor disk usage; count-based retention is enforced per rule rather than as a global directory limit.
- Keep count limits appropriate for a development service; enforcing a matched rule scans existing JSON records in the log directory.
- Do not expose the log directory through a public web server.

Rest Gate is best suited to controlled development and diagnostic environments. Production use should additionally consider redaction, access control, disk quotas, request-size limits, and streaming behavior.
