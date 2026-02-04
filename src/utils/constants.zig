/// Centralized constants for the window manager
/// Contains all magic numbers and configuration thresholds

const std = @import("std");

// ============================================================================
// Batch Operation Constants
// ============================================================================

/// Maximum number of XCB operations in a single batch
/// 256 operations = ~16KB stack (well within safe limits)
pub const MAX_BATCH_OPS: usize = 256;

/// Auto-flush threshold at ~80% capacity to prevent overflow
/// Triggers automatic flush before batch fills completely
pub const AUTO_FLUSH_THRESHOLD: usize = 200;

// ============================================================================
// Window Management Constants
// ============================================================================

/// Maximum number of visible windows to process in tiling layouts
/// Stack-allocated buffer size for visible window list
pub const MAX_VISIBLE_WINDOWS: usize = 128;

/// Maximum batch size for window attribute queries during startup
/// Limits memory usage when scanning existing windows
pub const SETUP_BATCH_SIZE: usize = 256;

// ============================================================================
// Cursor Constants
// ============================================================================

/// X11 cursor glyph for left pointer
pub const CURSOR_LEFT_PTR: u16 = 68;

/// X11 cursor glyph for left pointer mask
pub const CURSOR_LEFT_PTR_MASK: u16 = 69;

// ============================================================================
// Signal Handling Constants
// ============================================================================

/// Timer interval for periodic tasks (clock updates, etc.)
pub const TIMER_INTERVAL_SEC: i64 = 1;

// ============================================================================
// XKB Constants (from xkbcommon.zig)
// ============================================================================

/// Maximum retry attempts for XKB initialization
pub const XKB_MAX_RETRIES: usize = 3;

/// Delay between XKB retry attempts in milliseconds
pub const XKB_RETRY_DELAY_MS: u64 = 50;

/// Minimum number of valid test keys required for keymap validation
pub const XKB_MIN_VALID_KEYS: usize = 2;

// ============================================================================
// Input Constants
// ============================================================================

/// Mouse button code for move operation (Button1)
pub const MOUSE_BUTTON_MOVE: u8 = 1;

/// Mouse button code for resize operation (Button3)
pub const MOUSE_BUTTON_RESIZE: u8 = 3;

// ============================================================================
// Performance Tuning
// ============================================================================

/// Initial capacity for keybind hash map
/// Set to reasonable default to avoid early rehashing
pub const KEYBIND_MAP_INITIAL_CAPACITY: u32 = 64;

/// Initial capacity for window tracking maps
pub const WINDOW_MAP_INITIAL_CAPACITY: u32 = 32;

// ============================================================================
// Notes
// ============================================================================

// These constants are centralized here to:
// 1. Make tuning easier - all magic numbers in one place
// 2. Ensure consistency across modules
// 3. Document the rationale for each value
// 4. Enable easy experimentation with different values
