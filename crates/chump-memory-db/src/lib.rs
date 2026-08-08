//! chump-memory-db — ChumpOS memory store extracted from the bin crate.
//!
//! Owns `chump_memory.db` schema/queries, episodic→semantic curation, and
//! provider-backed summarization. Extracted per EFFECTIVE-410 (build-speed) so
//! it compiles + caches independently of the 190k-line binary.

pub mod memory_db;
