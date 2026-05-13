pub mod table;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Table,
}

impl std::str::FromStr for Format {
    type Err = anyhow::Error;
    fn from_str(s: &str) -> anyhow::Result<Self> {
        match s.to_ascii_lowercase().as_str() {
            "table" => Ok(Self::Table),
            // v0.2 adds: "json", "mermaid", "markdown".
            other => anyhow::bail!("unsupported --format {other} (v0.1 supports: table)"),
        }
    }
}
