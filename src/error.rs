use std::fmt;
use std::sync::Arc;

use crate::value::{SourceSpan, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorKind {
    Underflow,
    UndefinedWord,
    Type,
    Shape,
    Conform,
    Overflow,
    Domain,
    Contract,
    Parse,
    Io,
    User,
}

impl ErrorKind {
    pub fn symbol(self) -> &'static str {
        match self {
            Self::Underflow => "underflow",
            Self::UndefinedWord => "undefined-word",
            Self::Type => "type",
            Self::Shape => "shape",
            Self::Conform => "conform",
            Self::Overflow => "overflow",
            Self::Domain => "domain",
            Self::Contract => "contract",
            Self::Parse => "parse",
            Self::Io => "io",
            Self::User => "user",
        }
    }
}

#[derive(Clone, Debug)]
pub struct EclError {
    pub kind: ErrorKind,
    pub kind_name: Arc<str>,
    pub message: String,
    pub word: Option<Arc<str>>,
    pub trace: Vec<Arc<str>>,
    pub span: Option<Box<SourceSpan>>,
    pub data: Vec<(Value, Value)>,
}

impl EclError {
    pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            kind_name: Arc::from(kind.symbol()),
            message: message.into(),
            word: None,
            trace: Vec::new(),
            span: None,
            data: Vec::new(),
        }
    }

    pub fn parse(message: impl Into<String>, span: Option<SourceSpan>) -> Self {
        let mut error = Self::new(ErrorKind::Parse, message);
        error.span = span.map(Box::new);
        error
    }

    pub fn with_data(mut self, key: impl Into<Arc<str>>, value: Value) -> Self {
        self.data.push((Value::symbol(key), value));
        self
    }

    /// Convert a language error dictionary supplied to `raise` into the host
    /// control value used while unwinding the explicit evaluator.
    pub fn raised(value: &Value) -> Result<Self, Self> {
        let Some(entries) = value.as_dict() else {
            return Err(Self::new(
                ErrorKind::Type,
                format!("raise expected an error dict, got {}", value.type_name()),
            ));
        };
        let lookup = |name: &str| {
            entries
                .iter()
                .find_map(|(key, value)| (key.as_symbol() == Some(name)).then_some(value))
        };
        let Some(kind_name) = lookup("kind").and_then(Value::as_symbol) else {
            return Err(Self::new(
                ErrorKind::Type,
                "raise expected its dict to contain a symbol at 'kind",
            ));
        };
        let message = match lookup("msg") {
            Some(Value {
                kind: crate::value::ValueKind::String(message),
                ..
            }) => message.to_string(),
            Some(other) => {
                return Err(Self::new(
                    ErrorKind::Type,
                    format!(
                        "raise expected 'msg to be a string, got {}",
                        other.type_name()
                    ),
                ));
            }
            None => format!("raised '{kind_name}"),
        };
        let kind = match kind_name {
            "underflow" => ErrorKind::Underflow,
            "undefined-word" => ErrorKind::UndefinedWord,
            "type" => ErrorKind::Type,
            "shape" => ErrorKind::Shape,
            "conform" => ErrorKind::Conform,
            "overflow" => ErrorKind::Overflow,
            "domain" => ErrorKind::Domain,
            "contract" => ErrorKind::Contract,
            "parse" => ErrorKind::Parse,
            "io" => ErrorKind::Io,
            "user" => ErrorKind::User,
            _ => ErrorKind::User,
        };
        let mut error = Self::new(kind, message);
        error.kind_name = Arc::from(kind_name);
        if let Some(word) = lookup("word") {
            match &word.kind {
                crate::value::ValueKind::Symbol(word) => error.word = Some(word.clone()),
                crate::value::ValueKind::List(values) if values.is_empty() => {}
                _ => {
                    return Err(Self::new(
                        ErrorKind::Type,
                        "raise expected 'word to be a symbol or []",
                    ));
                }
            }
        }
        if let Some(trace) = lookup("trace") {
            let Some(trace) = trace.as_list() else {
                return Err(Self::new(
                    ErrorKind::Type,
                    "raise expected 'trace to be a list of symbols",
                ));
            };
            error.trace = trace
                .iter()
                .map(|value| {
                    value.as_symbol().map(Arc::from).ok_or_else(|| {
                        Self::new(ErrorKind::Type, "raise expected 'trace to contain symbols")
                    })
                })
                .collect::<Result<Vec<_>, _>>()?;
        }
        if let Some(data_value) = lookup("data") {
            let Some(data) = data_value.as_dict() else {
                return Err(Self::new(
                    ErrorKind::Type,
                    "raise expected 'data to be a dict",
                ));
            };
            let data_lookup = |name: &str| {
                data.iter()
                    .find_map(|(key, value)| (key.as_symbol() == Some(name)).then_some(value))
            };
            if let (
                Some(crate::value::ValueKind::String(source)),
                Some(crate::value::ValueKind::Int(line)),
                Some(crate::value::ValueKind::Int(column)),
            ) = (
                data_lookup("source").map(|value| &value.kind),
                data_lookup("line").map(|value| &value.kind),
                data_lookup("col").map(|value| &value.kind),
            ) && let (Ok(line), Ok(column)) = (usize::try_from(*line), usize::try_from(*column))
            {
                error.span = Some(Box::new(SourceSpan::new(source.clone(), line, column)));
            }
            error.data = data
                .iter()
                .filter(|(key, _)| !matches!(key.as_symbol(), Some("source" | "line" | "col")))
                .cloned()
                .collect();
        }
        Ok(error)
    }

    pub fn attach_context(&mut self, trace: &[Arc<str>], span: Option<SourceSpan>) {
        if self.word.is_none() {
            self.word = trace.last().cloned();
        }
        if self.trace.is_empty() {
            self.trace = trace.iter().rev().cloned().collect();
        }
        if self.span.is_none() {
            self.span = span.map(Box::new);
        }
    }

    pub fn to_value(&self) -> Value {
        let word = self.word.as_ref().map_or_else(
            || Value::list(Vec::new()),
            |word| Value::symbol(word.clone()),
        );
        let trace = Value::list(
            self.trace
                .iter()
                .map(|word| Value::symbol(word.clone()))
                .collect::<Vec<_>>(),
        );
        let mut data = self.data.clone();
        if let Some(span) = &self.span {
            data.push((Value::symbol("source"), Value::string(span.source.clone())));
            data.push((Value::symbol("line"), Value::int(span.line as i64)));
            data.push((Value::symbol("col"), Value::int(span.column as i64)));
        }
        Value::dict(vec![
            (Value::symbol("kind"), Value::symbol(self.kind_name.clone())),
            (Value::symbol("msg"), Value::string(self.message.clone())),
            (Value::symbol("word"), word),
            (Value::symbol("trace"), trace),
            (Value::symbol("data"), Value::dict(data)),
        ])
    }
}

impl fmt::Display for EclError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.to_value())
    }
}

impl std::error::Error for EclError {}
