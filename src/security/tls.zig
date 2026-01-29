//! TLS Configuration
//! Provides mTLS configuration for secure connections.

const std = @import("std");

/// TLS configuration for server and client connections
pub const TlsConfig = struct {
    cert_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    ca_file: ?[]const u8 = null,
    verify_client: bool = false,
    min_version: TlsVersion = .tls_1_3,
    ciphers: ?[]const u8 = null,

    pub const TlsVersion = enum {
        tls_1_2,
        tls_1_3,

        pub fn toValue(self: TlsVersion) u16 {
            return switch (self) {
                .tls_1_2 => 0x0303,
                .tls_1_3 => 0x0304,
            };
        }
    };

    /// Load configuration from environment
    pub fn loadFromEnv() TlsConfig {
        return .{
            .cert_file = std.posix.getenv("TLS_CERT_FILE"),
            .key_file = std.posix.getenv("TLS_KEY_FILE"),
            .ca_file = std.posix.getenv("TLS_CA_FILE"),
            .verify_client = std.mem.eql(
                u8,
                std.posix.getenv("TLS_VERIFY_CLIENT") orelse "false",
                "true",
            ),
        };
    }

    /// Check if TLS is enabled
    pub fn isEnabled(self: TlsConfig) bool {
        return self.cert_file != null and self.key_file != null;
    }

    /// Validate TLS configuration
    pub fn validate(self: TlsConfig) !void {
        const cwd = std.fs.cwd();

        if (self.cert_file) |cert| {
            cwd.access(cert, .{}) catch {
                std.log.err("TLS cert file not found: {s}", .{cert});
                return error.CertFileNotFound;
            };
        }

        if (self.key_file) |key| {
            cwd.access(key, .{}) catch {
                std.log.err("TLS key file not found: {s}", .{key});
                return error.KeyFileNotFound;
            };
        }

        if (self.ca_file) |ca| {
            cwd.access(ca, .{}) catch {
                std.log.err("TLS CA file not found: {s}", .{ca});
                return error.CaFileNotFound;
            };
        }

        std.log.info("TLS configuration validated", .{});
    }
};

/// Certificate information
pub const CertInfo = struct {
    subject: []const u8,
    issuer: []const u8,
    serial: []const u8,
    not_before: i64,
    not_after: i64,
    fingerprint_sha256: [32]u8,

    /// Check if certificate is expired
    pub fn isExpired(self: CertInfo) bool {
        return std.time.timestamp() > self.not_after;
    }

    /// Check if certificate is not yet valid
    pub fn isNotYetValid(self: CertInfo) bool {
        return std.time.timestamp() < self.not_before;
    }

    /// Get days until expiration
    pub fn daysUntilExpiration(self: CertInfo) i64 {
        const remaining = self.not_after - std.time.timestamp();
        return @divFloor(remaining, 86400);
    }
};

/// mTLS client configuration
pub const MtlsClientConfig = struct {
    allocator: std.mem.Allocator,
    client_cert: []const u8,
    client_key: []const u8,
    ca_cert: []const u8,
    server_name: ?[]const u8 = null,
    skip_verify: bool = false,

    /// Load from Oracle Wallet-style files
    pub fn loadFromWallet(wallet_path: []const u8, allocator: std.mem.Allocator) !MtlsClientConfig {
        const client_cert_path = try std.fs.path.join(allocator, &.{ wallet_path, "client-cert.pem" });
        errdefer allocator.free(client_cert_path);

        const client_key_path = try std.fs.path.join(allocator, &.{ wallet_path, "client-key.pem" });
        errdefer allocator.free(client_key_path);

        const ca_cert_path = try std.fs.path.join(allocator, &.{ wallet_path, "ca-cert.pem" });
        errdefer allocator.free(ca_cert_path);

        return .{
            .allocator = allocator,
            .client_cert = client_cert_path,
            .client_key = client_key_path,
            .ca_cert = ca_cert_path,
        };
    }

    /// Clean up allocated paths.
    /// IMPORTANT: Only call this on instances created via `loadFromWallet`.
    /// Calling on directly-initialized instances causes undefined behavior.
    pub fn deinit(self: *MtlsClientConfig) void {
        self.allocator.free(self.client_cert);
        self.allocator.free(self.client_key);
        self.allocator.free(self.ca_cert);
    }
};
