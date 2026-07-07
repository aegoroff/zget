# zget

A non-interactive network retriever implemented in [Zig](https://ziglang.org/) 0.16.0, similar to `wget` or `curl`.

## Description

`zget` is a lightweight command-line tool for downloading files over HTTP/HTTPS. It reports progress and speed, supports custom headers and proxies, follows redirects, and writes to a file, a directory, or stdout.

## Features

- HTTP/HTTPS downloads with automatic redirect following (up to 10 hops)
- Custom HTTP headers (`-H`)
- Proxy support via environment variables
- Progress bar with percentage, bytes read, and speed (MiB/sec)
- Flexible output: file path, directory, or stdout (`-O -`)
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
# Download to current directory (filename from URL)
zget https://example.com/file.zip

# Write to a specific file
zget -O output.zip https://example.com/file.zip

# Write into a directory (filename from URL)
zget -O /path/to/directory https://example.com/file.zip

# Write body to stdout (progress and summary go to stderr)
zget -O - https://example.com/file.zip
```

### Options

| Option | Description |
|--------|-------------|
| `-H, --header <HEADER>` | Add a custom HTTP header. Repeatable. Format: `Name: Value` |
| `-O, --output <PATH>` | Output path. Directory appends the URL filename; `-` writes to stdout |
| `--no-proxy` | Ignore `http_proxy` / `https_proxy` environment variables |
| `--proxy-user <USER>` | Username for proxy authentication |
| `--proxy-password <PASS>` | Password for proxy authentication |

Positional argument: `URI` — the URL to download.

### Proxy Configuration

Proxies are read from the environment (unless `--no-proxy` is set):

| Variable | Purpose |
|----------|---------|
| `http_proxy` | Proxy for `http://` requests |
| `https_proxy` | Proxy for `https://` requests |
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
- Live progress (percentage, bytes read, speed)
- Final summary: elapsed time, total bytes, average speed

When writing to stdout (`-O -`), the response body goes to stdout and status lines go to stderr.

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
