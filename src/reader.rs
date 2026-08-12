use std::collections::HashSet;
use std::fmt;
use std::sync::Arc;

use crate::error::EclError;
use crate::value::{SourceSpan, Value, ValueKind};

#[derive(Clone, Debug)]
pub struct ParseFailure(pub EclError);

impl fmt::Display for ParseFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl std::error::Error for ParseFailure {}

#[derive(Clone, Debug)]
pub enum ReadStatus {
    Complete(Vec<Value>),
    Incomplete { message: String, span: SourceSpan },
}

/// The ecl reader. A reader is cheap and only retains the logical source name.
#[derive(Clone, Debug)]
pub struct Reader {
    source: Arc<str>,
}

impl Reader {
    pub fn new(source: impl Into<Arc<str>>) -> Self {
        Self {
            source: source.into(),
        }
    }

    /// Read a complete script or `-e` unit.
    pub fn read(&self, input: &str) -> Result<Vec<Value>, ParseFailure> {
        match self.read_status(input)? {
            ReadStatus::Complete(forms) => Ok(forms),
            ReadStatus::Incomplete { message, span } => {
                Err(ParseFailure(EclError::parse(message, Some(span))))
            }
        }
    }

    /// Read a possibly incomplete REPL unit. Open delimiters and strings are
    /// reported as `Incomplete`; every other malformed form is an error.
    pub fn read_status(&self, input: &str) -> Result<ReadStatus, ParseFailure> {
        let mut parser = Parser::new(self.source.clone(), input);
        match parser.program() {
            Ok(forms) => Ok(ReadStatus::Complete(forms)),
            Err(ParseSignal::Incomplete { message, span }) => {
                Ok(ReadStatus::Incomplete { message, span })
            }
            Err(ParseSignal::Failure(error)) => Err(ParseFailure(error)),
        }
    }
}

enum ParseSignal {
    Incomplete { message: String, span: SourceSpan },
    Failure(EclError),
}

type ParseResult<T> = Result<T, ParseSignal>;

struct Parser {
    source: Arc<str>,
    chars: Vec<char>,
    index: usize,
    line: usize,
    column: usize,
}

impl Parser {
    fn new(source: Arc<str>, input: &str) -> Self {
        Self {
            source,
            chars: input.chars().collect(),
            index: 0,
            line: 1,
            column: 1,
        }
    }

    fn program(&mut self) -> ParseResult<Vec<Value>> {
        let mut forms = Vec::new();
        loop {
            self.skip_ignored();
            let Some(character) = self.peek() else {
                return Ok(forms);
            };
            if matches!(character, ')' | ']' | '}') {
                return self.fail(format!("unmatched closing delimiter `{character}`"));
            }
            forms.extend(self.form()?);
        }
    }

    /// A source form expands to more than one value only for `{...}`, whose
    /// two-form expansion is `( ... ) dict-of`.
    fn form(&mut self) -> ParseResult<Vec<Value>> {
        self.skip_ignored();
        let Some(character) = self.peek() else {
            return self.incomplete("expected a form before end of input", self.span());
        };
        match character {
            '(' | '[' => self.list(character).map(|value| vec![value]),
            '{' => self.dict(),
            '"' => self.string().map(|value| vec![value]),
            '\'' => self.quoted_symbol().map(|value| vec![value]),
            '\\' => self.character().map(|value| vec![value]),
            ')' | ']' | '}' => self.fail(format!("unmatched closing delimiter `{character}`")),
            ';' => self.fail("`;` is reserved"),
            '|' => self.fail("`|` is legal only around a list's leading binder"),
            _ => self.atom().map(|value| vec![value]),
        }
    }

