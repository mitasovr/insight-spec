# syntax=docker/dockerfile:1.7

# ---- Build stage ----
FROM rust:1.92-alpine AS builder

RUN apk add --no-cache musl-dev pkgconfig openssl-dev openssl-libs-static

WORKDIR /build

# Cache dependencies first. Build with --features io (the full binary needs ClickHouse I/O;
# rustc 1.89+ required — rust:1.92 image satisfies this).
COPY Cargo.toml Cargo.lock* ./
RUN mkdir -p src/core src/io \
    && echo "fn main() {}" > src/main.rs \
    && echo "pub mod types; pub mod jira;" > src/core/mod.rs \
    && echo "" > src/core/types.rs \
    && echo "" > src/core/jira.rs \
    && cargo build --release --features io 2>/dev/null || cargo build --release --features io

# Real sources.
COPY src ./src
RUN touch src/main.rs src/core/mod.rs src/core/types.rs src/core/jira.rs
RUN cargo build --release --features io

# ---- Runtime stage ----
FROM gcr.io/distroless/cc-debian12:nonroot AS runtime

COPY --from=builder /build/target/release/jira-enrich /usr/local/bin/jira-enrich

USER nonroot:nonroot
ENTRYPOINT ["/usr/local/bin/jira-enrich"]
