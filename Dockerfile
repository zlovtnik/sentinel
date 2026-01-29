# =============================================================================
# Process Sentinel Dockerfile
# Multi-stage build with Zig and Oracle Instant Client
# =============================================================================

# Stage 1: Builder
FROM debian:bookworm-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    curl \
    xz-utils \
    ca-certificates \
    libaio1 \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.2 (stable release)
RUN curl -fsSL https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
    | tar -xJ -C /opt \
    && ln -s /opt/zig-x86_64-linux-0.15.2/zig /usr/local/bin/zig

# Install Oracle Instant Client
RUN mkdir -p /opt/oracle && \
    curl -fsSL https://download.oracle.com/otn_software/linux/instantclient/2326100/instantclient-basic-linux.x64-23.26.1.0.0.zip \
    -o /tmp/instantclient.zip && \
    apt-get update && apt-get install -y unzip && \
    unzip -q /tmp/instantclient.zip -d /opt/oracle && \
    rm /tmp/instantclient.zip && \
    mv /opt/oracle/instantclient_* /opt/oracle/instantclient && \
    echo /opt/oracle/instantclient > /etc/ld.so.conf.d/oracle-instantclient.conf && \
    ldconfig

ENV LD_LIBRARY_PATH=/opt/oracle/instantclient
ENV ORACLE_HOME=/opt/oracle/instantclient

# Copy source code
WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src ./src

# Clone ODPI-C (submodule not included in Docker COPY)
RUN mkdir -p deps && \
    curl -fsSL https://github.com/oracle/odpi/archive/refs/tags/v5.4.0.tar.gz \
    | tar -xz -C deps && \
    mv deps/odpi-5.4.0 deps/odpi

# Build the application using environment variables (not -D flags)
# build.zig reads ORACLE_HOME and ODPIC_PATH from environment
# Use baseline x86_64 CPU to avoid illegal instruction errors on cloud VMs
RUN ORACLE_HOME=/opt/oracle/instantclient ODPIC_PATH=deps/odpi \
    zig build -Doptimize=ReleaseSafe -Dcpu=x86_64

# =============================================================================
# Stage 2: Runtime
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libaio1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 1000 sentinel

# Copy Oracle Instant Client from builder
COPY --from=builder /opt/oracle/instantclient /opt/oracle/instantclient

ENV LD_LIBRARY_PATH=/opt/oracle/instantclient
ENV ORACLE_HOME=/opt/oracle/instantclient

# Copy binary from builder
COPY --from=builder /app/zig-out/bin/process-sentinel /usr/local/bin/process-sentinel

# Create directories for wallet and logs
RUN mkdir -p /opt/sentinel/wallet /opt/sentinel/logs \
    && chown -R sentinel:sentinel /opt/sentinel

# Security: Non-root user
USER sentinel
WORKDIR /opt/sentinel

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Default environment
ENV SENTINEL_LISTEN_ADDRESS=0.0.0.0
ENV SENTINEL_LISTEN_PORT=8080
ENV SENTINEL_LOG_LEVEL=info

# Expose ports
EXPOSE 8080

# Entry point
ENTRYPOINT ["/usr/local/bin/process-sentinel"]
