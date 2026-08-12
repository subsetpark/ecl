use std::fmt;
use std::sync::Arc;

/// Source provenance carried by reader-produced values.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceSpan {
    pub source: Arc<str>,
    pub line: usize,
    pub column: usize,
}

impl SourceSpan {
    pub fn new(source: impl Into<Arc<str>>, line: usize, column: usize) -> Self {
        Self {
            source: source.into(),
            line,
            column,
        }
    }
}

impl fmt::Display for SourceSpan {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}:{}", self.source, self.line, self.column)
    }
}

/// A reader/evaluator value.
///
/// `Word` is the one implementation-level marker in the skeleton: it records
/// that a symbol appearing in a quotation is executable. Quoted source symbols
/// use `Symbol`. Keeping the marker in the list makes `cons`, `compose`,
/// `body`, and `parse` preserve code without introducing a separate AST.
#[derive(Clone, Debug)]
pub struct Value {
    pub kind: ValueKind,
    pub span: Option<SourceSpan>,
}

#[derive(Clone, Debug)]
pub enum ValueKind {
    Int(i64),
    Float(f64),
    Char(char),
    Symbol(Arc<str>),
    String(Arc<str>),
    List(Arc<[Value]>),
    Dict(Arc<[(Value, Value)]>),
    Word(Arc<str>),
}

impl Value {
    pub fn new(kind: ValueKind) -> Self {
        Self { kind, span: None }
    }

    pub fn at(kind: ValueKind, span: SourceSpan) -> Self {
        Self {
            kind,
            span: Some(span),
        }
    }

    pub fn int(value: i64) -> Self {
        Self::new(ValueKind::Int(value))
    }

    pub fn float(value: f64) -> Self {
        Self::new(ValueKind::Float(value))
    }

    pub fn char(value: char) -> Self {
        Self::new(ValueKind::Char(value))
    }

    pub fn symbol(value: impl Into<Arc<str>>) -> Self {
        Self::new(ValueKind::Symbol(value.into()))
    }

    pub fn string(value: impl Into<Arc<str>>) -> Self {
        Self::new(ValueKind::String(value.into()))
    }

    pub fn word(value: impl Into<Arc<str>>) -> Self {
        Self::new(ValueKind::Word(value.into()))
    }

    /// Construct a list, applying construction-specialization (decision 2):
    /// a non-empty all-char list is the same value as a string and takes the
    /// string representation immediately.
    pub fn list(values: impl Into<Vec<Value>>) -> Self {
        let values = values.into();
        if !values.is_empty()
            && values
                .iter()
                .all(|value| matches!(value.kind, ValueKind::Char(_)))
        {
            let string: String = values
                .iter()
                .map(|value| match value.kind {
                    ValueKind::Char(character) => character,
                    _ => unreachable!("all elements checked to be chars"),
                })
                .collect();
            return Self::new(ValueKind::String(Arc::from(string)));
        }
        Self::new(ValueKind::List(Arc::from(values)))
    }

    pub fn dict(entries: impl Into<Vec<(Value, Value)>>) -> Self {
        Self::new(ValueKind::Dict(Arc::from(entries.into())))
    }

    pub fn as_word(&self) -> Option<&str> {
        match &self.kind {
            ValueKind::Word(word) => Some(word),
            _ => None,
        }
    }

    pub fn as_symbol(&self) -> Option<&str> {
        match &self.kind {
            ValueKind::Symbol(symbol) => Some(symbol),
            _ => None,
        }
    }

    pub fn as_list(&self) -> Option<&[Value]> {
        match &self.kind {
            ValueKind::List(values) => Some(values),
            _ => None,
        }
    }

    pub fn as_dict(&self) -> Option<&[(Value, Value)]> {
        match &self.kind {
            ValueKind::Dict(entries) => Some(entries),
            _ => None,
        }
    }