    fn list(&mut self, open: char) -> ParseResult<Value> {
        let start = self.span();
        self.bump();
        let close = if open == '(' { ')' } else { ']' };
        self.skip_ignored();
        let binder = if self.peek() == Some('|') {
            Some(self.binder()?)
        } else {
            None
        };

        let mut body = Vec::new();
        loop {
            self.skip_ignored();
            match self.peek() {
                Some(character) if character == close => {
                    self.bump();
                    break;
                }
                Some(character) if matches!(character, ')' | ']') => {
                    return self.fail_at(
                        format!(
                            "mismatched delimiter: `{open}` must close with `{close}`, not `{character}`"
                        ),
                        self.span(),
                    );
                }
                Some('}') => {
                    return self.fail_at("unmatched closing delimiter `}`", self.span());
                }
                None => {
                    return self
                        .incomplete(format!("unclosed `{open}`; expected `{close}`"), start);
                }
                _ => body.extend(self.form()?),
            }
        }

        let body = if let Some(names) = binder {
            lower_binder(names, body, &start).map_err(ParseSignal::Failure)?
        } else {
            body
        };
        // Construction-specialization (decision 2): all-char lists become
        // strings here too, so `[\a \b]` and `"ab"` are the same value.
        let mut value = Value::list(body);
        value.span = Some(start);
        Ok(value)
    }

    fn dict(&mut self) -> ParseResult<Vec<Value>> {
        let start = self.span();
        self.bump();
        let mut body = Vec::new();
        loop {
            self.skip_ignored();
            match self.peek() {
                Some('}') => {
                    self.bump();
                    break;
                }
                Some(character) if matches!(character, ')' | ']') => {
                    return self.fail_at(
                        format!(
                            "mismatched delimiter: `{{` must close with `}}`, not `{character}`"
                        ),
                        self.span(),
                    );
                }
                None => return self.incomplete("unclosed `{`; expected `}`", start),
                _ => body.extend(self.form()?),
            }
        }

        Ok(vec![
            Value::at(ValueKind::List(Arc::from(body)), start.clone()),
            Value::at(ValueKind::Word(Arc::from("dict-of")), start),
        ])
    }

    fn binder(&mut self) -> ParseResult<Vec<Arc<str>>> {
        let start = self.span();
        self.bump();
        let mut names = Vec::new();
        let mut seen = HashSet::new();
        loop {
            self.skip_ignored();
            match self.peek() {
                Some('|') => {
                    self.bump();
                    if names.is_empty() {
                        return self.fail_at("a binder must contain at least one name", start);
                    }
                    return Ok(names);
                }
                None => return self.incomplete("unclosed binder; expected `|`", start),
                Some('(' | ')' | '[' | ']' | '{' | '}' | '"' | '\'' | '\\' | ';') => {
                    return self.fail_at(
                        "binder names must be unquoted, unqualified symbols",
                        self.span(),
                    );
                }
                _ => {
                    let name_span = self.span();
                    let token = self.take_token(true);
                    if token.is_empty()
                        || token.contains('.')
                        || classify_number(&token).is_some()
                        || classify_inf(&token).is_some()
                        || !valid_symbol(&token)
                    {
                        return self.fail_at(format!("invalid binder name `{token}`"), name_span);
                    }
                    if !seen.insert(token.clone()) {
                        return self.fail_at(format!("duplicate binder name `{token}`"), name_span);
                    }
                    names.push(Arc::from(token));
                }
            }
        }
    }

    fn string(&mut self) -> ParseResult<Value> {
        let start = self.span();
        self.bump();
        let mut value = String::new();
        loop {
            match self.bump() {
                Some('"') => {
                    return Ok(Value::at(ValueKind::String(Arc::from(value)), start));
                }
                Some('\\') => value.push(self.escape(&start)?),
                Some(character) => value.push(character),
                None => return self.incomplete("unclosed string; expected `\"`", start),
            }
        }
    }

