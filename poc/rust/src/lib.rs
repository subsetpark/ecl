//! A small, end-to-end implementation of the language specified by the
//! documents in the repository's `design/` directory.
//!
//! This crate is deliberately a walking skeleton rather than the complete
//! v1 runtime. See `README.md` for the implemented surface.

pub mod error;
pub mod reader;
pub mod runtime;
pub mod value;

pub use error::{EclError, ErrorKind};
pub use reader::{ParseFailure, ReadStatus, Reader};
pub use runtime::Runtime;
pub use value::{SourceSpan, Value, ValueKind};