    pub fn type_name(&self) -> &'static str {
        match self.kind {
            ValueKind::Int(_) => "int",
            ValueKind::Float(_) => "float",
            ValueKind::Char(_) => "char",
            ValueKind::Symbol(_) => "symbol",
            ValueKind::String(_) => "string",
            ValueKind::List(_) => "list",
            ValueKind::Dict(_) => "dict",
            ValueKind::Word(_) => "word",
        }
    }

    /// Structural whole-value equality (`match`), ignoring provenance.
    pub fn structurally_eq(&self, other: &Self) -> bool {
        match (&self.kind, &other.kind) {
            (ValueKind::Int(a), ValueKind::Int(b)) => a == b,
            // Numeric equality, matching `=`: 0.0 equals -0.0, and NaN cannot
            // exist (non-finite results from finite inputs are errors).
            (ValueKind::Float(a), ValueKind::Float(b)) => a == b,
            (ValueKind::Int(a), ValueKind::Float(b)) | (ValueKind::Float(b), ValueKind::Int(a)) => {
                (*a as f64) == *b
            }
            (ValueKind::Char(a), ValueKind::Char(b)) => a == b,
            (ValueKind::Symbol(a), ValueKind::Symbol(b)) => a == b,
            (ValueKind::String(a), ValueKind::String(b)) => a == b,
            (ValueKind::String(string), ValueKind::List(values))
            | (ValueKind::List(values), ValueKind::String(string)) => {
                string.chars().count() == values.len()
                    && string
                        .chars()
                        .zip(values.iter())
                        .all(|(character, value)| {
                            matches!(value.kind, ValueKind::Char(other) if character == other)
                        })
            }
            (ValueKind::Word(a), ValueKind::Word(b)) => a == b,
            (ValueKind::List(a), ValueKind::List(b)) => {
                a.len() == b.len()
                    && a.iter()
                        .zip(b.iter())
                        .all(|(left, right)| left.structurally_eq(right))
            }
            (ValueKind::Dict(a), ValueKind::Dict(b)) => {
                a.len() == b.len()
                    && a.iter().all(|(left_key, left_value)| {
                        b.iter().any(|(right_key, right_value)| {
                            left_key.structurally_eq(right_key)
                                && left_value.structurally_eq(right_value)
                        })
                    })
            }
            _ => false,
        }
    }

    pub fn canonical(&self) -> String {
        let mut output = String::new();
        self.write_canonical(&mut output);
        output
    }

    fn write_canonical(&self, output: &mut String) {
        match &self.kind {
            ValueKind::Int(value) => output.push_str(&value.to_string()),
            ValueKind::Float(value) => write_float(*value, output),
            ValueKind::Char(value) => write_char(*value, output),
            ValueKind::Symbol(value) => {
                output.push('\'');
                output.push_str(value);
            }
            ValueKind::String(value) => write_string(value, output),
            ValueKind::Word(value) => output.push_str(value),
            ValueKind::List(values) => {
                let (open, close) = if is_specialized(values) {
                    ('[', ']')
                } else {
                    ('(', ')')
                };
                output.push(open);
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        output.push(' ');
                    }
                    value.write_canonical(output);
                }
                output.push(close);
            }
            ValueKind::Dict(entries) => {
                output.push('{');
                for (index, (key, value)) in entries.iter().enumerate() {
                    if index > 0 {
                        output.push(' ');
                    }
                    key.write_canonical(output);
                    output.push(' ');
                    value.write_canonical(output);
                }
                output.push('}');
            }
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.canonical())
    }
}

impl PartialEq for Value {
    fn eq(&self, other: &Self) -> bool {
        self.structurally_eq(other)
    }
}

fn write_float(value: f64, output: &mut String) {
    if !value.is_finite() {
        // `inf`/`-inf` are literals and round-trip. NaN cannot be produced by
        // the runtime; printing it is defensive for debug-created values.
        output.push_str(if value.is_nan() {
            "nan"
        } else if value.is_sign_negative() {
            "-inf"
        } else {
            "inf"
        });
        return;
    }

    let rendered = value.to_string();
    output.push_str(&rendered);
    if !rendered.contains(['.', 'e', 'E']) {
        output.push_str(".0");
    }
}

fn write_char(value: char, output: &mut String) {
    output.push('\\');
    match value {
        ' ' => output.push_str("space"),
        '\t' => output.push_str("tab"),
        '\n' => output.push_str("newline"),
        c if c.is_control() || matches!(c, '\\' | '\'' | '"') => {
            output.push_str("u{");
            output.push_str(&format!("{:x}", c as u32));
            output.push('}');
        }
        c => output.push(c),
    }
}

