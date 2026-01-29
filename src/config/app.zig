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
    extracted_wallet_path: ?[]const u8 = null, // Set if wallet was extracted from base64

    const Self = @This();

    /// Initialize application configuration from environment
    pub fn init(allocator: std.mem.Allocator) !Self {
        // First, check if we need to extract base64 wallet
        const extracted_path = try wallet.extractBase64Wallet(allocator);

        // Cleanup extracted wallet on any subsequent failure
        errdefer if (extracted_path) |path| {
            // Remove extracted files for security
            cleanupWalletDir(path);
            allocator.free(path);
        };

        const env_config = try env.Config.load();
        var wallet_config = try wallet.loadFromEnv();

        // If wallet was extracted, update the wallet location
        if (extracted_path) |path| {
            wallet_config.wallet_location = path;
            std.log.info("Using extracted wallet from ORACLE_WALLET_BASE64", .{});
        }

        return .{
            .env = env_config,
            .wallet = wallet_config,
            .allocator = allocator,
            .extracted_wallet_path = extracted_path,
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
        // Clean up extracted wallet directory if we created it
        if (self.extracted_wallet_path) |path| {
            cleanupWalletDir(path);
            std.log.info("Cleaned up extracted wallet directory", .{});

            // Free the allocated path string
            self.allocator.free(path);
            self.extracted_wallet_path = null;
        }
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

/// Helper to cleanup wallet directory (used by errdefer and deinit)
fn cleanupWalletDir(path: []const u8) void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            dir.deleteTree(entry.name) catch {};
        } else {
            dir.deleteFile(entry.name) catch {};
        }
    }
    std.fs.deleteDirAbsolute(path) catch {};
}

// Re-export commonly used types
pub const Config = env.Config;
pub const WalletConfig = wallet.WalletConfig;
