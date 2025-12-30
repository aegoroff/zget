# zget

A non-interactive network retriever implemented in Zig, similar to `wget` or `curl`.

## Description

`zget` is a lightweight command-line tool for downloading files from the internet. It provides progress tracking, download speed monitoring, and flexible output options.

## Features

- Download files from HTTP/HTTPS URLs
- Custom HTTP headers support
- Progress tracking with percentage and bytes downloaded
- Download speed monitoring (MiB/sec)
- Flexible output path specification
- Cross-platform support (Linux, macOS, Windows)

## Installation

### Building from Source

Requires [Zig](https://ziglang.org/) 0.12.0 or later.

```bash
# Clone the repository
git clone <repository-url>
cd zget

# Build the project
zig build

# The executable will be in zig-out/bin/zget
```

### Cross-compilation

The project supports cross-compilation for multiple platforms:

```bash
# Build for specific target
zig build -Dtarget=x86_64-linux-musl
zig build -Dtarget=aarch64-macos-none
zig build -Dtarget=x86_64-windows-gnu
```

### Creating Release Archives

```bash
# Build and create a tar.gz archive
zig build archive
```

## Usage

### Basic Usage

```bash
# Download a file (saves to current directory with filename from URL)
zget https://example.com/file.zip

# Specify output file
zget -O output.zip https://example.com/file.zip

# Specify output directory (filename will be extracted from URL)
zget -O /path/to/directory https://example.com/file.zip
```

### Options

- `-H, --header <HEADER>`: Add custom HTTP header(s). Can be used multiple times.
  - Format: `Header-Name: Header-Value`
  - Example: `-H "Authorization: Bearer token123"`

- `-O, --output <PATH>`: Specify output path. If it's a directory, the filename will be extracted from the URI.

### Examples

```bash
# Download with custom headers
zget -H "User-Agent: MyApp/1.0" -H "Authorization: Bearer token" https://api.example.com/data.json

# Download to specific file
zget -O myfile.tar.gz https://example.com/release.tar.gz

# Download to directory
zget -O /tmp/downloads https://example.com/file.zip
```

## Output

`zget` provides detailed information during download:

- URI being downloaded
- Content type
- Content size (if available)
- Progress percentage
- Bytes downloaded
- Download speed (MiB/sec)
- Total time taken
- Final statistics

## Building and Testing

```bash
# Build the project
zig build

# Run unit tests
zig build test

# Run the application
zig build run -- <arguments>
```

## Dependencies

- [yazap](https://github.com/prajwalch/yazap): Command-line argument parsing library

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Copyright

Copyright (C) 2025 Alexander Egorov. All rights reserved.
