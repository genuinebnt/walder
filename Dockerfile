# Use the official Rust image as the build environment
FROM rust:1.82-bookworm AS builder

# Install system dependencies
RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /usr/src/wallsetter

# Copy the entire workspace
COPY . .

# Build only the CLI tool in release mode
RUN cargo build --release -p wallsetter-cli

# Use a minimal runtime image
FROM debian:bookworm-slim

# Install runtime dependencies (like CA certificates for HTTPS requests)
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Copy the compiled CLI binary from the builder stage
COPY --from=builder /usr/src/wallsetter/target/release/wallsetter-cli /usr/local/bin/wallsetter-cli

# Create a volume for storing downloaded wallpapers
VOLUME ["/wallpapers"]

# Set the default executable
ENTRYPOINT ["wallsetter-cli"]

# Default command (can be overridden)
CMD ["--help"]
