//! ANSI color codes for terminal output.
//!
//! Provides escape sequences for colored debug output in the terminal.
//! Used throughout the codebase for visually distinguishing different types
//! of log messages (errors, warnings, info, debug).
//!
//! Usage:
//!   std.debug.print("{s}[ERROR]{s} Something went wrong\n", .{RED, RESET});

/// Yellow color - typically used for warnings
pub const YELLOW = "\x1b[33m";

/// Red color - typically used for errors
pub const RED = "\x1b[31m";

/// Blue color - typically used for info messages
pub const BLUE = "\x1b[34m";

/// Green color - typically used for success messages
pub const GREEN = "\x1b[32m";

/// Cyan color - typically used for debug messages
pub const CYAN = "\x1b[36m";

/// Reset to default terminal color
pub const RESET = "\x1b[0m";
