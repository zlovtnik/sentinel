//! Oracle Wallet Configuration
//! Handles Oracle Wallet-based mTLS authentication for secure database connections.

const std = @import("std");

/// Oracle Wallet configuration for secure database connections
pub const WalletConfig = struct {
    wallet_location: []const u8, // $ORACLE_WALLET_LOCATION
    tns_name: []const u8, // $ORACLE_TNS_NAME
    ssl_server_dn_match: bool = true,
    ssl_server_cert_dn: ?[]const u8 = null,

    /// Build the Oracle connection descriptor string
    /// Format matches CLM Service tnsnames.ora format for consistency
    pub fn getConnectionDescriptor(
        self: WalletConfig,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        // For wallet-based connections, we typically use the TNS alias
        // The actual connection string is resolved from tnsnames.ora
        // pointed to by TNS_ADMIN environment variable
        return try std.fmt.allocPrint(allocator, "{s}", .{self.tns_name});
    }

    /// Build a full Easy Connect Plus descriptor with wallet
    /// Use this when tnsnames.ora is not available
    pub fn getFullDescriptor(
        self: WalletConfig,
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        service_name: []const u8,
    ) ![]const u8 {
        const ssl_match = if (self.ssl_server_dn_match) "yes" else "no";

        if (self.ssl_server_cert_dn) |dn| {
            return try std.fmt.allocPrint(allocator,
                \\(description=
                \\  (retry_count=20)(retry_delay=3)
                \\  (address=(protocol=tcps)(port={d})(host={s}))
                \\  (connect_data=(service_name={s}))
                \\  (security=
                \\    (ssl_server_dn_match={s})
                \\    (ssl_server_cert_dn="{s}")
                \\    (wallet_location=(source=(method=file)(method_data=(directory={s}))))
                \\  )
                \\)
            , .{
                port,
                host,
                service_name,
                ssl_match,
                dn,
                self.wallet_location,
            });
        }

        return try std.fmt.allocPrint(allocator,
            \\(description=
            \\  (retry_count=20)(retry_delay=3)
            \\  (address=(protocol=tcps)(port={d})(host={s}))
            \\  (connect_data=(service_name={s}))
            \\  (security=
            \\    (ssl_server_dn_match={s})
            \\    (wallet_location=(source=(method=file)(method_data=(directory={s}))))
            \\  )
            \\)
        , .{
            port,
            host,
            service_name,
            ssl_match,
            self.wallet_location,
        });
    }

    /// Validate wallet files exist
    pub fn validate(self: WalletConfig, allocator: std.mem.Allocator) !void {
        // Check for cwallet.sso (auto-login wallet)
        const sso_path = try std.fs.path.join(
            allocator,
            &.{ self.wallet_location, "cwallet.sso" },
        );
        defer allocator.free(sso_path);

        std.fs.accessAbsolute(sso_path, .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    std.log.err("Oracle Wallet SSO file not found: {s}", .{sso_path});
                    return error.WalletNotFound;
                },
                error.AccessDenied => {
                    std.log.err("Access denied to Oracle Wallet: {s}", .{sso_path});
                    return error.AccessDenied;
                },
                else => {
                    std.log.err("Failed to access Oracle Wallet {s}: {}", .{ sso_path, err });
                    return err;
                },
            }
        };

        std.log.info("Oracle Wallet validated at: {s}", .{self.wallet_location});
    }
};

/// Environment-based wallet configuration loader
pub fn loadFromEnv() !WalletConfig {
    const wallet_location = std.posix.getenv("ORACLE_WALLET_LOCATION") orelse {
        std.log.err("ORACLE_WALLET_LOCATION environment variable not set", .{});
        return error.MissingEnvironmentVariable;
    };

    const tns_name = std.posix.getenv("ORACLE_TNS_NAME") orelse {
        std.log.err("ORACLE_TNS_NAME environment variable not set", .{});
        return error.MissingEnvironmentVariable;
    };

    const ssl_match_str = std.posix.getenv("ORACLE_SSL_SERVER_DN_MATCH") orelse "yes";

    // Case-insensitive check for truthy/falsy values with warning for unrecognized
    const ssl_server_dn_match = blk: {
        if (ssl_match_str.len == 0) break :blk true; // Default to true

        // Convert to lowercase for comparison
        var lower_buf: [16]u8 = undefined;
        const len = @min(ssl_match_str.len, lower_buf.len);
        for (ssl_match_str[0..len], 0..) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }
        const lower = lower_buf[0..len];

        // Check for common truthy values
        if (std.mem.eql(u8, lower, "yes") or
            std.mem.eql(u8, lower, "true") or
            std.mem.eql(u8, lower, "1") or
            std.mem.eql(u8, lower, "on"))
        {
            break :blk true;
        }

        // Check for common falsy values
        if (std.mem.eql(u8, lower, "no") or
            std.mem.eql(u8, lower, "false") or
            std.mem.eql(u8, lower, "0") or
            std.mem.eql(u8, lower, "off"))
        {
            break :blk false;
        }

        // Unrecognized value - warn and default to true for security
        std.log.warn(
            "ORACLE_SSL_SERVER_DN_MATCH has unrecognized value '{s}'; defaulting to enabled",
            .{ssl_match_str},
        );
        break :blk true;
    };

    return .{
        .wallet_location = wallet_location,
        .tns_name = tns_name,
        .ssl_server_dn_match = ssl_server_dn_match,
        .ssl_server_cert_dn = std.posix.getenv("ORACLE_SSL_SERVER_CERT_DN"),
    };
}

// =============================================================================
// Tests
// =============================================================================

test "WalletConfig.getConnectionDescriptor returns TNS name" {
    const config = WalletConfig{
        .wallet_location = "/path/to/wallet",
        .tns_name = "mydb_high",
    };

    const desc = try config.getConnectionDescriptor(std.testing.allocator);
    defer std.testing.allocator.free(desc);

    try std.testing.expectEqualStrings("mydb_high", desc);
}
