pub mod json;
pub mod table;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Table,
    /// INFRA-1257: machine-readable rankings for the fleet picker.
    Json,
}

impl std::str::FromStr for Format {
    type Err = anyhow::Error;
    fn from_str(s: &str) -> anyhow::Result<Self> {
        match s.to_ascii_lowercase().as_str() {
            "table" => Ok(Self::Table),
            "json" => Ok(Self::Json),
            // v0.2 adds: "mermaid", "markdown".
            other => anyhow::bail!("unsupported --format {other} (supports: table, json)"),
        }
    }
}
