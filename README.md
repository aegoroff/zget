# zget

A non-interactive network retriever implemented in [Zig](https://ziglang.org/) 0.16.0, similar to `wget` or `curl`.

## Description

`zget` is a lightweight command-line tool for downloading files over HTTP/HTTPS. It reports progress and speed, supports custom headers and proxies, follows redirects, decompresses gzip/deflate/zstd responses, and writes to a file, a directory, or stdout.

## Features

- HTTP/HTTPS downloads with automatic redirect following (default: 10 hops, configurable)
- Automatic decompression of gzip/deflate/zstd response bodies
- Custom HTTP headers (`-H`)
- Proxy support via environment variables (case-insensitive names)
- Progress display with bytes read and speed; percentage when `Content-Length` is known
- Flexible output: file path, existing directory, or stdout (`-O -`)
- Filename from URL path (percent-decoded), `Content-Disposition`, or `index.html` fallback
- Readable error messages on stderr
- `--version` / `-V`
- `--timeout` — connection and read timeout in seconds
- `--no-check-certificate` — skip TLS certificate chain verification (direct HTTPS only)
- `-q` / `--quiet` — suppress progress, summary, and warnings (errors still print on failure)
- `--checksum=sha256` / `--checksum=blake3` — print digest after transfer (ignored with `-q`)
- Default `User-Agent: zget/<version>` header
- Cross-platform builds (Linux, macOS, Windows)

## Installation

### Building from Source

Requires [Zig](https://ziglang.org/) **0.16.0** (see `mise.toml`). [mise](https://mise.jdx.dev/) is the easiest way to install the pinned version:

```bash
# Clone the repository
git clone https://github.com/aegoroff/zget.git
cd zget

# Install Zig 0.16.0 via mise (optional)
mise install

# Build
zig build

# Binary: zig-out/bin/zget
```

With [just](https://github.com/casey/just):

```bash
just build    # ReleaseFast, x86_64-linux-musl
just test
```

With mise (used in CI):

```bash
mise run build:zig
```

### Cross-compilation

```bash
zig build -Dtarget=x86_64-linux-musl
zig build -Dtarget=aarch64-macos-none
zig build -Dtarget=x86_64-windows-gnu
```

### Release Archives

```bash
zig build archive -Dversion=0.2.0
```

Produces `zig-out/zget-<version>-<arch>-<os>-<abi>.tar.gz`.

Pre-built archives are attached to [GitHub releases](https://github.com/aegoroff/zget/releases).

## Usage

### Basic Usage

```bash
# Show version
zget --version
zget -V

# Download to current directory (filename from URL)
zget https://example.com/file.zip

# Download a site root as index.html
zget https://example.com/

# Write to a specific file
zget -O output.zip https://example.com/file.zip

# Write into an existing directory (filename from URL)
zget -O /path/to/directory https://example.com/file.zip

# Write body to stdout (progress and summary go to stderr)
zget -O - https://example.com/file.zip
```

### Options

| Option | Description |
|--------|-------------|
| `-H, --header <HEADER>` | Add a custom HTTP header. Repeatable. Format: `Name: Value` |
| `-O, --output <PATH>` | Output path. Existing directory appends the URL filename; `-` writes to stdout |
| `--no-proxy` | Ignore proxy environment variables |
| `--proxy-user <USER>` | Username for proxy authentication |
| `--proxy-password <PASS>` | Password for proxy authentication |
| `-V, --version` | Print version information and exit |
| `--timeout <SECONDS>` | Connection and read timeout in seconds |
| `--max-redirect <COUNT>` | Maximum number of HTTP redirects to follow (default: 10) |
| `--no-check-certificate` | Don't verify the peer's TLS certificate chain (direct HTTPS only) |
| `-q, --quiet` | Quiet (no progress, summary, or warnings) |
| `--checksum <TYPE>` | Print checksum after download (`sha256`, `blake3`; ignored with `-q`) |
| `-h, --help` | Print help and exit |

Positional argument: `URI` — the URL to download (`http://` or `https://` only).

### Proxy Configuration

Proxies are read from the environment (unless `--no-proxy` is set). Variable names are matched case-insensitively (`http_proxy`, `HTTP_PROXY`, etc.):

| Variable | Purpose |
|----------|---------|
| `http_proxy` | Proxy for `http://` requests |
| `https_proxy` | Proxy for `https://` requests; falls back to `http_proxy` when unset |
| `no_proxy` | Comma-separated host patterns to bypass the proxy |

CLI credentials override embedded credentials in the proxy URL:

```bash
export http_proxy=http://proxy.example:8080
export no_proxy=localhost,127.0.0.1,.example.com
zget --proxy-user alice --proxy-password secret https://example.com/file.zip
```

### Examples

```bash
# Custom headers
zget -H "User-Agent: MyApp/1.0" -H "Authorization: Bearer token" \
  https://api.example.com/data.json

# Named output file
zget -O myfile.tar.gz https://example.com/release.tar.gz

# Pipe to another command
zget -O - https://example.com/data.json | jq .
```

## Output

During a download, `zget` prints:

- Request URI
- Content type
- Content size (when the server sends `Content-Length`)
- Live progress: percentage when size is known, otherwise bytes read and speed
- Final summary: elapsed time, total bytes, average speed

When writing to stdout (`-O -`), the response body goes to stdout and status lines go to stderr.

On failure, a short message is printed to stderr, for example:

```text
error: Unsupported URI scheme (only http and https are supported)
```

## Building and Testing

```bash
zig build
zig build test
zig build run -- -O out.zip https://example.com/file.zip
```

## Dependencies

- [yazap](https://github.com/prajwalch/yazap) 0.7.0 — CLI argument parsing

## License

MIT License — see [LICENSE.txt](LICENSE.txt).

## Copyright

Copyright (C) 2025–2026 Alexander Egorov. All rights reserved.
