//! JWT Validation
//! Validates JWT tokens from Keycloak for API authentication.
//!
//! SECURITY NOTE: RS256 signature verification is required for production.
//! Signature enforcement is ENABLED by default. Set ENFORCE_JWT_SIG=false
//! ONLY for local development/testing environments.
//! TODO: Implement full RS256 verification with JWKS fetching and caching
//! before deploying to production.

const std = @import("std");
const base64 = std.base64;

/// JWT Claims extracted from token
/// Caller owns the memory and must call deinit() to free allocated fields.
pub const Claims = struct {
    allocator: std.mem.Allocator,
    sub: []const u8, // Subject (user ID)
    iss: []const u8, // Issuer
    aud: []const u8, // Audience
    exp: i64, // Expiration timestamp
    iat: i64, // Issued at timestamp
    tenant_id: ?[]const u8, // Custom claim for multi-tenancy
    roles: [][]const u8, // User roles (owned slices)
    scope: ?[]const u8, // OAuth scopes

    /// Free all allocated memory
    pub fn deinit(self: *Claims) void {
        self.allocator.free(self.sub);
        self.allocator.free(self.iss);
        self.allocator.free(self.aud);
        if (self.tenant_id) |t| self.allocator.free(t);
        if (self.scope) |s| self.allocator.free(s);
        for (self.roles) |role| {
            self.allocator.free(role);
        }
        self.allocator.free(self.roles);
    }

    /// Check if token is expired
    pub fn isExpired(self: Claims) bool {
        return std.time.timestamp() > self.exp;
    }

    /// Check if user has a specific role
    pub fn hasRole(self: Claims, role: []const u8) bool {
        for (self.roles) |r| {
            if (std.mem.eql(u8, r, role)) return true;
        }
        return false;
    }
};

/// JWT Validation configuration
pub const JwtConfig = struct {
    jwk_set_uri: []const u8, // Keycloak JWKS endpoint
    issuer_uri: []const u8, // Expected issuer
    audience: []const u8, // Expected audience
    tenant_claim: []const u8 = "tenant_id",
    roles_claim: []const u8 = "roles",
    clock_skew_seconds: i64 = 60, // Allowed clock skew
    cache_ttl_seconds: u64 = 300, // JWK cache TTL
};

