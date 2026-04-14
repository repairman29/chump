# Chump Web — multi-stage build for the PWA web server.
# Usage: docker build -t chump-web -f docker/Dockerfile .
# Note: run from repo root so Cargo.toml, src/, web/ are in context.

FROM rust:1.82-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY chump-tool-macro/ chump-tool-macro/
# Desktop/Tauri crate is in the workspace but not needed for the web server.
# Copy a stub so cargo resolves the workspace without Tauri dependencies.
RUN mkdir -p desktop/src-tauri/src && \
    echo '[package]\nname = "chump-desktop"\nversion = "0.1.0"\nedition = "2021"\n' > desktop/src-tauri/Cargo.toml && \
    echo 'fn main() {}' > desktop/src-tauri/src/main.rs && \
    echo 'fn main() {}' > desktop/src-tauri/build.rs
COPY src/ src/
# Build release binary (no optional features — just the web server).
RUN cargo build --release --bin chump

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git sqlite3 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/target/release/chump /usr/local/bin/chump
COPY web/ /app/web/
WORKDIR /app
RUN mkdir -p /app/sessions /app/logs /app/data
ENV CHUMP_HOME=/app \
    CHUMP_WEB_STATIC_DIR=/app/web \
    CHUMP_WEB_PORT=3000
EXPOSE 3000
ENTRYPOINT ["chump", "--web", "--port", "3000"]