    fn escape(&mut self, string_start: &SourceSpan) -> ParseResult<char> {
        let escape_span = self.span();
        match self.bump() {
            Some('\\') => Ok('\\'),
            Some('"') => Ok('"'),
            Some('n') => Ok('\n'),
            Some('t') => Ok('\t'),
            Some('u') if self.peek() == Some('{') => {
                self.bump();
                let mut digits = String::new();
                loop {
                    match self.bump() {
                        Some('}') => break,
                        Some(character) if character.is_ascii_hexdigit() => digits.push(character),
                        Some(character) => {
                            return self.fail_at(
                                format!("invalid character `{character}` in Unicode escape"),
                                escape_span,
                            );
                        }
                        None => {
                            return self.incomplete(
                                "unclosed Unicode escape; expected `}`",
                                string_start.clone(),
                            );
                        }
                    }
                }
                decode_codepoint(&digits).map_err(|message| {
                    ParseSignal::Failure(EclError::parse(message, Some(escape_span)))
                })
            }
            Some(character) => self.fail_at(
                format!("unknown string escape `\\{character}`"),
                escape_span,
            ),
            None => self.incomplete("unclosed string escape", string_start.clone()),
        }
    }

    fn quoted_symbol(&mut self) -> ParseResult<Value> {
        let start = self.span();
        self.bump();
        let token = self.take_token(false);
        if !valid_symbol(&token) {
            return self.fail_at(
                if token.is_empty() {
                    "quoted symbol is missing its name".to_owned()
                } else {
                    format!("invalid quoted symbol `'{token}`")
                },
                start,
            );
        }
        Ok(Value::at(ValueKind::Symbol(Arc::from(token)), start))
    }

    fn character(&mut self) -> ParseResult<Value> {
        let start = self.span();
        self.bump();
        let Some(next) = self.peek() else {
            return self.fail_at("character literal is missing its character", start);
        };

        let value = if next == 'u' && self.peek_n(1) == Some('{') {
            self.bump();
            self.bump();
            let mut digits = String::new();
            loop {
                match self.bump() {
                    Some('}') => break,
                    Some(character) if character.is_ascii_hexdigit() => digits.push(character),
                    Some(character) => {
                        return self.fail_at(
                            format!("invalid character `{character}` in Unicode character literal"),
                            start,
                        );
                    }
                    None => {
                        return self
                            .incomplete("unclosed Unicode character literal; expected `}`", start);
                    }
                }
            }
            decode_codepoint(&digits).map_err(|message| {
                ParseSignal::Failure(EclError::parse(message, Some(start.clone())))
            })?
        } else if is_token_boundary(next) || matches!(next, ';' | '|') {
            self.bump().expect("peeked character exists")
        } else {
            let token = self.take_token(false);
            match token.as_str() {
                "space" => ' ',
                "tab" => '\t',
                "newline" => '\n',
                _ if token.starts_with("u{") && token.ends_with('}') => {
                    decode_codepoint(&token[2..token.len() - 1]).map_err(|message| {
                        ParseSignal::Failure(EclError::parse(message, Some(start.clone())))
                    })?
                }
                _ => {
                    let mut characters = token.chars();
                    let Some(character) = characters.next() else {
                        return self.fail_at("character literal is missing its character", start);
                    };
                    if characters.next().is_some() {
                        return self.fail_at(format!("unknown character name `\\{token}`"), start);
                    }
                    character
                }
            }
        };
        Ok(Value::at(ValueKind::Char(value), start))
    }

    fn atom(&mut self) -> ParseResult<Value> {
        let start = self.span();
        let token = self.take_token(false);
        if token.is_empty() {
            return self.fail_at("expected a token", start);
        }

        if let Some(value) = classify_inf(&token) {
            return Ok(Value::at(ValueKind::Float(value), start));
        }
        if looks_like_number(&token) {
            match classify_number(&token) {
                Some(Ok(Number::Int(value))) => {
                    return Ok(Value::at(ValueKind::Int(value), start));
                }
                Some(Ok(Number::Float(value))) => {
                    return Ok(Value::at(ValueKind::Float(value), start));
                }
                Some(Err(message)) => return self.fail_at(message, start),
                None => {}
            }
        }
        if !valid_symbol(&token) {
            return self.fail_at(format!("invalid word `{token}`"), start);
        }
        Ok(Value::at(ValueKind::Word(Arc::from(token)), start))
    }

