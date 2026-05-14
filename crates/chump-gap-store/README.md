# chump-gap-store

SQLite-backed gap registry used by the [Chump](https://github.com/repairman29/chump) fleet. A "gap" is a piece of work with an ID, status, priority, effort, dependencies, and blame lineage. This crate is the canonical store: it owns the schema, the migrations, and the per-file YAML mirror layer that lets git track gap state alongside code.

## What it does

- **Schema** — `gaps`, `gap_blame`, `gap_events` tables with automatic migrations.
- **Read/write API** — `GapStore::open(path)` returns a handle; `insert`, `update`, `list`, `get`, `ship`, `reserve` operate over the SQLite connection.
- **YAML mirror** — `dump_per_file` / `load_per_file_*` write one `docs/gaps/<ID>.yaml` per gap so the registry is git-trackable without a monolithic file.
- **Dependency walk** — `topo_pickable(ids)` and `blocked_by(id)` honor the `depends_on` graph.
- **Drift detection** — `audit_priorities`, `vague_pickable`, and `missing_dep_refs` surface registry health issues for fleet ops.

## Zero internal deps on `chump`

The crate intentionally depends only on `anyhow`, `rusqlite`, `serde`, `serde_json`, `serde_yaml`, and `chrono`. Nothing from the main `chump` binary leaks in. The chump CLI consumes this crate as a path dependency; nothing else in the workspace imports it directly.

## License

MIT.
