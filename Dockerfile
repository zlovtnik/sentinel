# =============================================================================
# Process Sentinel Dockerfile
# Multi-stage build with Zig and Oracle Instant Client
# Uses Oracle Linux for better Oracle client compatibility
# =============================================================================

# Stage 1: Builder - Use Oracle Linux which Oracle tests their clients against
FROM oraclelinux:8-slim AS builder

# Install build dependencies
RUN microdnf install -y \
    curl \
    tar \
    xz \
    ca-certificates \
    libaio \
    unzip \
    && microdnf clean all

# Install Zig 0.15.2 (stable release)
RUN curl -fsSL https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
    | tar -xJ -C /opt \
    && ln -s /opt/zig-x86_64-linux-0.15.2/zig /usr/local/bin/zig

# Install Oracle Instant Client 21c from Oracle Linux repos (optimized for OL)
RUN microdnf install -y oracle-instantclient-release-el8 && \
    microdnf install -y oracle-instantclient-basic && \
    microdnf clean all

ENV LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib
ENV ORACLE_HOME=/usr/lib/oracle/21/client64

# Copy source code
WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src ./src

# Clone ODPI-C (submodule not included in Docker COPY)
RUN mkdir -p deps && \
    curl -fsSL https://github.com/oracle/odpi/archive/refs/tags/v5.4.0.tar.gz \
    | tar -xz -C deps && \
    mv deps/odpi-5.4.0 deps/odpi

# Build the application
# Use baseline x86_64 CPU to avoid illegal instruction errors on cloud VMs
RUN ORACLE_HOME=/usr/lib/oracle/21/client64 ODPIC_PATH=deps/odpi \
    zig build -Doptimize=ReleaseSafe -Dcpu=x86_64

# =============================================================================
# Stage 2: Runtime - Use Oracle Linux for runtime too
FROM oraclelinux:8-slim AS runtime

# Install runtime dependencies
RUN microdnf install -y oracle-instantclient-release-el8 && \
    microdnf install -y oracle-instantclient-basic libaio && \
    microdnf clean all && \
    useradd -r -u 1000 sentinel

ENV LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib
ENV ORACLE_HOME=/usr/lib/oracle/21/client64

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