    fn take_token(&mut self, stop_at_pipe: bool) -> String {
        let mut token = String::new();
        while let Some(character) = self.peek() {
            if is_token_boundary(character)
                || matches!(character, ';')
                || (stop_at_pipe && character == '|')
                || (!stop_at_pipe && character == '|')
            {
                break;
            }
            token.push(character);
            self.bump();
        }
        token
    }

    fn skip_ignored(&mut self) {
        loop {
            while self
                .peek()
                .is_some_and(|character| character.is_whitespace() || character == ',')
            {
                self.bump();
            }
            if self.peek() == Some('#') {
                while self.peek().is_some_and(|character| character != '\n') {
                    self.bump();
                }
                continue;
            }
            break;
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.index).copied()
    }

    fn peek_n(&self, offset: usize) -> Option<char> {
        self.chars.get(self.index + offset).copied()
    }

    fn bump(&mut self) -> Option<char> {
        let character = self.peek()?;
        self.index += 1;
        if character == '\n' {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        Some(character)
    }

    fn span(&self) -> SourceSpan {
        SourceSpan::new(self.source.clone(), self.line, self.column)
    }

    fn fail<T>(&self, message: impl Into<String>) -> ParseResult<T> {
        self.fail_at(message, self.span())
    }

    fn fail_at<T>(&self, message: impl Into<String>, span: SourceSpan) -> ParseResult<T> {
        Err(ParseSignal::Failure(EclError::parse(message, Some(span))))
    }

    fn incomplete<T>(&self, message: impl Into<String>, span: SourceSpan) -> ParseResult<T> {
        Err(ParseSignal::Incomplete {
            message: message.into(),
            span,
        })
    }
}

fn is_token_boundary(character: char) -> bool {
    character.is_whitespace()
        || character == ','
        || matches!(character, '(' | ')' | '[' | ']' | '{' | '}' | '"' | '#')
}

fn valid_symbol(token: &str) -> bool {
    !token.is_empty()
        && !token.starts_with(['\'', '\\'])
        && !token.ends_with('.')
        && !token.starts_with('.')
        && !token.contains("..")
        && !token.chars().any(|character| {
            character.is_whitespace()
                || character == ','
                || matches!(
                    character,
                    '(' | ')' | '[' | ']' | '{' | '}' | '"' | '#' | '\'' | '\\' | ';' | '|'
                )
        })
}

enum Number {
    Int(i64),
    Float(f64),
}

/// `Some` means the token has a complete numeric lexical shape. The inner
/// error distinguishes an out-of-range literal from an ordinary word such as
/// `2dup` or `1+`.
fn classify_number(token: &str) -> Option<Result<Number, String>> {
    let unsigned = token
        .strip_prefix(['+', '-'])
        .filter(|rest| !rest.is_empty())
        .unwrap_or(token);

    if let Some(hex) = unsigned.strip_prefix("0x") {
        if hex.is_empty() || !hex.chars().all(|character| character.is_ascii_hexdigit()) {
            return None;
        }
        let negative = token.starts_with('-');
        let magnitude = match u64::from_str_radix(hex, 16) {
            Ok(value) => value,
            Err(_) => return Some(Err(format!("integer literal `{token}` is outside int64"))),
        };
        let value = if negative {
            if magnitude == (i64::MAX as u64) + 1 {
                i64::MIN
            } else if magnitude <= i64::MAX as u64 {
                -(magnitude as i64)
            } else {
                return Some(Err(format!("integer literal `{token}` is outside int64")));
            }
        } else if magnitude <= i64::MAX as u64 {
            magnitude as i64
        } else {
            return Some(Err(format!("integer literal `{token}` is outside int64")));
        };
        return Some(Ok(Number::Int(value)));
    }

    if valid_decimal_int(unsigned) {
        let normalized = token.replace('_', "");
        return Some(
            normalized
                .parse::<i64>()
                .map(Number::Int)
                .map_err(|_| format!("integer literal `{token}` is outside int64")),
        );
    }

    if valid_float(unsigned) {
        return Some(
            token
                .parse::<f64>()
                .map_err(|_| format!("invalid float literal `{token}`"))
                .and_then(|value| {
                    if value.is_finite() {
                        Ok(Number::Float(value))
                    } else {
                        Err(format!("float literal `{token}` is outside float64"))
                    }
                }),
        );
    }
    None
}

/// `inf`/`+inf`/`-inf` are float literals (whole-token, like `0x` hex); the
/// names leave the word namespace. NaN has no literal — it does not exist.
fn classify_inf(token: &str) -> Option<f64> {
    match token {
        "inf" | "+inf" => Some(f64::INFINITY),
        "-inf" => Some(f64::NEG_INFINITY),
        _ => None,
    }
}

fn looks_like_number(token: &str) -> bool {
    token
        .strip_prefix(['+', '-'])
        .unwrap_or(token)
        .chars()
        .next()
        .is_some_and(|character| character.is_ascii_digit())
}

fn valid_decimal_int(token: &str) -> bool {
    let mut previous_digit = false;
    let mut any = false;
    for character in token.chars() {
        if character.is_ascii_digit() {
            any = true;
            previous_digit = true;
        } else if character == '_' && previous_digit {
            previous_digit = false;
        } else {
            return false;
        }
    }
    any && previous_digit
}

fn valid_float(token: &str) -> bool {
    if token.contains('_') {
        return false;
    }
    let (mantissa, exponent) = match token.find(['e', 'E']) {
        Some(index) => (&token[..index], Some(&token[index + 1..])),
        None => (token, None),
    };
    if token.matches(['e', 'E']).count() > 1 {
        return false;
    }
    if let Some(exponent) = exponent {
        let digits = exponent.strip_prefix(['+', '-']).unwrap_or(exponent);
        if digits.is_empty() || !digits.chars().all(|character| character.is_ascii_digit()) {
            return false;
        }
    }
    let mantissa_ok = if let Some(dot) = mantissa.find('.') {
        !mantissa[..dot].is_empty()
            && !mantissa[dot + 1..].is_empty()
            && mantissa.matches('.').count() == 1
            && mantissa[..dot]
                .chars()
                .all(|character| character.is_ascii_digit())
            && mantissa[dot + 1..]
                .chars()
                .all(|character| character.is_ascii_digit())
    } else {
        mantissa.chars().all(|character| character.is_ascii_digit())
    };
    mantissa_ok && (mantissa.contains('.') || exponent.is_some())
}

fn decode_codepoint(digits: &str) -> Result<char, String> {
    if digits.is_empty() || digits.len() > 6 {
        return Err("a Unicode escape needs one to six hexadecimal digits".to_owned());
    }
    let codepoint = u32::from_str_radix(digits, 16)
        .map_err(|_| "a Unicode escape contains a non-hexadecimal digit".to_owned())?;
    char::from_u32(codepoint)
        .ok_or_else(|| format!("U+{codepoint:04X} is not a Unicode scalar value"))
}

/// Lower a binder using only ordinary point-free stack/list words.
///
/// The input values are first packed into `[lo ... hi]`, kept at the top of
/// the stack, and every ordinary body form runs beneath that list with `dip`.
/// A local reference becomes `dup <index> at swap`, which copies the bound
/// value beneath the protected list. The final `pop` removes the locals list.
fn lower_binder(
    names: Vec<Arc<str>>,
    body: Vec<Value>,
    span: &SourceSpan,
) -> Result<Vec<Value>, EclError> {
    for form in &body {
        if let ValueKind::List(_) | ValueKind::Dict(_) = &form.kind
            && let Some(name) = nested_local_reference(form, &names)
        {
            return Err(EclError::parse(
                format!(
                    "local `{name}` crosses a quotation boundary; capture it explicitly with `cons`"
                ),
                form.span.clone().or_else(|| Some(span.clone())),
            ));
        }
    }

    let generated = |kind| Value::at(kind, span.clone());
    let mut lowered = Vec::new();
    lowered.push(generated(ValueKind::List(Arc::from(Vec::<Value>::new()))));
    for _ in &names {
        lowered.push(generated(ValueKind::Word(Arc::from("cons"))));
    }
    for form in body {
        if let ValueKind::Word(word) = &form.kind
            && let Some(index) = names.iter().position(|name| name == word)
        {
            lowered.push(generated(ValueKind::Word(Arc::from("dup"))));
            lowered.push(generated(ValueKind::Int(index as i64)));
            lowered.push(generated(ValueKind::Word(Arc::from("at"))));
            lowered.push(generated(ValueKind::Word(Arc::from("swap"))));
            continue;
        }
        lowered.push(generated(ValueKind::List(Arc::from(vec![form]))));
        lowered.push(generated(ValueKind::Word(Arc::from("dip"))));
    }
    lowered.push(generated(ValueKind::Word(Arc::from("pop"))));
    Ok(lowered)
}

fn nested_local_reference<'a>(value: &'a Value, names: &'a [Arc<str>]) -> Option<&'a str> {
    match &value.kind {
        ValueKind::Word(word) if names.iter().any(|name| name == word) => Some(word),
        ValueKind::List(values) => values
            .iter()
            .find_map(|value| nested_local_reference(value, names)),
        ValueKind::Dict(entries) => entries.iter().find_map(|(key, value)| {
            nested_local_reference(key, names).or_else(|| nested_local_reference(value, names))
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(source: &str) -> Vec<Value> {
        Reader::new("test").read(source).unwrap()
    }

    #[test]
    fn reads_atoms_comments_commas_and_matched_lists() {
        let forms = read("1, -2 0x10 3.5 2e3 # hi\n [\\a 'x \"ok\"]");
        assert_eq!(forms.len(), 6);
        assert_eq!(forms[0].canonical(), "1");
        assert_eq!(forms[1].canonical(), "-2");
        assert_eq!(forms[2].canonical(), "16");
        assert_eq!(forms[3].canonical(), "3.5");
        assert_eq!(forms[4].canonical(), "2000.0");
        assert_eq!(forms[5].canonical(), "(\\a 'x \"ok\")");
    }

    #[test]
    fn reads_unicode_codepoint_escapes() {
        let forms = read(r#"\u{1f642} "\u{03bb}""#);
        assert!(matches!(forms[0].kind, ValueKind::Char('🙂')));
        assert!(matches!(&forms[1].kind, ValueKind::String(value) if value.as_ref() == "λ"));
    }

    #[test]
    fn dicts_desugar_to_two_forms() {
        let forms = read("{'answer 40 2 +}");
        assert_eq!(forms.len(), 2);
        assert_eq!(forms[0].canonical(), "('answer 40 2 +)");
        assert_eq!(forms[1].canonical(), "dict-of");
    }

    #[test]
    fn binder_lowers_to_point_free_code() {
        let forms = read("(|x| x x *)");
        let quotation = &forms[0];
        assert_eq!(
            quotation.canonical(),
            "([] cons dup 0 at swap dup 0 at swap (*) dip pop)"
        );
    }

    #[test]
    fn reports_incomplete_input_for_repl_continuation() {
        assert!(matches!(
            Reader::new("<repl>").read_status("1 (2").unwrap(),
            ReadStatus::Incomplete { .. }
        ));
    }

    #[test]
    fn rejects_mismatched_delimiters_and_crossing_locals() {
        assert!(Reader::new("test").read("[1 2)").is_err());
        assert!(Reader::new("test").read("(|x| (x))").is_err());
        assert!(Reader::new("test").read("9223372036854775808").is_err());
    }
}
