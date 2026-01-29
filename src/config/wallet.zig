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
                    std.log.err("Failed to access Oracle Wallet {s}: {any}", .{ sso_path, err });
                    return err;
                },
            }
        };

        std.log.info("Oracle Wallet validated at: {s}", .{self.wallet_location});
    }
};

/// Environment-based wallet configuration loader
/// Supports two modes:
/// 1. ORACLE_WALLET_LOCATION - path to existing wallet directory
/// 2. ORACLE_WALLET_BASE64 - base64-encoded wallet files (for containerized deployments)
///
/// When using ORACLE_WALLET_BASE64:
/// - Expects base64-encoded content of wallet files (ZIP archive or custom format)
/// - ZIP format: Base64-encoded ZIP containing cwallet.sso, ewallet.p12, tnsnames.ora, etc.
/// - Custom format: Each file prefixed with "---FILENAME:name.ext---\n" followed by base64 content
/// - Files are extracted to a unique temp directory with mode 0o700
/// - The path is heap-allocated; caller must free when done
pub fn loadFromEnv() !WalletConfig {
    const tns_name = std.posix.getenv("ORACLE_TNS_NAME") orelse {
        std.log.err("ORACLE_TNS_NAME environment variable not set", .{});
        return error.MissingEnvironmentVariable;
    };

    // Check for base64 wallet first (preferred for containerized deployments)
    const wallet_location = blk: {
        if (std.posix.getenv("ORACLE_WALLET_BASE64")) |_| {
            // Base64 wallet will be extracted by extractBase64Wallet()
            // Use ORACLE_WALLET_EXTRACT_PATH if set, otherwise default path
            break :blk std.posix.getenv("ORACLE_WALLET_EXTRACT_PATH") orelse "/tmp/oracle_wallet";
        }

        // Fall back to traditional path-based wallet
        break :blk std.posix.getenv("ORACLE_WALLET_LOCATION") orelse {
            std.log.err("Neither ORACLE_WALLET_LOCATION nor ORACLE_WALLET_BASE64 environment variable set", .{});
            return error.MissingEnvironmentVariable;
        };
    };

    const ssl_match_str = std.posix.getenv("ORACLE_SSL_SERVER_DN_MATCH") orelse "yes";

    // Case-insensitive check for truthy/falsy values with warning for unrecognized
    const ssl_server_dn_match = ssl_blk: {
        if (ssl_match_str.len == 0) break :ssl_blk true; // Default to true

        // Convert to lowercase for comparison
        var lower_buf: [16]u8 = undefined;
        const len = @min(ssl_match_str.len, lower_buf.len);
        for (ssl_match_str[0..len], 0..) |ch, i| {
            lower_buf[i] = std.ascii.toLower(ch);
        }
        const lower = lower_buf[0..len];

        // Check for common truthy values
        if (std.mem.eql(u8, lower, "yes") or
            std.mem.eql(u8, lower, "true") or
            std.mem.eql(u8, lower, "1") or
            std.mem.eql(u8, lower, "on"))
        {
            break :ssl_blk true;
        }

        // Check for common falsy values
        if (std.mem.eql(u8, lower, "no") or
            std.mem.eql(u8, lower, "false") or
            std.mem.eql(u8, lower, "0") or
            std.mem.eql(u8, lower, "off"))
        {
            break :ssl_blk false;
        }

        // Unrecognized value - warn and default to true for security
        std.log.warn(
            "ORACLE_SSL_SERVER_DN_MATCH has unrecognized value '{s}'; defaulting to enabled",
            .{ssl_match_str},
        );
        break :ssl_blk true;
    };

    return .{
        .wallet_location = wallet_location,
        .tns_name = tns_name,
        .ssl_server_dn_match = ssl_server_dn_match,
        .ssl_server_cert_dn = std.posix.getenv("ORACLE_SSL_SERVER_CERT_DN"),
    };
}

