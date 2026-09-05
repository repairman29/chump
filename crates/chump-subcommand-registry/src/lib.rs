//! Subcommand self-registration via `inventory` (INFRA-1687 slice).
//!
//! Each subcommand module calls [`register_subcommand!`] once at module
//! scope to submit itself into the link-time registry, so adding a new
//! subcommand never requires editing a central dispatch file.

pub use inventory;

/// A CLI subcommand registered at link time via [`register_subcommand!`].
pub struct Subcommand {
    pub name: &'static str,
    pub run: fn(&[String]) -> anyhow::Result<()>,
}

inventory::collect!(Subcommand);

/// Registers a subcommand into the link-time inventory.
///
/// ```
/// use chump_subcommand_registry::register_subcommand;
///
/// fn run_hello(_args: &[String]) -> anyhow::Result<()> {
///     Ok(())
/// }
///
/// register_subcommand!("hello", run_hello);
/// ```
#[macro_export]
macro_rules! register_subcommand {
    ($name:expr, $run:expr) => {
        $crate::inventory::submit! {
            $crate::Subcommand {
                name: $name,
                run: $run,
            }
        }
    };
}

/// Iterates every subcommand registered so far via [`register_subcommand!`].
pub fn all_subcommands() -> impl Iterator<Item = &'static Subcommand> {
    inventory::iter::<Subcommand>()
}