/// JWT Validator for Keycloak tokens
pub const JwtValidator = struct {
    config: JwtConfig,
    allocator: std.mem.Allocator,
    jwk_cache: ?JwkSet,
    cache_updated_at: i64,
    enforce_signature: bool,

    // Metrics
    validations_total: std.atomic.Value(u64),
    validations_success: std.atomic.Value(u64),
    validations_failed: std.atomic.Value(u64),

    const Self = @This();

    /// Initialize JWT validator
    pub fn init(config: JwtConfig, allocator: std.mem.Allocator) Self {
        // Signature enforcement is ENABLED by default (fail-secure)
        // Only disable when env var is explicitly set to "false" or "0"
        const enforce_sig = if (std.posix.getenv("ENFORCE_JWT_SIG")) |val|
            !(std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0"))
        else
            true;

        return .{
            .config = config,
            .allocator = allocator,
            .jwk_cache = null,
            .cache_updated_at = 0,
            .enforce_signature = enforce_sig,
            .validations_total = std.atomic.Value(u64).init(0),
            .validations_success = std.atomic.Value(u64).init(0),
            .validations_failed = std.atomic.Value(u64).init(0),
        };
    }

    /// Validate a JWT token
    pub fn validate(self: *Self, auth_header: []const u8) !Claims {
        _ = self.validations_total.fetchAdd(1, .monotonic);

        // Extract token from "Bearer <token>"
        const token = extractToken(auth_header) orelse {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.InvalidAuthHeader;
        };

        // Split token into parts
        var parts = std.mem.splitScalar(u8, token, '.');
        const header_b64 = parts.next() orelse {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.InvalidToken;
        };
        const payload_b64 = parts.next() orelse {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.InvalidToken;
        };
        const signature_b64 = parts.next() orelse {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.InvalidToken;
        };

        // Ensure no extra parts (must be exactly 3 dot-separated parts)
        if (parts.next() != null) {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.InvalidToken;
        }

        // Decode header
        const header_json = self.decodeBase64Url(header_b64) catch |err| {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return err;
        };
        defer self.allocator.free(header_json);

        // Decode payload
        const payload_json = self.decodeBase64Url(payload_b64) catch |err| {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return err;
        };
        defer self.allocator.free(payload_json);

        // Parse claims
        const claims = self.parseClaims(payload_json) catch |err| {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return err;
        };

        // Validate issuer
        if (!std.mem.eql(u8, claims.iss, self.config.issuer_uri)) {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.InvalidIssuer;
        }

        // Validate audience
        if (!std.mem.eql(u8, claims.aud, self.config.audience)) {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.InvalidAudience;
        }

        // Validate expiration
        const now = std.time.timestamp();
        if (now > claims.exp + self.config.clock_skew_seconds) {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.TokenExpired;
        }

        // Validate not before
        if (now < claims.iat - self.config.clock_skew_seconds) {
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.TokenNotYetValid;
        }

        // Signature verification
        if (self.enforce_signature) {
            // TODO: Implement RS256 signature verification with JWKS
            // For now, fail-safe: reject tokens when enforcement is enabled
            // but verification is not implemented
            _ = signature_b64; // Acknowledge we have the signature
            std.log.err("JWT signature enforcement enabled but verification not implemented", .{});
            _ = self.validations_failed.fetchAdd(1, .monotonic);
            return error.SignatureVerificationNotImplemented;
        }

        _ = self.validations_success.fetchAdd(1, .monotonic);
        return claims;
    }

    /// Extract token from Authorization header
    fn extractToken(header: []const u8) ?[]const u8 {
        if (std.mem.startsWith(u8, header, "Bearer ")) {
            return header[7..];
        }
        return null;
    }

    /// Decode base64url encoded string
    fn decodeBase64Url(self: *Self, encoded: []const u8) ![]u8 {
        // Convert base64url to standard base64
        var buf = try self.allocator.alloc(u8, encoded.len);
        defer self.allocator.free(buf);

        for (encoded, 0..) |char, i| {
            buf[i] = switch (char) {
                '-' => '+',
                '_' => '/',
                else => char,
            };
        }

        // Add padding if needed
        const padding_len = (4 - (encoded.len % 4)) % 4;
        const padded_len = encoded.len + padding_len;
        var padded = try self.allocator.alloc(u8, padded_len);
        defer self.allocator.free(padded);

        @memcpy(padded[0..encoded.len], buf[0..encoded.len]);
        for (encoded.len..padded_len) |i| {
            padded[i] = '=';
        }

        // Decode
        const decoded_len = try base64.standard.Decoder.calcSizeForSlice(padded);
        const decoded = try self.allocator.alloc(u8, decoded_len);
        try base64.standard.Decoder.decode(decoded, padded);

        return decoded;
    }

    /// Parse claims from JSON payload
    /// Returns Claims struct that owns all allocated memory.
    fn parseClaims(self: *Self, json_data: []const u8) !Claims {
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json_data,
            .{},
        ) catch return error.InvalidJson;
        defer parsed.deinit();

        const root = parsed.value.object;

        // Extract required claims
        const sub = if (root.get("sub")) |v| v.string else return error.MissingSubject;
        const iss = if (root.get("iss")) |v| v.string else return error.MissingIssuer;
        const exp = if (root.get("exp")) |v| v.integer else return error.MissingExpiration;
        const iat = if (root.get("iat")) |v| v.integer else return error.MissingIssuedAt;

        // Audience can be string or array
        const aud = if (root.get("aud")) |v| switch (v) {
            .string => |s| s,
            .array => |arr| if (arr.items.len > 0) arr.items[0].string else "",
            else => "",
        } else "";

        // Optional claims
        const tenant_id = if (root.get(self.config.tenant_claim)) |v| v.string else null;
        const scope = if (root.get("scope")) |v| v.string else null;

        // Parse roles - duplicate each string into allocator-owned memory
        var roles_list = std.ArrayList([]u8).init(self.allocator);
        errdefer {
            for (roles_list.items) |role| {
                self.allocator.free(role);
            }
            roles_list.deinit();
        }

        if (root.get(self.config.roles_claim)) |roles_value| {
            if (roles_value == .array) {
                for (roles_value.array.items) |role| {
                    if (role == .string) {
                        const duped_role = try self.allocator.dupe(u8, role.string);
                        try roles_list.append(duped_role);
                    }
                }
            }
        }

        return .{
            .allocator = self.allocator,
            .sub = try self.allocator.dupe(u8, sub),
            .iss = try self.allocator.dupe(u8, iss),
            .aud = try self.allocator.dupe(u8, aud),
            .exp = exp,
            .iat = iat,
            .tenant_id = if (tenant_id) |t| try self.allocator.dupe(u8, t) else null,
            .roles = try roles_list.toOwnedSlice(),
            .scope = if (scope) |s| try self.allocator.dupe(u8, s) else null,
        };
    }

    /// Get validator statistics
    pub fn getStats(self: *Self) ValidatorStats {
        return .{
            .total = self.validations_total.load(.monotonic),
            .success = self.validations_success.load(.monotonic),
            .failed = self.validations_failed.load(.monotonic),
        };
    }
};

/// JWK Set for caching public keys
const JwkSet = struct {
    keys: []Jwk,
};

/// JSON Web Key
const Jwk = struct {
    kty: []const u8,
    kid: []const u8,
    use: []const u8,
    alg: []const u8,
    n: []const u8, // RSA modulus
    e: []const u8, // RSA exponent
};

/// Validator statistics
pub const ValidatorStats = struct {
    total: u64,
    success: u64,
    failed: u64,
};