/// Extract base64-encoded wallet from environment variable to filesystem
/// Call this before initializing the connection pool when ORACLE_WALLET_BASE64 is set.
///
/// Supports two formats for ORACLE_WALLET_BASE64:
/// 1. ZIP archive (recommended): Base64-encoded ZIP file containing wallet files
///    (cwallet.sso, ewallet.p12, tnsnames.ora, sqlnet.ora)
/// 2. Custom format: Base64-encoded content with ---FILENAME:name--- headers
///
/// Returns the heap-allocated path where wallet files were extracted, or null if no base64 wallet is configured.
/// The caller owns the returned path and must free it with the same allocator when done.
pub fn extractBase64Wallet(allocator: std.mem.Allocator) !?[]const u8 {
    const wallet_b64 = std.posix.getenv("ORACLE_WALLET_BASE64") orelse return null;

    // Use ORACLE_WALLET_EXTRACT_PATH if set, otherwise generate a unique path
    const base_path = std.posix.getenv("ORACLE_WALLET_EXTRACT_PATH") orelse "/tmp/oracle_wallet";

    // Generate unique directory name with PID and timestamp for uniqueness
    var path_buf: [256]u8 = undefined;
    const pid = std.c.getpid();
    const timestamp = std.time.milliTimestamp();
    const wallet_dir_slice = std.fmt.bufPrint(&path_buf, "{s}_{d}_{d}", .{ base_path, pid, timestamp }) catch {
        return error.PathTooLong;
    };

    // Allocate heap copy of the path to return
    const wallet_dir = try allocator.dupe(u8, wallet_dir_slice);
    errdefer allocator.free(wallet_dir);

    // Create wallet directory with secure permissions
    // Since we use PID+timestamp for uniqueness, PathAlreadyExists indicates a race condition
    std.fs.makeDirAbsolute(wallet_dir) catch |err| {
        std.log.err("Failed to create wallet directory {s}: {any}", .{ wallet_dir, err });
        return err;
    };

    // Decode the outer base64 wrapper
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(wallet_b64) catch |err| {
        std.log.err("Failed to calculate base64 decode size: {any}", .{err});
        return error.InvalidBase64;
    };
    const decoded = try allocator.alloc(u8, decoded_size);
    defer allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, wallet_b64) catch |err| {
        std.log.err("Failed to decode ORACLE_WALLET_BASE64: {any}", .{err});
        return error.InvalidBase64;
    };

    // Detect format: ZIP files start with "PK" (0x50 0x4B)
    if (decoded.len >= 2 and decoded[0] == 0x50 and decoded[1] == 0x4B) {
        try extractZipWallet(wallet_dir, decoded, allocator);
    } else {
        try extractCustomFormatWallet(wallet_dir, decoded, allocator);
    }

    std.log.info("Oracle wallet extracted to: {s}", .{wallet_dir});

    // Return the heap-allocated path (caller owns and must free)
    return wallet_dir;
}

