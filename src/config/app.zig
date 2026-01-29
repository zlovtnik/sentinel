//! Application Configuration
//! Aggregates all configuration modules and provides a unified interface.

const std = @import("std");
const env = @import("env.zig");
const wallet = @import("wallet.zig");

/// Application context holding all runtime configuration
pub const AppConfig = struct {
    env: env.Config,
    wallet: wallet.WalletConfig,
    allocator: std.mem.Allocator,

    const Self = @This();

    /// Initialize application configuration from environment
    pub fn init(allocator: std.mem.Allocator) !Self {
        const env_config = try env.Config.load();
        const wallet_config = try wallet.loadFromEnv();

        return .{
            .env = env_config,
            .wallet = wallet_config,
            .allocator = allocator,
        };
    }

    /// Validate all configuration
    pub fn validate(self: *Self) !void {
        // Validate wallet exists
        try self.wallet.validate(self.allocator);

        // Validate port ranges
        if (self.env.http_port == 0) {
            return error.InvalidHttpPort;
        }

        // Validate pool settings
        if (self.env.pool_min_sessions > self.env.pool_max_sessions) {
            return error.InvalidPoolConfiguration;
        }

        std.log.info("Configuration validated successfully", .{});
    }

    /// Cleanup allocated resources
    pub fn deinit(self: *Self) void {
        _ = self;
        // Currently no heap allocations to free in AppConfig
        // This is a placeholder for future cleanup if needed
    }

    /// Get Oracle connection string
    pub fn getOracleConnString(self: *Self) ![]const u8 {
        return try self.wallet.getConnectionDescriptor(self.allocator);
    }

    /// Print configuration summary (safe for logs)
    pub fn printSummary(self: Self) void {
        self.env.printSummary();
    }
};

// Re-export commonly used types
pub const Config = env.Config;
pub const WalletConfig = wallet.WalletConfig;