fn write_string(value: &str, output: &mut String) {
    output.push('"');
    for character in value.chars() {
        match character {
            '\\' => output.push_str("\\\\"),
            '"' => output.push_str("\\\""),
            '\n' => output.push_str("\\n"),
            '\t' => output.push_str("\\t"),
            c if c.is_control() => {
                output.push_str("\\u{");
                output.push_str(&format!("{:x}", c as u32));
                output.push('}');
            }
            c => output.push(c),
        }
    }
    output.push('"');
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LeafKind {
    Int,
    Float,
    Char,
    Symbol,
    String,
}

fn scalar_leaf_kind(value: &Value) -> Option<LeafKind> {
    match value.kind {
        ValueKind::Int(_) => Some(LeafKind::Int),
        ValueKind::Float(_) => Some(LeafKind::Float),
        ValueKind::Char(_) => Some(LeafKind::Char),
        ValueKind::Symbol(_) => Some(LeafKind::Symbol),
        ValueKind::String(_) => Some(LeafKind::String),
        _ => None,
    }
}

/// Representation-facing specialization heuristic used by the skeleton's
/// printer. Empty and homogeneous flat leaves specialize; rectangular nests
/// of specialized lists specialize when all child shapes match.
fn is_specialized(values: &[Value]) -> bool {
    if values.is_empty() {
        return true;
    }

    if let Some(first_kind) = scalar_leaf_kind(&values[0]) {
        return values
            .iter()
            .all(|value| scalar_leaf_kind(value) == Some(first_kind));
    }

    let ValueKind::List(first) = &values[0].kind else {
        return false;
    };
    if !is_specialized(first) {
        return false;
    }
    let Some(shape) = rectangular_shape(&values[0]) else {
        return false;
    };
    values.iter().all(|value| {
        matches!(&value.kind, ValueKind::List(items) if is_specialized(items))
            && rectangular_shape(value).as_ref() == Some(&shape)
    })
}

pub(crate) fn rectangular_shape(value: &Value) -> Option<Vec<usize>> {
    match &value.kind {
        ValueKind::String(string) => Some(vec![string.chars().count()]),
        ValueKind::List(values) => {
            let mut shape = vec![values.len()];
            if values.is_empty() {
                return Some(shape);
            }

            let first_child = rectangular_shape(&values[0]);
            if values
                .iter()
                .skip(1)
                .any(|value| rectangular_shape(value) != first_child)
            {
                return None;
            }
            if let Some(child) = first_child {
                shape.extend(child);
            } else if values
                .iter()
                .any(|value| matches!(value.kind, ValueKind::List(_)))
            {
                return None;
            }
            Some(shape)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_printer_exposes_specialization() {
        assert_eq!(
            Value::list(vec![Value::int(1), Value::int(2)]).canonical(),
            "[1 2]"
        );
        assert_eq!(
            Value::list(vec![Value::int(1), Value::word("+")]).canonical(),
            "(1 +)"
        );
        assert_eq!(
            Value::list(vec![
                Value::list(vec![Value::int(1), Value::int(2)]),
                Value::list(vec![Value::int(3)])
            ])
            .canonical(),
            "([1 2] [3])"
        );
    }

    #[test]
    fn float_printing_remains_a_float() {
        assert_eq!(Value::float(2.0).canonical(), "2.0");
        assert_eq!(Value::float(0.125).canonical(), "0.125");
    }

    #[test]
    fn strings_are_structurally_char_vectors_and_dict_order_is_not_identity() {
        assert!(
            Value::string("ab")
                .structurally_eq(&Value::list(vec![Value::char('a'), Value::char('b')]))
        );
        assert!(
            Value::dict(vec![
                (Value::symbol("a"), Value::int(1)),
                (Value::symbol("b"), Value::int(2)),
            ])
            .structurally_eq(&Value::dict(vec![
                (Value::symbol("b"), Value::int(2)),
                (Value::symbol("a"), Value::int(1)),
            ]))
        );
    }
}