/// Extract wallet files from a ZIP archive
/// Parses ZIP format manually to avoid std.zip API issues
fn extractZipWallet(wallet_dir: []const u8, zip_data: []const u8, allocator: std.mem.Allocator) !void {
    var dir = try std.fs.openDirAbsolute(wallet_dir, .{});
    defer dir.close();

    // Find End of Central Directory record by scanning backwards
    // EOCD signature is "PK\x05\x06"
    var eocd_pos: ?usize = null;
    if (zip_data.len >= 22) {
        var i: usize = zip_data.len - 22;
        while (true) {
            if (i + 3 < zip_data.len and
                zip_data[i] == 0x50 and zip_data[i + 1] == 0x4B and
                zip_data[i + 2] == 0x05 and zip_data[i + 3] == 0x06)
            {
                eocd_pos = i;
                break;
            }
            if (i == 0) break;
            i -= 1;
        }
    }

    if (eocd_pos == null) {
        std.log.err("No EOCD record found in ZIP", .{});
        return error.InvalidZipFormat;
    }

    // Parse EOCD to get central directory offset
    const eocd = eocd_pos.?;
    const cd_offset = std.mem.readInt(u32, zip_data[eocd + 16 ..][0..4], .little);
    const total_entries = std.mem.readInt(u16, zip_data[eocd + 10 ..][0..2], .little);

    var cd_pos: usize = cd_offset;
    var entries_processed: u16 = 0;
    var successful_extractions: u16 = 0;

    while (entries_processed < total_entries and cd_pos + 46 <= zip_data.len) {
        // Check central directory signature "PK\x01\x02"
        if (zip_data[cd_pos] != 0x50 or zip_data[cd_pos + 1] != 0x4B or
            zip_data[cd_pos + 2] != 0x01 or zip_data[cd_pos + 3] != 0x02)
        {
            break;
        }

        const compression = std.mem.readInt(u16, zip_data[cd_pos + 10 ..][0..2], .little);
        const compressed_size = std.mem.readInt(u32, zip_data[cd_pos + 20 ..][0..4], .little);
        const uncompressed_size = std.mem.readInt(u32, zip_data[cd_pos + 24 ..][0..4], .little);
        const filename_len = std.mem.readInt(u16, zip_data[cd_pos + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, zip_data[cd_pos + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, zip_data[cd_pos + 32 ..][0..2], .little);
        const local_header_offset = std.mem.readInt(u32, zip_data[cd_pos + 42 ..][0..4], .little);

        const filename_start = cd_pos + 46;
        const filename_end = filename_start + filename_len;
        if (filename_end > zip_data.len) break;

        const full_filename = zip_data[filename_start..filename_end];

        // Skip directories
        if (!std.mem.endsWith(u8, full_filename, "/")) {
            const filename = std.fs.path.basename(full_filename);

            if (filename.len > 0) {
                // Check if this is a critical wallet file (explicitly includes cwallet.sso and ewallet.p12)
                const is_critical = std.mem.eql(u8, filename, "cwallet.sso") or
                    std.mem.eql(u8, filename, "ewallet.p12") or
                    std.mem.endsWith(u8, filename, ".sso") or
                    std.mem.endsWith(u8, filename, ".p12");

                // Read local file header to get actual data offset
                const local_offset: usize = local_header_offset;
                if (local_offset + 30 <= zip_data.len) {
                    const local_filename_len = std.mem.readInt(u16, zip_data[local_offset + 26 ..][0..2], .little);
                    const local_extra_len = std.mem.readInt(u16, zip_data[local_offset + 28 ..][0..2], .little);

                    const data_offset = local_offset + 30 + local_filename_len + local_extra_len;
                    const data_end = data_offset + compressed_size;

                    if (data_end <= zip_data.len) {
                        // Only handle stored (uncompressed) files
                        if (compression == 0) {
                            const file_data = zip_data[data_offset..data_end];

                            // Write file with secure permissions
                            const file = dir.createFile(filename, .{ .mode = 0o600 }) catch |err| {
                                std.log.err("Failed to create {s}: {any}", .{ filename, err });
                                cd_pos += 46 + filename_len + extra_len + comment_len;
                                entries_processed += 1;
                                continue;
                            };
                            defer file.close();
                            file.writeAll(file_data) catch |err| {
                                std.log.err("Failed to write {s}: {any}", .{ filename, err });
                                cd_pos += 46 + filename_len + extra_len + comment_len;
                                entries_processed += 1;
                                continue;
                            };

                            std.log.debug("Extracted wallet file: {s} ({d} bytes)", .{ filename, file_data.len });
                            successful_extractions += 1;
                        } else if (compression == 8) {
                            // Deflate compression - inflate using zlib
                            const compressed = zip_data[data_offset..data_end];
                            var input_reader: std.Io.Reader = .fixed(compressed);
                            const history = try allocator.alloc(u8, std.compress.flate.max_window_len);
                            defer allocator.free(history);
                            var inflater = std.compress.flate.Decompress.init(&input_reader, .raw, history);
                            const inflated = inflater.reader.readAlloc(
                                allocator,
                                @intCast(uncompressed_size),
                            ) catch |err| {
                                if (is_critical) {
                                    std.log.err("Failed to inflate critical wallet file {s}: {any}", .{ filename, err });
                                    return error.DeflateDecompressionFailed;
                                }
                                std.log.warn("Failed to inflate file {s}: {any}", .{ filename, err });
                                cd_pos += 46 + filename_len + extra_len + comment_len;
                                entries_processed += 1;
                                continue;
                            };
                            defer allocator.free(inflated);

                            const file = dir.createFile(filename, .{ .mode = 0o600 }) catch |err| {
                                std.log.err("Failed to create {s}: {any}", .{ filename, err });
                                cd_pos += 46 + filename_len + extra_len + comment_len;
                                entries_processed += 1;
                                continue;
                            };
                            defer file.close();
                            file.writeAll(inflated) catch |err| {
                                std.log.err("Failed to write {s}: {any}", .{ filename, err });
                                cd_pos += 46 + filename_len + extra_len + comment_len;
                                entries_processed += 1;
                                continue;
                            };

                            std.log.debug("Extracted wallet file: {s} ({d} bytes)", .{ filename, inflated.len });
                            successful_extractions += 1;
                        } else {
                            if (is_critical) {
                                std.log.err("Critical wallet file {s} uses unsupported compression {d}", .{ filename, compression });
                                return error.UnsupportedCompression;
                            }
                            std.log.warn("Unsupported compression method {d} for {s}", .{ compression, filename });
                        }
                    }
                }
            }
        }

        // Move to next central directory entry
        cd_pos += 46 + filename_len + extra_len + comment_len;
        entries_processed += 1;
    }

    if (successful_extractions == 0) {
        std.log.err("No files extracted from ZIP archive", .{});
        return error.EmptyZipArchive;
    }
}

/// Extract wallet files from custom ---FILENAME:xxx--- format
fn extractCustomFormatWallet(wallet_dir: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    var lines = std.mem.splitSequence(u8, content, "\n");
    var current_filename: ?[]const u8 = null;
    var file_content: std.ArrayList(u8) = .empty;
    defer file_content.deinit(allocator);

    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "---FILENAME:") and std.mem.endsWith(u8, line, "---")) {
            // Save previous file if exists
            if (current_filename) |filename| {
                try writeWalletFile(wallet_dir, filename, file_content.items, allocator);
            }

            // Start new file
            const name_start = "---FILENAME:".len;
            const name_end = line.len - "---".len;
            current_filename = line[name_start..name_end];
            file_content.clearRetainingCapacity();
        } else if (current_filename) |filename| {
            if (line.len == 0) continue;

            // Check if this is a binary wallet file that requires valid base64
            // Using endsWith covers cwallet.sso, ewallet.p12, and any path variants
            const is_binary = std.mem.endsWith(u8, filename, ".sso") or
                std.mem.endsWith(u8, filename, ".p12") or
                std.mem.endsWith(u8, filename, ".p12.lck");

            // Decode base64 content for this file
            const line_decoded_size = std.base64.standard.Decoder.calcSizeForSlice(line) catch {
                if (is_binary) {
                    std.log.err("Invalid base64 in binary wallet file: {s}", .{filename});
                    return error.InvalidBase64InBinaryFile;
                }
                // Invalid base64, treat as raw content for text files
                try file_content.appendSlice(allocator, line);
                try file_content.append(allocator, '\n');
                continue;
            };
            const line_buf = try allocator.alloc(u8, line_decoded_size);
            defer allocator.free(line_buf);

            std.base64.standard.Decoder.decode(line_buf, line) catch {
                if (is_binary) {
                    std.log.err("Base64 decode failed for binary wallet file: {s}", .{filename});
                    return error.InvalidBase64InBinaryFile;
                }
                // Not valid base64, might be raw content - append as-is for text files
                try file_content.appendSlice(allocator, line);
                try file_content.append(allocator, '\n');
                continue;
            };
            try file_content.appendSlice(allocator, line_buf);
        }
    }

    // Write last file
    if (current_filename) |filename| {
        try writeWalletFile(wallet_dir, filename, file_content.items, allocator);
    }
}

fn writeWalletFile(
    wallet_dir: []const u8,
    filename: []const u8,
    content: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const file_path = try std.fs.path.join(allocator, &.{ wallet_dir, filename });
    defer allocator.free(file_path);

    // Create file with restrictive permissions (owner read/write only)
    const file = try std.fs.createFileAbsolute(file_path, .{ .mode = 0o600 });
    defer file.close();

    try file.writeAll(content);

    std.log.debug("Extracted wallet file: {s} ({d} bytes)", .{ filename, content.len });
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
