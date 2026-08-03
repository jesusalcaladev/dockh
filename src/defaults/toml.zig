//! The default config.toml, embedded inside its own module.
//!
//! dockh embeds it from src/main.zig (`@embedFile("defaults/config.toml")`,
//! which stays inside the dock's module root src/). dockh-config's module is
//! rooted at src/config-gui/, where a `../defaults/` embed would leave the
//! package path — so it imports this file as a named submodule instead.
pub const content = @embedFile("config.toml");
