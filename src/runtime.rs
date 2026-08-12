use std::cmp::Ordering;
use std::collections::HashMap;
use std::io::{self, Write};
use std::sync::Arc;

use crate::error::{EclError, ErrorKind};
use crate::reader::Reader;
use crate::value::{Value, ValueKind, rectangular_shape};

#[derive(Clone, Debug)]
enum Binding {
    Word(Arc<[Value]>),
    Value(Value),
}

/// A persistent ecl session: data stack, late-bound dictionary, and CLI args.
/// Each call to `run`/`run_forms` is one transactional stack unit. Binding and
/// IO effects intentionally survive a failed unit, as required by decision 7.
pub struct Runtime {
    stack: Vec<Value>,
    bindings: HashMap<Arc<str>, Binding>,
    arguments: Vec<Arc<str>>,
}

impl Default for Runtime {
    fn default() -> Self {
        Self::new()
    }
}

impl Runtime {
    pub fn new() -> Self {
        let mut runtime = Self {
            stack: Vec::new(),
            bindings: HashMap::new(),
            arguments: Vec::new(),
        };
        runtime.install_prelude();
        runtime
    }

    pub fn with_args(arguments: impl IntoIterator<Item = String>) -> Self {
        let mut runtime = Self::new();
        runtime.arguments = arguments.into_iter().map(Arc::<str>::from).collect();
        runtime
    }

    pub fn stack(&self) -> &[Value] {
        &self.stack
    }

    pub fn clear_stack(&mut self) {
        self.stack.clear();
    }

    pub fn stack_display(&self) -> String {
        self.stack
            .iter()
            .map(Value::canonical)
            .collect::<Vec<_>>()
            .join(" ")
    }

    pub fn run(&mut self, source_name: &str, source: &str) -> Result<(), EclError> {
        let forms = Reader::new(source_name)
            .read(source)
            .map_err(|failure| failure.0)?;
        self.run_forms(forms)
    }

    pub fn run_forms(&mut self, forms: Vec<Value>) -> Result<(), EclError> {
        let checkpoint = self.stack.clone();
        let result = Machine::new(self).run(Arc::from(forms));
        if result.is_err() {
            self.stack = checkpoint;
        }
        result
    }

    fn install_prelude(&mut self) {
        const PRELUDE: &[(&str, &str)] = &[
            ("nip", "(swap pop)"),
            ("when", "([] if)"),
            ("wrap", "([] cons)"),
            ("pair", "([] cons cons)"),
            ("last", "(dup len 1 - at)"),
            ("sort", "(dup grade at)"),
            ("sum", "(0 (+) fold)"),
            ("prod", "(1 (*) fold)"),
            ("mean", "(dup sum swap len /)"),
            ("print", "(prin \"\\n\" prin)"),
            ("inspect", "(dup pp)"),
            ("keep", "(over (call) dip)"),
            ("bi", "((keep) dip call)"),
            ("tri", "(((keep) dip keep) dip call)"),
            (
                "fail",
                "(wrap ('kind 'user 'msg) swap compose dict-of raise)",
            ),
            ("lines", "(slurp \"\\n\" split)"),
            (
                "find",
                "((match) cons each dup where swap len swap dup len 0 = (pop) (first nip) if)",
            ),
        ];
        for (name, source) in PRELUDE {
            let forms = Reader::new("<prelude>")
                .read(source)
                .expect("built-in prelude source must parse");
            let body = forms
                .into_iter()
                .next()
                .and_then(|value| match value.kind {
                    ValueKind::List(body) => Some(body),
                    _ => None,
                })
                .expect("built-in prelude entry must be one quotation");
            self.bindings.insert(Arc::from(*name), Binding::Word(body));
        }
    }
}

#[derive(Clone)]
enum Frame {
    Eval {
        code: Arc<[Value]>,
        next: usize,
        traced_word: Option<Arc<str>>,
    },
    Restore(Value),
    TraceEnd,
    WhileAfterCond {
        condition: Arc<[Value]>,
        body: Arc<[Value]>,
        base: usize,
    },
    WhileAfterBody {
        condition: Arc<[Value]>,
        body: Arc<[Value]>,
    },
    DictAfter {
        outer: Vec<Value>,
    },
    EachAfter {
        outer: Vec<Value>,
        items: Arc<[Value]>,
        quotation: Arc<[Value]>,
        index: usize,
        results: Vec<Value>,
    },
    Each2After {
        outer: Vec<Value>,
        left: Arc<[Value]>,
        right: Arc<[Value]>,
        quotation: Arc<[Value]>,
        index: usize,
        results: Vec<Value>,
    },
    ForAfter {
        outer: Vec<Value>,
        items: Arc<[Value]>,
        quotation: Arc<[Value]>,
        index: usize,
    },
    FoldAfter {
        outer: Vec<Value>,
        items: Arc<[Value]>,
        quotation: Arc<[Value]>,
        index: usize,
        scan_results: Option<Vec<Value>>,
    },
    AttemptAfter {
        outer: Vec<Value>,
        trace_depth: usize,
    },
}

struct Machine<'runtime> {
    runtime: &'runtime mut Runtime,
    frames: Vec<Frame>,
    trace: Vec<Arc<str>>,
}

impl<'runtime> Machine<'runtime> {
    fn new(runtime: &'runtime mut Runtime) -> Self {
        Self {
            runtime,
            frames: Vec::new(),
            trace: Vec::new(),
        }
    }

    fn run(mut self, code: Arc<[Value]>) -> Result<(), EclError> {
        self.schedule(code, None);
        while let Some(frame) = self.frames.pop() {
            let result = self.step(frame);
            if let Err(mut error) = result {
                if self.catch_attempt(&mut error) {
                    continue;
                }
                if error.trace.is_empty() {
                    error.attach_context(&self.trace, error.span.as_deref().cloned());
                }
                return Err(error);
            }
        }
        Ok(())
    }

    fn step(&mut self, frame: Frame) -> Result<(), EclError> {
        match frame {
            Frame::Eval {
                code,
                next,
                traced_word,
            } => {
                if next == code.len() {
                    if traced_word.is_some() {
                        self.trace.pop();
                    }
                    return Ok(());
                }
                let form = code[next].clone();
                let tail = next + 1 == code.len();
                if !tail {
                    self.frames.push(Frame::Eval {
                        code,
                        next: next + 1,
                        traced_word,
                    });
                    return self.execute(form);
                }

                let owns_trace = traced_word.is_some();
                let inherits_tail_trace =
                    !owns_trace && matches!(self.frames.last(), Some(Frame::TraceEnd));
                let calls_word = form.as_word().is_some_and(|word| {
                    matches!(self.runtime.bindings.get(word), Some(Binding::Word(_)))
                });

                if calls_word && (owns_trace || inherits_tail_trace) {
                    if inherits_tail_trace {
                        self.frames.pop();
                    }
                    self.trace.pop();
                    return self.execute(form);
                }

                if owns_trace {
                    let frame_base = self.frames.len();
                    let result = self.execute(form);
                    if result.is_ok() {
                        if self.frames.len() == frame_base {
                            self.trace.pop();
                        } else {
                            self.frames.insert(frame_base, Frame::TraceEnd);
                        }
                    }
                    result
                } else {
                    self.execute(form)
                }
            }
            Frame::Restore(value) => {
                self.runtime.stack.push(value);
                Ok(())
            }
            Frame::TraceEnd => {
                self.trace.pop();
                Ok(())
            }
            Frame::WhileAfterCond {
                condition,
                body,
                base,
            } => {
                if self.runtime.stack.len() != base + 1 {
                    return Err(contract_error(
                        "while condition",
                        "( ... -- ... bool )",
                        base,
                        self.runtime.stack.len(),
                    ));
                }
                let predicate = self.pop_bool("while")?;
                if predicate {
                    self.frames.push(Frame::WhileAfterBody {
                        condition,
                        body: body.clone(),
                    });
                    self.schedule(body, None);
                }
                Ok(())
            }
            Frame::WhileAfterBody { condition, body } => {
                let base = self.runtime.stack.len();
                self.frames.push(Frame::WhileAfterCond {
                    condition: condition.clone(),
                    body,
                    base,
                });
                self.schedule(condition, None);
                Ok(())
            }
            Frame::DictAfter { outer } => self.finish_dict(outer),
            Frame::EachAfter {
                outer,
                items,
                quotation,
                index,
                results,
            } => self.finish_each(outer, items, quotation, index, results),
            Frame::Each2After {
                outer,
                left,
                right,
                quotation,
                index,
                results,
            } => self.finish_each2(outer, left, right, quotation, index, results),
            Frame::ForAfter {
                outer,
                items,
                quotation,
                index,
            } => self.finish_for(outer, items, quotation, index),
            Frame::FoldAfter {
                outer,
                items,
                quotation,
                index,
                scan_results,
            } => self.finish_fold(outer, items, quotation, index, scan_results),
            Frame::AttemptAfter { outer, .. } => {
                let results = std::mem::take(&mut self.runtime.stack);
                self.runtime.stack = outer;
                self.runtime.stack.push(ok_outcome(results));
                Ok(())
            }
        }
    }

    fn schedule(&mut self, code: Arc<[Value]>, traced_word: Option<Arc<str>>) {
        self.frames.push(Frame::Eval {
            code,
            next: 0,
            traced_word,
        });
    }

    fn execute(&mut self, form: Value) -> Result<(), EclError> {
        let ValueKind::Word(word) = &form.kind else {
            self.runtime.stack.push(form);
            return Ok(());
        };
        let word = word.clone();
        let span = form.span.clone();

        if let Some(binding) = self.runtime.bindings.get(&word).cloned() {
            match binding {
                Binding::Value(value) => self.runtime.stack.push(value),
                Binding::Word(body) => {
                    self.trace.push(word.clone());
                    self.schedule(body, Some(word));
                }
            }
            return Ok(());
        }

        self.trace.push(word.clone());
        let mut result = self.primitive(&word);
        if let Err(error) = &mut result {
            error.attach_context(&self.trace, span);
        }
        self.trace.pop();
        result
    }

    fn primitive(&mut self, word: &str) -> Result<(), EclError> {
        match word {
            "dup" => self.dup(),
            "swap" => self.swap(),
            "pop" => self.pop_word(),
            "over" => self.over(),
            "dip" => self.dip(),
            "call" => self.call(),
            "cons" => self.cons(),
            "compose" => self.compose(),
            "if" => self.if_word(),
            "while" => self.while_word(),
            "def" => self.define(true),
            "let" => self.define(false),
            "body" => self.body(),
            "words" => self.words(),
            "to-word" => self.coerce_word(),
            "to-symbol" => self.coerce_symbol(),
            "parse" => self.parse(),
            "str" => self.str_word(),
            "+" => self.binary_pervasive(BinaryOp::Add, "+"),
            "-" => self.binary_pervasive(BinaryOp::Sub, "-"),
            "*" => self.binary_pervasive(BinaryOp::Mul, "*"),
            "/" => self.binary_pervasive(BinaryOp::Div, "/"),
            "div" => self.binary_pervasive(BinaryOp::IntDiv, "div"),
            "mod" => self.binary_pervasive(BinaryOp::Mod, "mod"),
            "pow" => self.binary_pervasive(BinaryOp::Pow, "pow"),
            "min" => self.binary_pervasive(BinaryOp::Min, "min"),
            "max" => self.binary_pervasive(BinaryOp::Max, "max"),
            "=" => self.binary_pervasive(BinaryOp::Eq, "="),
            "<>" => self.binary_pervasive(BinaryOp::Ne, "<>"),
            "<" => self.binary_pervasive(BinaryOp::Lt, "<"),
            ">" => self.binary_pervasive(BinaryOp::Gt, ">"),
            "<=" => self.binary_pervasive(BinaryOp::Le, "<="),
            ">=" => self.binary_pervasive(BinaryOp::Ge, ">="),
            "and" => self.binary_pervasive(BinaryOp::And, "and"),
            "or" => self.binary_pervasive(BinaryOp::Or, "or"),
            "neg" => self.unary_pervasive(UnaryOp::Neg, "neg"),
            "abs" => self.unary_pervasive(UnaryOp::Abs, "abs"),
            "sqrt" => self.unary_pervasive(UnaryOp::Sqrt, "sqrt"),
            "floor" => self.unary_pervasive(UnaryOp::Floor, "floor"),
            "ceil" => self.unary_pervasive(UnaryOp::Ceil, "ceil"),
            "round" => self.unary_pervasive(UnaryOp::Round, "round"),
            "not" => self.unary_pervasive(UnaryOp::Not, "not"),
            "match" => self.match_word(),
            "len" => self.len(),
            "shape" => self.shape(),
            "first" => self.first(),
            "rest" => self.rest(),
            "take" => self.take(),
            "drop" => self.drop_sequence(),
            "at" => self.at(),
            "where" => self.where_word(),
            "in" => self.in_word(),
            "raze" => self.raze(),
            "cat" => self.cat(),
            "reverse" => self.reverse(),
            "range" => self.range(),
            "grade" => self.grade(),
            "distinct" => self.distinct(),
            "dict-of" => self.dict_of(),
            "keys" => self.keys(),
            "vals" => self.vals(),
            "put" => self.put(),
            "del" => self.del(),
            "merge" => self.merge(),
            "has?" => self.has(),
            "each" => self.each(),
            "each2" => self.each2(),
            "for" => self.for_word(),
            "fold" => self.fold(false),
            "scan" => self.fold(true),
            "split" => self.split(),
            "join" => self.join(),
            "format" => self.format(),
            "raise" => self.raise(),
            "attempt" => self.attempt(),
            "ok?" => self.ok(),
            "ok!" => self.ok_bang(),
            "or-else" => self.or_else(),
            "prin" => self.prin(),
            "pp" => self.pp(),
            "slurp" => self.slurp(),
            "spit" => self.spit(),
            "args" => self.args(),
            _ => Err(
                EclError::new(ErrorKind::UndefinedWord, format!("undefined word `{word}`"))
                    .with_data("name", Value::symbol(Arc::from(word))),
            ),
        }
    }

    fn catch_attempt(&mut self, error: &mut EclError) -> bool {
        let Some(index) = self
            .frames
            .iter()
            .rposition(|frame| matches!(frame, Frame::AttemptAfter { .. }))
        else {
            return false;
        };
        let Frame::AttemptAfter { outer, trace_depth } = self.frames.remove(index) else {
            unreachable!()
        };
        self.frames.truncate(index);
        self.trace.truncate(trace_depth);
        self.runtime.stack = outer;
        self.runtime.stack.push(err_outcome(error.to_value()));
        true
    }

    fn require(&self, count: usize, word: &str) -> Result<(), EclError> {
        if self.runtime.stack.len() >= count {
            Ok(())
        } else {
            Err(EclError::new(
                ErrorKind::Underflow,
                format!(
                    "{word} needs {count} stack value{}, but found {}",
                    if count == 1 { "" } else { "s" },
                    self.runtime.stack.len()
                ),
            )
            .with_data("needed", Value::int(count as i64))
            .with_data("available", Value::int(self.runtime.stack.len() as i64)))
        }
    }

    fn pop(&mut self, word: &str) -> Result<Value, EclError> {
        self.require(1, word)?;
        Ok(self.runtime.stack.pop().expect("required one value"))
    }

    fn pop_list(&mut self, word: &str) -> Result<Arc<[Value]>, EclError> {
        let value = self.pop(word)?;
        match value.kind {
            ValueKind::List(values) => Ok(values),
            _ => Err(type_error(word, "list", &value)),
        }
    }

    fn pop_symbol(&mut self, word: &str) -> Result<Arc<str>, EclError> {
        let value = self.pop(word)?;
        match value.kind {
            ValueKind::Symbol(symbol) => Ok(symbol),
            _ => Err(type_error(word, "symbol", &value)),
        }
    }

    fn pop_int(&mut self, word: &str) -> Result<i64, EclError> {
        let value = self.pop(word)?;
        match value.kind {
            ValueKind::Int(integer) => Ok(integer),
            _ => Err(type_error(word, "int", &value)),
        }
    }

    fn pop_bool(&mut self, word: &str) -> Result<bool, EclError> {
        let value = self.pop(word)?;
        match value.kind {
            ValueKind::Int(0) => Ok(false),
            ValueKind::Int(1) => Ok(true),
            _ => Err(EclError::new(
                ErrorKind::Type,
                format!("{word} expected a 0/1 bool, got {}", value.canonical()),
            )),
        }
    }

    fn pop_string(&mut self, word: &str) -> Result<Arc<str>, EclError> {
        let value = self.pop(word)?;
        match value.kind {
            ValueKind::String(string) => Ok(string),
            _ => Err(type_error(word, "string", &value)),
        }
    }

    fn dup(&mut self) -> Result<(), EclError> {
        self.require(1, "dup")?;
        let value = self
            .runtime
            .stack
            .last()
            .expect("required one value")
            .clone();
        self.runtime.stack.push(value);
        Ok(())
    }

    fn swap(&mut self) -> Result<(), EclError> {
        self.require(2, "swap")?;
        let length = self.runtime.stack.len();
        self.runtime.stack.swap(length - 1, length - 2);
        Ok(())
    }

    fn pop_word(&mut self) -> Result<(), EclError> {
        self.pop("pop")?;
        Ok(())
    }

    fn over(&mut self) -> Result<(), EclError> {
        self.require(2, "over")?;
        let value = self.runtime.stack[self.runtime.stack.len() - 2].clone();
        self.runtime.stack.push(value);
        Ok(())
    }

    fn dip(&mut self) -> Result<(), EclError> {
        self.require(2, "dip")?;
        let quotation = self.pop_list("dip")?;
        let protected = self.pop("dip")?;
        self.frames.push(Frame::Restore(protected));
        self.schedule(quotation, None);
        Ok(())
    }

    fn call(&mut self) -> Result<(), EclError> {
        // Vector ⊂ Quotation, literally: any list-like value applies. A data
        // list unstacks its elements; a string pushes its chars.
        let value = self.pop("call")?;
        let quotation: Arc<[Value]> = match &value.kind {
            ValueKind::List(values) => values.clone(),
            ValueKind::String(_) => Arc::from(try_sequence(&value).expect("string sequences")),
            _ => return Err(type_error("call", "list", &value)),
        };
        self.schedule(quotation, None);
        Ok(())
    }

    fn coerce_word(&mut self) -> Result<(), EclError> {
        let value = self.pop("to-word")?;
        match &value.kind {
            ValueKind::Symbol(name) | ValueKind::Word(name) => {
                self.runtime.stack.push(Value::word(name.clone()));
                Ok(())
            }
            _ => Err(type_error("to-word", "symbol or word", &value)),
        }
    }

    fn coerce_symbol(&mut self) -> Result<(), EclError> {
        let value = self.pop("to-symbol")?;
        match &value.kind {
            ValueKind::Symbol(name) | ValueKind::Word(name) => {
                self.runtime.stack.push(Value::symbol(name.clone()));
                Ok(())
            }
            _ => Err(type_error("to-symbol", "symbol or word", &value)),
        }
    }

    fn cons(&mut self) -> Result<(), EclError> {
        self.require(2, "cons")?;
        let list_value = self.pop("cons")?;
        let list =
            try_sequence(&list_value).ok_or_else(|| type_error("cons", "list", &list_value))?;
        let value = self.pop("cons")?;
        let mut result = Vec::with_capacity(list.len() + 1);
        result.push(value);
        result.extend(list);
        self.runtime.stack.push(Value::list(result));
        Ok(())
    }

    fn compose(&mut self) -> Result<(), EclError> {
        self.require(2, "compose")?;
        let right = self.pop_list("compose")?;
        let left = self.pop_list("compose")?;
        let mut result = Vec::with_capacity(left.len() + right.len());
        result.extend(left.iter().cloned());
        result.extend(right.iter().cloned());
        self.runtime.stack.push(Value::list(result));
        Ok(())
    }

    fn if_word(&mut self) -> Result<(), EclError> {
        self.require(3, "if")?;
        let otherwise = self.pop_list("if")?;
        let then = self.pop_list("if")?;
        let predicate = self.pop_bool("if")?;
        self.schedule(if predicate { then } else { otherwise }, None);
        Ok(())
    }

    fn while_word(&mut self) -> Result<(), EclError> {
        self.require(2, "while")?;
        let body = self.pop_list("while")?;
        let condition = self.pop_list("while")?;
        let base = self.runtime.stack.len();
        self.frames.push(Frame::WhileAfterCond {
            condition: condition.clone(),
            body,
            base,
        });
        self.schedule(condition, None);
        Ok(())
    }

    fn define(&mut self, word_binding: bool) -> Result<(), EclError> {
        let operation = if word_binding { "def" } else { "let" };
        self.require(2, operation)?;
        let name = self.pop_symbol(operation)?;
        let value = self.pop(operation)?;
        let binding = if word_binding {
            let ValueKind::List(body) = value.kind else {
                return Err(type_error(operation, "list body", &value));
            };
            Binding::Word(body)
        } else {
            Binding::Value(value)
        };
        self.runtime.bindings.insert(name, binding);
        Ok(())
    }

    fn body(&mut self) -> Result<(), EclError> {
        let name = self.pop_symbol("body")?;
        match self.runtime.bindings.get(&name) {
            Some(Binding::Word(body)) => {
                self.runtime.stack.push(Value::list(body.to_vec()));
                Ok(())
            }
            Some(Binding::Value(_)) => Err(EclError::new(
                ErrorKind::Type,
                format!("'{name} is a value binding, not a word"),
            )),
            None => Err(EclError::new(
                ErrorKind::UndefinedWord,
                format!("undefined word `{name}`"),
            )),
        }
    }

    fn words(&mut self) -> Result<(), EclError> {
        let mut names = core_words()
            .iter()
            .map(|name| (*name).to_owned())
            .chain(self.runtime.bindings.keys().map(ToString::to_string))
            .collect::<Vec<_>>();
        names.sort();
        names.dedup();
        let rendered = names.join(" ");
        writeln!(io::stdout(), "{rendered}").map_err(io_error)
    }

    fn parse(&mut self) -> Result<(), EclError> {
        let source = self.pop_string("parse")?;
        let forms = Reader::new("<parse>")
            .read(&source)
            .map_err(|failure| failure.0)?;
        self.runtime.stack.push(Value::list(forms));
        Ok(())
    }

    fn str_word(&mut self) -> Result<(), EclError> {
        let value = self.pop("str")?;
        self.runtime.stack.push(Value::string(value.canonical()));
        Ok(())
    }

    fn binary_pervasive(&mut self, operation: BinaryOp, word: &str) -> Result<(), EclError> {
        self.require(2, word)?;
        let right = self.pop(word)?;
        let left = self.pop(word)?;
        self.runtime
            .stack
            .push(pervade_binary(&left, &right, operation)?);
        Ok(())
    }

    fn unary_pervasive(&mut self, operation: UnaryOp, word: &str) -> Result<(), EclError> {
        let value = self.pop(word)?;
        self.runtime.stack.push(pervade_unary(&value, operation)?);
        Ok(())
    }

    fn match_word(&mut self) -> Result<(), EclError> {
        self.require(2, "match")?;
        let right = self.pop("match")?;
        let left = self.pop("match")?;
        self.runtime
            .stack
            .push(Value::int(i64::from(left.structurally_eq(&right))));
        Ok(())
    }

    fn len(&mut self) -> Result<(), EclError> {
        let value = self.pop("len")?;
        let length = match &value.kind {
            ValueKind::List(values) => values.len(),
            ValueKind::String(string) => string.chars().count(),
            _ => return Err(type_error("len", "list", &value)),
        };
        self.runtime.stack.push(Value::int(length as i64));
        Ok(())
    }

    fn shape(&mut self) -> Result<(), EclError> {
        let value = self.pop("shape")?;
        let shape = match &value.kind {
            ValueKind::String(string) => vec![string.chars().count()],
            ValueKind::List(_) => rectangular_shape(&value).ok_or_else(|| {
                EclError::new(ErrorKind::Shape, "shape requires a rectangular list")
            })?,
            _ => return Err(type_error("shape", "list", &value)),
        };
        self.runtime.stack.push(Value::list(
            shape
                .into_iter()
                .map(|size| Value::int(size as i64))
                .collect::<Vec<_>>(),
        ));
        Ok(())
    }

    fn first(&mut self) -> Result<(), EclError> {
        let value = self.pop("first")?;
        let result = match &value.kind {
            ValueKind::List(values) => values.first().cloned(),
            ValueKind::String(string) => string.chars().next().map(Value::char),
            _ => return Err(type_error("first", "list", &value)),
        }
        .ok_or_else(|| EclError::new(ErrorKind::Domain, "first requires a non-empty list"))?;
        self.runtime.stack.push(result);
        Ok(())
    }

    fn rest(&mut self) -> Result<(), EclError> {
        let value = self.pop("rest")?;
        let result = match &value.kind {
            ValueKind::List(values) => {
                if values.is_empty() {
                    return Err(EclError::new(
                        ErrorKind::Domain,
                        "rest requires a non-empty list",
                    ));
                }
                Value::list(values[1..].to_vec())
            }
            ValueKind::String(string) => {
                if string.is_empty() {
                    return Err(EclError::new(
                        ErrorKind::Domain,
                        "rest requires a non-empty string",
                    ));
                }
                Value::string(string.chars().skip(1).collect::<String>())
            }
            _ => return Err(type_error("rest", "list", &value)),
        };
        self.runtime.stack.push(result);
        Ok(())
    }

    fn take(&mut self) -> Result<(), EclError> {
        self.require(2, "take")?;
        let count = self.pop_int("take")?;
        let sequence = self.pop("take")?;
        self.runtime
            .stack
            .push(slice_sequence(&sequence, count, true)?);
        Ok(())
    }

    fn drop_sequence(&mut self) -> Result<(), EclError> {
        self.require(2, "drop")?;
        let count = self.pop_int("drop")?;
        let sequence = self.pop("drop")?;
        self.runtime
            .stack
            .push(slice_sequence(&sequence, count, false)?);
        Ok(())
    }

    fn at(&mut self) -> Result<(), EclError> {
        self.require(2, "at")?;
        let index = self.pop("at")?;
        let collection = self.pop("at")?;
        self.runtime.stack.push(index_value(&collection, &index)?);
        Ok(())
    }

    fn where_word(&mut self) -> Result<(), EclError> {
        let mask = self.pop("where")?;
        let items = sequence(&mask, "where")?;
        let mut indices = Vec::new();
        for (index, item) in items.iter().enumerate() {
            match item.kind {
                ValueKind::Int(0) => {}
                ValueKind::Int(1) => indices.push(Value::int(index as i64)),
                _ => {
                    return Err(EclError::new(
                        ErrorKind::Type,
                        format!(
                            "where expected a 0/1 mask; element {index} is {}",
                            item.canonical()
                        ),
                    ));
                }
            }
        }
        self.runtime.stack.push(Value::list(indices));
        Ok(())
    }

    fn in_word(&mut self) -> Result<(), EclError> {
        self.require(2, "in")?;
        let collection = self.pop("in")?;
        let needle = self.pop("in")?;
        let items = sequence(&collection, "in")?;
        self.runtime.stack.push(membership(&needle, &items));
        Ok(())
    }

    fn raze(&mut self) -> Result<(), EclError> {
        let list = self.pop_list("raze")?;
        let mut result = Vec::new();
        for value in list.iter() {
            match &value.kind {
                ValueKind::List(values) => result.extend(values.iter().cloned()),
                ValueKind::String(string) => result.extend(string.chars().map(Value::char)),
                _ => result.push(value.clone()),
            }
        }
        self.runtime.stack.push(Value::list(result));
        Ok(())
    }

    fn cat(&mut self) -> Result<(), EclError> {
        self.require(2, "cat")?;
        let right = self.pop("cat")?;
        let left = self.pop("cat")?;
        let result = match (&left.kind, &right.kind) {
            (ValueKind::List(left), ValueKind::List(right)) => {
                let mut values = Vec::with_capacity(left.len() + right.len());
                values.extend(left.iter().cloned());
                values.extend(right.iter().cloned());
                Value::list(values)
            }
            (ValueKind::String(left), ValueKind::String(right)) => {
                Value::string(format!("{left}{right}"))
            }
            _ => {
                return Err(EclError::new(
                    ErrorKind::Type,
                    "cat expected two lists (or two strings)",
                ));
            }
        };
        self.runtime.stack.push(result);
        Ok(())
    }

    fn reverse(&mut self) -> Result<(), EclError> {
        let value = self.pop("reverse")?;
        let result = match &value.kind {
            ValueKind::List(values) => {
                Value::list(values.iter().rev().cloned().collect::<Vec<_>>())
            }
            ValueKind::String(string) => Value::string(string.chars().rev().collect::<String>()),
            _ => return Err(type_error("reverse", "list", &value)),
        };
        self.runtime.stack.push(result);
        Ok(())
    }

    fn range(&mut self) -> Result<(), EclError> {
        let count = self.pop_int("range")?;
        if count < 0 {
            return Err(EclError::new(
                ErrorKind::Domain,
                "range requires a non-negative int",
            ));
        }
        self.runtime
            .stack
            .push(Value::list((0..count).map(Value::int).collect::<Vec<_>>()));
        Ok(())
    }

    fn grade(&mut self) -> Result<(), EclError> {
        let value = self.pop("grade")?;
        let items = sequence(&value, "grade")?;
        let mut indices = (0..items.len()).collect::<Vec<_>>();
        let mut failure = None;
        indices.sort_by(
            |left, right| match compare_scalars(&items[*left], &items[*right]) {
                Ok(ordering) => ordering,
                Err(error) => {
                    failure = Some(error);
                    Ordering::Equal
                }
            },
        );
        if let Some(error) = failure {
            return Err(error);
        }
        self.runtime.stack.push(Value::list(
            indices
                .into_iter()
                .map(|index| Value::int(index as i64))
                .collect::<Vec<_>>(),
        ));
        Ok(())
    }

    fn distinct(&mut self) -> Result<(), EclError> {
        let value = self.pop("distinct")?;
        let items = sequence(&value, "distinct")?;
        let mut result: Vec<Value> = Vec::new();
        for item in items {
            if !result.iter().any(|known| known.structurally_eq(&item)) {
                result.push(item);
            }
        }
        self.runtime.stack.push(Value::list(result));
        Ok(())
    }

    fn dict_of(&mut self) -> Result<(), EclError> {
        let quotation = self.pop_list("dict-of")?;
        let outer = std::mem::take(&mut self.runtime.stack);
        self.frames.push(Frame::DictAfter { outer });
        self.schedule(quotation, None);
        Ok(())
    }

    fn finish_dict(&mut self, outer: Vec<Value>) -> Result<(), EclError> {
        if !self.runtime.stack.len().is_multiple_of(2) {
            return Err(contract_error(
                "dict-of quotation",
                "an even number of results",
                0,
                self.runtime.stack.len(),
            ));
        }
        let results = std::mem::take(&mut self.runtime.stack);
        let mut entries: Vec<(Value, Value)> = Vec::with_capacity(results.len() / 2);
        for pair in results.chunks_exact(2) {
            if entries.iter().any(|(key, _)| key.structurally_eq(&pair[0])) {
                return Err(EclError::new(
                    ErrorKind::Domain,
                    format!("duplicate dict key {}", pair[0].canonical()),
                ));
            }
            entries.push((pair[0].clone(), pair[1].clone()));
        }
        self.runtime.stack = outer;
        self.runtime.stack.push(Value::dict(entries));
        Ok(())
    }

    fn keys(&mut self) -> Result<(), EclError> {
        let value = self.pop("keys")?;
        let Some(entries) = value.as_dict() else {
            return Err(type_error("keys", "dict", &value));
        };
        self.runtime.stack.push(Value::list(
            entries
                .iter()
                .map(|(key, _)| key.clone())
                .collect::<Vec<_>>(),
        ));
        Ok(())
    }

    fn vals(&mut self) -> Result<(), EclError> {
        let value = self.pop("vals")?;
        let Some(entries) = value.as_dict() else {
            return Err(type_error("vals", "dict", &value));
        };
        self.runtime.stack.push(Value::list(
            entries
                .iter()
                .map(|(_, value)| value.clone())
                .collect::<Vec<_>>(),
        ));
        Ok(())
    }

    fn put(&mut self) -> Result<(), EclError> {
        self.require(3, "put")?;
        let new_value = self.pop("put")?;
        let key = self.pop("put")?;
        let dict = self.pop("put")?;
        let Some(entries) = dict.as_dict() else {
            return Err(type_error("put", "dict", &dict));
        };
        let mut result = entries.to_vec();
        if let Some((_, value)) = result
            .iter_mut()
            .find(|(known, _)| known.structurally_eq(&key))
        {
            *value = new_value;
        } else {
            result.push((key, new_value));
        }
        self.runtime.stack.push(Value::dict(result));
        Ok(())
    }

    fn del(&mut self) -> Result<(), EclError> {
        self.require(2, "del")?;
        let key = self.pop("del")?;
        let dict = self.pop("del")?;
        let Some(entries) = dict.as_dict() else {
            return Err(type_error("del", "dict", &dict));
        };
        self.runtime.stack.push(Value::dict(
            entries
                .iter()
                .filter(|(known, _)| !known.structurally_eq(&key))
                .cloned()
                .collect::<Vec<_>>(),
        ));
        Ok(())
    }

    fn merge(&mut self) -> Result<(), EclError> {
        self.require(2, "merge")?;
        let right = self.pop("merge")?;
        let left = self.pop("merge")?;
        let (Some(left), Some(right)) = (left.as_dict(), right.as_dict()) else {
            return Err(EclError::new(ErrorKind::Type, "merge expected two dicts"));
        };
        let mut result = left.to_vec();
        for (key, value) in right {
            if let Some((_, old)) = result
                .iter_mut()
                .find(|(known, _)| known.structurally_eq(key))
            {
                *old = value.clone();
            } else {
                result.push((key.clone(), value.clone()));
            }
        }
        self.runtime.stack.push(Value::dict(result));
        Ok(())
    }

    fn has(&mut self) -> Result<(), EclError> {
        self.require(2, "has?")?;
        let key = self.pop("has?")?;
        let dict = self.pop("has?")?;
        let Some(entries) = dict.as_dict() else {
            return Err(type_error("has?", "dict", &dict));
        };
        self.runtime.stack.push(Value::int(i64::from(
            entries.iter().any(|(known, _)| known.structurally_eq(&key)),
        )));
        Ok(())
    }

    fn each(&mut self) -> Result<(), EclError> {
        self.require(2, "each")?;
        let quotation = self.pop_list("each")?;
        let value = self.pop("each")?;
        let items: Arc<[Value]> = Arc::from(sequence(&value, "each")?);
        let outer = std::mem::take(&mut self.runtime.stack);
        if items.is_empty() {
            self.runtime.stack = outer;
            self.runtime.stack.push(Value::list(Vec::new()));
            return Ok(());
        }
        self.runtime.stack.push(items[0].clone());
        self.frames.push(Frame::EachAfter {
            outer,
            items,
            quotation: quotation.clone(),
            index: 0,
            results: Vec::new(),
        });
        self.schedule(quotation, None);
        Ok(())
    }

    fn finish_each(
        &mut self,
        outer: Vec<Value>,
        items: Arc<[Value]>,
        quotation: Arc<[Value]>,
        index: usize,
        mut results: Vec<Value>,
    ) -> Result<(), EclError> {
        if self.runtime.stack.len() != 1 {
            return Err(contract_error(
                &format!("each quotation at element {index}"),
                "( a -- b )",
                1,
                self.runtime.stack.len(),
            ));
        }
        results.push(self.runtime.stack.pop().expect("checked one result"));
        let next = index + 1;
        if next == items.len() {
            self.runtime.stack = outer;
            self.runtime.stack.push(Value::list(results));
            return Ok(());
        }
        self.runtime.stack.push(items[next].clone());
        self.frames.push(Frame::EachAfter {
            outer,
            items,
            quotation: quotation.clone(),
            index: next,
            results,
        });
        self.schedule(quotation, None);
        Ok(())
    }

    fn each2(&mut self) -> Result<(), EclError> {
        self.require(3, "each2")?;
        let quotation = self.pop_list("each2")?;
        let right_value = self.pop("each2")?;
        let left_value = self.pop("each2")?;
        // Broadcast conformability (decisions 3, 14): an atom on either side
        // extends to the other side's length, exactly as it would under a
        // pervasive binary word.
        let (left, right): (Arc<[Value]>, Arc<[Value]>) =
            match (try_sequence(&left_value), try_sequence(&right_value)) {
                (Some(left), Some(right)) => {
                    if left.len() != right.len() {
                        return Err(EclError::new(
                            ErrorKind::Conform,
                            format!(
                                "each2 requires equal leading lengths; got {} and {}",
                                left.len(),
                                right.len()
                            ),
                        ));
                    }
                    (Arc::from(left), Arc::from(right))
                }
                (Some(left), None) => {
                    let right = vec![right_value.clone(); left.len()];
                    (Arc::from(left), Arc::from(right))
                }
                (None, Some(right)) => {
                    let left = vec![left_value.clone(); right.len()];
                    (Arc::from(left), Arc::from(right))
                }
                (None, None) => {
                    return Err(type_error("each2", "at least one list", &left_value));
                }
            };
        let outer = std::mem::take(&mut self.runtime.stack);
        if left.is_empty() {
            self.runtime.stack = outer;
            self.runtime.stack.push(Value::list(Vec::new()));
            return Ok(());
        }
        self.runtime.stack.push(left[0].clone());
        self.runtime.stack.push(right[0].clone());
        self.frames.push(Frame::Each2After {
            outer,
            left,
            right,
            quotation: quotation.clone(),
            index: 0,
            results: Vec::new(),
        });
        self.schedule(quotation, None);
        Ok(())
    }

    fn finish_each2(
        &mut self,
        outer: Vec<Value>,
        left: Arc<[Value]>,
        right: Arc<[Value]>,
        quotation: Arc<[Value]>,
        index: usize,
        mut results: Vec<Value>,
    ) -> Result<(), EclError> {
        if self.runtime.stack.len() != 1 {
            return Err(contract_error(
                &format!("each2 quotation at element {index}"),
                "( a b -- c )",
                2,
                self.runtime.stack.len(),
            ));
        }
        results.push(self.runtime.stack.pop().expect("checked one result"));
        let next = index + 1;
        if next == left.len() {
            self.runtime.stack = outer;
            self.runtime.stack.push(Value::list(results));
            return Ok(());
        }
        self.runtime.stack.push(left[next].clone());
        self.runtime.stack.push(right[next].clone());
        self.frames.push(Frame::Each2After {
            outer,
            left,
            right,
            quotation: quotation.clone(),
            index: next,
            results,
        });
        self.schedule(quotation, None);
        Ok(())
    }

    fn for_word(&mut self) -> Result<(), EclError> {
        self.require(2, "for")?;
        let quotation = self.pop_list("for")?;
        let value = self.pop("for")?;
        let items: Arc<[Value]> = Arc::from(sequence(&value, "for")?);
        let outer = std::mem::take(&mut self.runtime.stack);
        if items.is_empty() {
            self.runtime.stack = outer;
            return Ok(());
        }
        self.runtime.stack.push(items[0].clone());
        self.frames.push(Frame::ForAfter {
            outer,
            items,
            quotation: quotation.clone(),
            index: 0,
        });
        self.schedule(quotation, None);
        Ok(())
    }

    fn finish_for(
        &mut self,
        outer: Vec<Value>,
        items: Arc<[Value]>,
        quotation: Arc<[Value]>,
        index: usize,
    ) -> Result<(), EclError> {
        if !self.runtime.stack.is_empty() {
            return Err(contract_error(
                &format!("for quotation at element {index}"),
                "( a -- )",
                1,
                self.runtime.stack.len(),
            ));
        }
        let next = index + 1;
        if next == items.len() {
            self.runtime.stack = outer;
            return Ok(());
        }
        self.runtime.stack.push(items[next].clone());
        self.frames.push(Frame::ForAfter {
            outer,
            items,
            quotation: quotation.clone(),
            index: next,
        });
        self.schedule(quotation, None);
        Ok(())
    }

    fn fold(&mut self, scan: bool) -> Result<(), EclError> {
        let word = if scan { "scan" } else { "fold" };
        self.require(3, word)?;
        let quotation = self.pop_list(word)?;
        let accumulator = self.pop(word)?;
        let value = self.pop(word)?;
        let items: Arc<[Value]> = Arc::from(sequence(&value, word)?);
        let outer = std::mem::take(&mut self.runtime.stack);
        if items.is_empty() {
            self.runtime.stack = outer;
            self.runtime.stack.push(if scan {
                Value::list(Vec::new())
            } else {
                accumulator
            });
            return Ok(());
        }
        self.runtime.stack.push(accumulator);
        self.runtime.stack.push(items[0].clone());
        self.frames.push(Frame::FoldAfter {
            outer,
            items,
            quotation: quotation.clone(),
            index: 0,
            scan_results: scan.then(Vec::new),
        });
        self.schedule(quotation, None);
        Ok(())
    }

    fn finish_fold(
        &mut self,
        outer: Vec<Value>,
        items: Arc<[Value]>,
        quotation: Arc<[Value]>,
        index: usize,
        mut scan_results: Option<Vec<Value>>,
    ) -> Result<(), EclError> {
        if self.runtime.stack.len() != 1 {
            return Err(contract_error(
                &format!("fold/scan quotation at element {index}"),
                "( acc a -- acc )",
                2,
                self.runtime.stack.len(),
            ));
        }
        let accumulator = self.runtime.stack.pop().expect("checked one result");
        if let Some(results) = &mut scan_results {
            results.push(accumulator.clone());
        }
        let next = index + 1;
        if next == items.len() {
            self.runtime.stack = outer;
            self.runtime.stack.push(match scan_results {
                Some(results) => Value::list(results),
                None => accumulator,
            });
            return Ok(());
        }
        self.runtime.stack.push(accumulator);
        self.runtime.stack.push(items[next].clone());
        self.frames.push(Frame::FoldAfter {
            outer,
            items,
            quotation: quotation.clone(),
            index: next,
            scan_results,
        });
        self.schedule(quotation, None);
        Ok(())
    }

    fn split(&mut self) -> Result<(), EclError> {
        self.require(2, "split")?;
        let separator = self.pop_string("split")?;
        let string = self.pop_string("split")?;
        self.runtime.stack.push(Value::list(
            string
                .split(separator.as_ref())
                .map(Value::string)
                .collect::<Vec<_>>(),
        ));
        Ok(())
    }

    fn join(&mut self) -> Result<(), EclError> {
        self.require(2, "join")?;
        let separator = self.pop_string("join")?;
        let list = self.pop_list("join")?;
        let mut strings = Vec::with_capacity(list.len());
        for value in list.iter() {
            let ValueKind::String(string) = &value.kind else {
                return Err(type_error("join", "a list of strings", value));
            };
            strings.push(string.as_ref());
        }
        self.runtime
            .stack
            .push(Value::string(strings.join(separator.as_ref())));
        Ok(())
    }

    fn format(&mut self) -> Result<(), EclError> {
        self.require(2, "format")?;
        let template = self.pop_string("format")?;
        let values = self.pop_list("format")?;
        self.runtime
            .stack
            .push(Value::string(format_values(&values, &template)?));
        Ok(())
    }

    fn raise(&mut self) -> Result<(), EclError> {
        let value = self.pop("raise")?;
        Err(EclError::raised(&value)?)
    }

    fn attempt(&mut self) -> Result<(), EclError> {
        let quotation = self.pop_list("attempt")?;
        let outer = std::mem::take(&mut self.runtime.stack);
        self.frames.push(Frame::AttemptAfter {
            outer,
            trace_depth: self.trace.len().saturating_sub(1),
        });
        self.schedule(quotation, None);
        Ok(())
    }

    fn ok(&mut self) -> Result<(), EclError> {
        let outcome = self.pop("ok?")?;
        let entries = outcome
            .as_dict()
            .ok_or_else(|| type_error("ok?", "outcome dict", &outcome))?;
        self.runtime
            .stack
            .push(Value::int(i64::from(dict_lookup(entries, "ok").is_some())));
        Ok(())
    }

    fn ok_bang(&mut self) -> Result<(), EclError> {
        let outcome = self.pop("ok!")?;
        let entries = outcome
            .as_dict()
            .ok_or_else(|| type_error("ok!", "outcome dict", &outcome))?;
        if let Some(results) = dict_lookup(entries, "ok") {
            self.runtime.stack.push(results.clone());
            return Ok(());
        }
        if let Some(error) = dict_lookup(entries, "err") {
            return Err(EclError::raised(error)?);
        }
        Err(EclError::new(
            ErrorKind::Type,
            "ok! expected an outcome containing 'ok or 'err",
        ))
    }

    fn or_else(&mut self) -> Result<(), EclError> {
        self.require(2, "or-else")?;
        let fallback = self.pop("or-else")?;
        let outcome = self.pop("or-else")?;
        let entries = outcome
            .as_dict()
            .ok_or_else(|| type_error("or-else", "outcome dict", &outcome))?;
        self.runtime
            .stack
            .push(dict_lookup(entries, "ok").cloned().unwrap_or(fallback));
        Ok(())
    }

    fn prin(&mut self) -> Result<(), EclError> {
        let string = self.pop_string("prin")?;
        print!("{string}");
        io::stdout().flush().map_err(io_error)
    }

    fn pp(&mut self) -> Result<(), EclError> {
        let value = self.pop("pp")?;
        writeln!(io::stdout(), "{}", value.canonical()).map_err(io_error)
    }

    fn slurp(&mut self) -> Result<(), EclError> {
        let path = self.pop_string("slurp")?;
        let contents = std::fs::read_to_string(path.as_ref()).map_err(io_error)?;
        self.runtime.stack.push(Value::string(contents));
        Ok(())
    }

    fn spit(&mut self) -> Result<(), EclError> {
        self.require(2, "spit")?;
        let path = self.pop_string("spit")?;
        let contents = self.pop_string("spit")?;
        std::fs::write(path.as_ref(), contents.as_bytes()).map_err(io_error)
    }

    fn args(&mut self) -> Result<(), EclError> {
        self.runtime.stack.push(Value::list(
            self.runtime
                .arguments
                .iter()
                .cloned()
                .map(Value::string)
                .collect::<Vec<_>>(),
        ));
        Ok(())
    }
}

#[derive(Clone, Copy)]
enum BinaryOp {
    Add,
    Sub,
    Mul,
    Div,
    IntDiv,
    Mod,
    Pow,
    Min,
    Max,
    Eq,
    Ne,
    Lt,
    Gt,
    Le,
    Ge,
    And,
    Or,
}

#[derive(Clone, Copy)]
enum UnaryOp {
    Neg,
    Abs,
    Sqrt,
    Floor,
    Ceil,
    Round,
    Not,
}

fn pervade_binary(left: &Value, right: &Value, operation: BinaryOp) -> Result<Value, EclError> {
    match (&left.kind, &right.kind) {
        (ValueKind::List(left), ValueKind::List(right)) => {
            if left.len() != right.len() {
                return Err(conform_error(left.len(), right.len()));
            }
            Ok(Value::list(
                left.iter()
                    .zip(right.iter())
                    .map(|(left, right)| pervade_binary(left, right, operation))
                    .collect::<Result<Vec<_>, _>>()?,
            ))
        }
        (ValueKind::List(left), _) => Ok(Value::list(
            left.iter()
                .map(|left| pervade_binary(left, right, operation))
                .collect::<Result<Vec<_>, _>>()?,
        )),
        (_, ValueKind::List(right)) => Ok(Value::list(
            right
                .iter()
                .map(|right| pervade_binary(left, right, operation))
                .collect::<Result<Vec<_>, _>>()?,
        )),
        (ValueKind::String(left), ValueKind::String(right)) => {
            let left = left.chars().map(Value::char).collect::<Vec<_>>();
            let right = right.chars().map(Value::char).collect::<Vec<_>>();
            pervade_binary(&Value::list(left), &Value::list(right), operation)
        }
        (ValueKind::String(left), _) => Ok(Value::list(
            left.chars()
                .map(Value::char)
                .map(|left| pervade_binary(&left, right, operation))
                .collect::<Result<Vec<_>, _>>()?,
        )),
        (_, ValueKind::String(right)) => Ok(Value::list(
            right
                .chars()
                .map(Value::char)
                .map(|right| pervade_binary(left, &right, operation))
                .collect::<Result<Vec<_>, _>>()?,
        )),
        (ValueKind::Dict(left), ValueKind::Dict(right)) => {
            let mut entries = left.to_vec();
            for (key, right_value) in right.iter() {
                if let Some((_, left_value)) = entries
                    .iter_mut()
                    .find(|(known, _)| known.structurally_eq(key))
                {
                    *left_value = pervade_binary(left_value, right_value, operation)?;
                } else {
                    entries.push((key.clone(), right_value.clone()));
                }
            }
            Ok(Value::dict(entries))
        }
        (ValueKind::Dict(entries), _) => Ok(Value::dict(
            entries
                .iter()
                .map(|(key, value)| Ok((key.clone(), pervade_binary(value, right, operation)?)))
                .collect::<Result<Vec<_>, EclError>>()?,
        )),
        (_, ValueKind::Dict(entries)) => Ok(Value::dict(
            entries
                .iter()
                .map(|(key, value)| Ok((key.clone(), pervade_binary(left, value, operation)?)))
                .collect::<Result<Vec<_>, EclError>>()?,
        )),
        _ => scalar_binary(left, right, operation),
    }
}

fn pervade_unary(value: &Value, operation: UnaryOp) -> Result<Value, EclError> {
    match &value.kind {
        ValueKind::List(values) => Ok(Value::list(
            values
                .iter()
                .map(|value| pervade_unary(value, operation))
                .collect::<Result<Vec<_>, _>>()?,
        )),
        ValueKind::String(string) => Ok(Value::list(
            string
                .chars()
                .map(Value::char)
                .map(|value| pervade_unary(&value, operation))
                .collect::<Result<Vec<_>, _>>()?,
        )),
        ValueKind::Dict(entries) => Ok(Value::dict(
            entries
                .iter()
                .map(|(key, value)| Ok((key.clone(), pervade_unary(value, operation)?)))
                .collect::<Result<Vec<_>, EclError>>()?,
        )),
        _ => scalar_unary(value, operation),
    }
}

fn scalar_binary(left: &Value, right: &Value, operation: BinaryOp) -> Result<Value, EclError> {
    use BinaryOp::*;
    match operation {
        Add => scalar_add(left, right),
        Sub => scalar_sub(left, right),
        Mul => numeric_binary(left, right, "*", i64::checked_mul, |a, b| a * b),
        Div => {
            let (left, right) = numeric_pair(left, right, "/")?;
            let divisor = right.as_float();
            if divisor == 0.0 {
                return Err(domain_error("division by zero"));
            }
            let propagating = !left.as_float().is_finite() || !divisor.is_finite();
            float_result(left.as_float() / divisor, propagating, "/")
        }
        IntDiv | Mod => {
            let (ValueKind::Int(left), ValueKind::Int(right)) = (&left.kind, &right.kind) else {
                return Err(numeric_type_error(
                    if matches!(operation, IntDiv) {
                        "div"
                    } else {
                        "mod"
                    },
                    left,
                    right,
                ));
            };
            if *right == 0 {
                return Err(domain_error("integer division by zero"));
            }
            let value = if matches!(operation, IntDiv) {
                left.checked_div(*right)
            } else {
                left.checked_rem(*right)
            }
            .ok_or_else(|| {
                overflow_error(if matches!(operation, IntDiv) {
                    "div"
                } else {
                    "mod"
                })
            })?;
            Ok(Value::int(value))
        }
        Pow => {
            let (left, right) = numeric_pair(left, right, "pow")?;
            let propagating = !left.as_float().is_finite() || !right.as_float().is_finite();
            float_result(left.as_float().powf(right.as_float()), propagating, "pow")
        }
        Min | Max => {
            let ordering = compare_scalars(left, right)?;
            let select_left = if matches!(operation, Min) {
                ordering != Ordering::Greater
            } else {
                ordering != Ordering::Less
            };
            Ok(if select_left {
                left.clone()
            } else {
                right.clone()
            })
        }
        Eq | Ne | Lt | Gt | Le | Ge => {
            let ordering = compare_scalars(left, right)?;
            let result = match operation {
                Eq => ordering == Ordering::Equal,
                Ne => ordering != Ordering::Equal,
                Lt => ordering == Ordering::Less,
                Gt => ordering == Ordering::Greater,
                Le => ordering != Ordering::Greater,
                Ge => ordering != Ordering::Less,
                _ => unreachable!(),
            };
            Ok(Value::int(i64::from(result)))
        }
        And | Or => {
            let left = bool_atom(
                left,
                if matches!(operation, And) {
                    "and"
                } else {
                    "or"
                },
            )?;
            let right = bool_atom(
                right,
                if matches!(operation, And) {
                    "and"
                } else {
                    "or"
                },
            )?;
            Ok(Value::int(i64::from(if matches!(operation, And) {
                left && right
            } else {
                left || right
            })))
        }
    }
}

fn scalar_add(left: &Value, right: &Value) -> Result<Value, EclError> {
    match (&left.kind, &right.kind) {
        (ValueKind::Char(character), ValueKind::Int(offset))
        | (ValueKind::Int(offset), ValueKind::Char(character)) => offset_char(*character, *offset),
        (ValueKind::Char(_), ValueKind::Char(_)) => {
            Err(EclError::new(ErrorKind::Type, "char + char is undefined"))
        }
        _ => numeric_binary(left, right, "+", i64::checked_add, |a, b| a + b),
    }
}

fn scalar_sub(left: &Value, right: &Value) -> Result<Value, EclError> {
    match (&left.kind, &right.kind) {
        (ValueKind::Char(left), ValueKind::Char(right)) => {
            Ok(Value::int((*left as i64) - (*right as i64)))
        }
        (ValueKind::Char(character), ValueKind::Int(offset)) => {
            let offset = offset
                .checked_neg()
                .ok_or_else(|| overflow_error("char subtraction"))?;
            offset_char(*character, offset)
        }
        _ => numeric_binary(left, right, "-", i64::checked_sub, |a, b| a - b),
    }
}

fn scalar_unary(value: &Value, operation: UnaryOp) -> Result<Value, EclError> {
    use UnaryOp::*;
    match operation {
        Not => Ok(Value::int(i64::from(!bool_atom(value, "not")?))),
        Neg => match value.kind {
            ValueKind::Int(integer) => integer
                .checked_neg()
                .map(Value::int)
                .ok_or_else(|| overflow_error("neg")),
            ValueKind::Float(float) => float_result(-float, !float.is_finite(), "neg"),
            _ => Err(type_error("neg", "number", value)),
        },
        Abs => match value.kind {
            ValueKind::Int(integer) => integer
                .checked_abs()
                .map(Value::int)
                .ok_or_else(|| overflow_error("abs")),
            ValueKind::Float(float) => float_result(float.abs(), !float.is_finite(), "abs"),
            _ => Err(type_error("abs", "number", value)),
        },
        Sqrt => {
            let number = numeric_atom(value, "sqrt")?.as_float();
            if number < 0.0 {
                return Err(domain_error("sqrt requires a non-negative number"));
            }
            float_result(number.sqrt(), !number.is_finite(), "sqrt")
        }
        // floor/ceil/round return int64 (decision 22): their results get used
        // as indices and mask arithmetic, and int-ness keeps integer
        // pipelines integer.
        Floor | Ceil | Round => {
            let word = match operation {
                Floor => "floor",
                Ceil => "ceil",
                Round => "round",
                _ => unreachable!(),
            };
            match value.kind {
                ValueKind::Int(_) => Ok(value.clone()),
                ValueKind::Float(float) => {
                    let result = match operation {
                        Floor => float.floor(),
                        Ceil => float.ceil(),
                        Round => float.round(),
                        _ => unreachable!(),
                    };
                    float_to_int(result, word)
                }
                _ => Err(type_error(word, "number", value)),
            }
        }
    }
}

fn float_to_int(value: f64, word: &str) -> Result<Value, EclError> {
    const INT64_LOWER: f64 = -9_223_372_036_854_775_808.0;
    const INT64_UPPER: f64 = 9_223_372_036_854_775_808.0; // 2^63, exclusive
    if value.is_finite() && (INT64_LOWER..INT64_UPPER).contains(&value) {
        Ok(Value::int(value as i64))
    } else {
        Err(EclError::new(
            ErrorKind::Overflow,
            format!("{word} result is outside int64"),
        ))
    }
}

#[derive(Clone, Copy)]
enum Numeric {
    Int(i64),
    Float(f64),
}

impl Numeric {
    fn as_float(self) -> f64 {
        match self {
            Self::Int(value) => value as f64,
            Self::Float(value) => value,
        }
    }
}

fn numeric_atom(value: &Value, word: &str) -> Result<Numeric, EclError> {
    match value.kind {
        ValueKind::Int(value) => Ok(Numeric::Int(value)),
        ValueKind::Float(value) => Ok(Numeric::Float(value)),
        _ => Err(type_error(word, "number", value)),
    }
}

fn numeric_pair(left: &Value, right: &Value, word: &str) -> Result<(Numeric, Numeric), EclError> {
    Ok((numeric_atom(left, word)?, numeric_atom(right, word)?))
}

fn numeric_binary(
    left: &Value,
    right: &Value,
    word: &str,
    integer: fn(i64, i64) -> Option<i64>,
    float: fn(f64, f64) -> f64,
) -> Result<Value, EclError> {
    match (&left.kind, &right.kind) {
        (ValueKind::Int(left), ValueKind::Int(right)) => integer(*left, *right)
            .map(Value::int)
            .ok_or_else(|| overflow_error(word)),
        (ValueKind::Int(left), ValueKind::Float(right)) => {
            float_result(float(*left as f64, *right), !right.is_finite(), word)
        }
        (ValueKind::Float(left), ValueKind::Int(right)) => {
            float_result(float(*left, *right as f64), !left.is_finite(), word)
        }
        (ValueKind::Float(left), ValueKind::Float(right)) => float_result(
            float(*left, *right),
            !left.is_finite() || !right.is_finite(),
            word,
        ),
        _ => Err(numeric_type_error(word, left, right)),
    }
}

fn compare_scalars(left: &Value, right: &Value) -> Result<Ordering, EclError> {
    match (&left.kind, &right.kind) {
        (ValueKind::Int(left), ValueKind::Int(right)) => Ok(left.cmp(right)),
        (ValueKind::Int(left), ValueKind::Float(right)) => (*left as f64)
            .partial_cmp(right)
            .ok_or_else(|| domain_error("numbers are not comparable")),
        (ValueKind::Float(left), ValueKind::Int(right)) => left
            .partial_cmp(&(*right as f64))
            .ok_or_else(|| domain_error("numbers are not comparable")),
        (ValueKind::Float(left), ValueKind::Float(right)) => left
            .partial_cmp(right)
            .ok_or_else(|| domain_error("numbers are not comparable")),
        (ValueKind::Char(left), ValueKind::Char(right)) => Ok(left.cmp(right)),
        _ => Err(EclError::new(
            ErrorKind::Type,
            format!(
                "comparison expected two numbers or two chars, got {} and {}",
                left.type_name(),
                right.type_name()
            ),
        )),
    }
}

fn bool_atom(value: &Value, word: &str) -> Result<bool, EclError> {
    match value.kind {
        ValueKind::Int(0) => Ok(false),
        ValueKind::Int(1) => Ok(true),
        _ => Err(EclError::new(
            ErrorKind::Type,
            format!("{word} expected a 0/1 bool, got {}", value.canonical()),
        )),
    }
}

fn offset_char(character: char, offset: i64) -> Result<Value, EclError> {
    let codepoint = (character as i64)
        .checked_add(offset)
        .and_then(|value| u32::try_from(value).ok())
        .and_then(char::from_u32)
        .ok_or_else(|| domain_error("char arithmetic produced an invalid Unicode codepoint"))?;
    Ok(Value::char(codepoint))
}

/// Decision 22's float rule: NaN never exists (`'domain`); ±inf propagate
/// from non-finite operands but may not be *produced* from finite inputs
/// (`'overflow` — that would be silent overflow).
fn float_result(value: f64, propagating: bool, word: &str) -> Result<Value, EclError> {
    if value.is_nan() {
        return Err(domain_error(format!("{word} produced NaN")));
    }
    if value.is_infinite() && !propagating {
        return Err(EclError::new(
            ErrorKind::Overflow,
            format!("{word} produced a non-finite float"),
        ));
    }
    Ok(Value::float(value))
}

fn sequence(value: &Value, word: &str) -> Result<Vec<Value>, EclError> {
    try_sequence(value).ok_or_else(|| type_error(word, "list", value))
}

fn try_sequence(value: &Value) -> Option<Vec<Value>> {
    match &value.kind {
        ValueKind::List(values) => Some(values.to_vec()),
        ValueKind::String(string) => Some(string.chars().map(Value::char).collect()),
        _ => None,
    }
}

fn membership(needle: &Value, haystack: &[Value]) -> Value {
    match &needle.kind {
        ValueKind::List(values) => Value::list(
            values
                .iter()
                .map(|value| membership(value, haystack))
                .collect::<Vec<_>>(),
        ),
        ValueKind::String(string) => Value::list(
            string
                .chars()
                .map(Value::char)
                .map(|value| membership(&value, haystack))
                .collect::<Vec<_>>(),
        ),
        _ => Value::int(i64::from(
            haystack.iter().any(|item| item.structurally_eq(needle)),
        )),
    }
}

fn slice_sequence(value: &Value, count: i64, take: bool) -> Result<Value, EclError> {
    let word = if take { "take" } else { "drop" };
    match &value.kind {
        ValueKind::List(values) => {
            let (start, end) = slice_bounds(values.len(), count, take);
            Ok(Value::list(values[start..end].to_vec()))
        }
        ValueKind::String(string) => {
            let characters = string.chars().collect::<Vec<_>>();
            let (start, end) = slice_bounds(characters.len(), count, take);
            Ok(Value::string(
                characters[start..end].iter().collect::<String>(),
            ))
        }
        _ => Err(type_error(word, "list", value)),
    }
}

fn slice_bounds(length: usize, count: i64, take: bool) -> (usize, usize) {
    let magnitude = count.unsigned_abs().min(length as u64) as usize;
    if take {
        if count >= 0 {
            (0, magnitude)
        } else {
            (length - magnitude, length)
        }
    } else if count >= 0 {
        (magnitude, length)
    } else {
        (0, length - magnitude)
    }
}

fn index_value(collection: &Value, index: &Value) -> Result<Value, EclError> {
    if let ValueKind::List(indices) = &index.kind {
        return Ok(Value::list(
            indices
                .iter()
                .map(|index| index_value(collection, index))
                .collect::<Result<Vec<_>, _>>()?,
        ));
    }
    match &collection.kind {
        ValueKind::List(values) => {
            let ValueKind::Int(index) = index.kind else {
                return Err(type_error("at", "int index", index));
            };
            let index = valid_index(index, values.len())?;
            Ok(values[index].clone())
        }
        ValueKind::String(string) => {
            let ValueKind::Int(index) = index.kind else {
                return Err(type_error("at", "int index", index));
            };
            let length = string.chars().count();
            let index = valid_index(index, length)?;
            Ok(Value::char(
                string.chars().nth(index).expect("validated char index"),
            ))
        }
        ValueKind::Dict(entries) => entries
            .iter()
            .find_map(|(key, value)| key.structurally_eq(index).then(|| value.clone()))
            .ok_or_else(|| {
                EclError::new(
                    ErrorKind::Domain,
                    format!("missing dict key {}", index.canonical()),
                )
            }),
        _ => Err(type_error("at", "list or dict", collection)),
    }
}

fn valid_index(index: i64, length: usize) -> Result<usize, EclError> {
    let index = usize::try_from(index)
        .map_err(|_| EclError::new(ErrorKind::Domain, format!("negative index {index}")))?;
    if index >= length {
        Err(EclError::new(
            ErrorKind::Domain,
            format!("index {index} is outside length {length}"),
        ))
    } else {
        Ok(index)
    }
}

fn format_values(values: &[Value], template: &str) -> Result<String, EclError> {
    let mut output = String::new();
    let mut values = values.iter();
    let mut characters = template.chars().peekable();
    while let Some(character) = characters.next() {
        match (character, characters.peek().copied()) {
            ('{', Some('{')) => {
                characters.next();
                output.push('{');
            }
            ('}', Some('}')) => {
                characters.next();
                output.push('}');
            }
            ('{', Some('}')) => {
                characters.next();
                let value = values.next().ok_or_else(|| {
                    EclError::new(
                        ErrorKind::Contract,
                        "format has more placeholders than values",
                    )
                })?;
                output.push_str(&value.canonical());
            }
            ('{', _) | ('}', _) => {
                return Err(EclError::new(
                    ErrorKind::Domain,
                    "format contains an unmatched brace",
                ));
            }
            _ => output.push(character),
        }
    }
    if values.next().is_some() {
        return Err(EclError::new(
            ErrorKind::Contract,
            "format has more values than placeholders",
        ));
    }
    Ok(output)
}

fn dict_lookup<'a>(entries: &'a [(Value, Value)], name: &str) -> Option<&'a Value> {
    entries
        .iter()
        .find_map(|(key, value)| (key.as_symbol() == Some(name)).then_some(value))
}

fn ok_outcome(results: Vec<Value>) -> Value {
    Value::dict(vec![(Value::symbol("ok"), Value::list(results))])
}

fn err_outcome(error: Value) -> Value {
    Value::dict(vec![(Value::symbol("err"), error)])
}

fn type_error(word: &str, expected: &str, got: &Value) -> EclError {
    EclError::new(
        ErrorKind::Type,
        format!(
            "{word} expected {expected}, got {} ({})",
            got.canonical(),
            got.type_name()
        ),
    )
    .with_data("expected", Value::string(expected))
    .with_data("got", Value::string(got.type_name()))
}

fn numeric_type_error(word: &str, left: &Value, right: &Value) -> EclError {
    EclError::new(
        ErrorKind::Type,
        format!(
            "{word} expected numeric atoms, got {} and {}",
            left.type_name(),
            right.type_name()
        ),
    )
}

fn overflow_error(word: &str) -> EclError {
    EclError::new(ErrorKind::Overflow, format!("integer overflow in {word}"))
}

fn domain_error(message: impl Into<String>) -> EclError {
    EclError::new(ErrorKind::Domain, message)
}

fn conform_error(left: usize, right: usize) -> EclError {
    EclError::new(
        ErrorKind::Conform,
        format!("leading axes do not conform: {left} versus {right}"),
    )
    .with_data("left", Value::int(left as i64))
    .with_data("right", Value::int(right as i64))
}

fn contract_error(context: &str, expected: &str, seeded: usize, observed: usize) -> EclError {
    EclError::new(
        ErrorKind::Contract,
        format!(
            "{context} violated its contract {expected}; seeded {seeded}, observed {observed} result values"
        ),
    )
    .with_data("expected", Value::string(expected))
    .with_data("observed", Value::int(observed as i64))
}

fn io_error(error: io::Error) -> EclError {
    EclError::new(ErrorKind::Io, error.to_string())
}

fn core_words() -> &'static [&'static str] {
    &[
        "dup",
        "swap",
        "pop",
        "over",
        "dip",
        "call",
        "cons",
        "compose",
        "if",
        "while",
        "def",
        "let",
        "body",
        "words",
        "to-word",
        "to-symbol",
        "parse",
        "str",
        "+",
        "-",
        "*",
        "/",
        "div",
        "mod",
        "pow",
        "min",
        "max",
        "=",
        "<>",
        "<",
        ">",
        "<=",
        ">=",
        "and",
        "or",
        "neg",
        "abs",
        "sqrt",
        "floor",
        "ceil",
        "round",
        "not",
        "match",
        "len",
        "shape",
        "first",
        "rest",
        "take",
        "drop",
        "at",
        "where",
        "in",
        "raze",
        "cat",
        "reverse",
        "range",
        "grade",
        "distinct",
        "dict-of",
        "keys",
        "vals",
        "put",
        "del",
        "merge",
        "has?",
        "each",
        "each2",
        "for",
        "fold",
        "scan",
        "split",
        "join",
        "format",
        "raise",
        "attempt",
        "ok?",
        "ok!",
        "or-else",
        "prin",
        "pp",
        "slurp",
        "spit",
        "args",
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(source: &str) -> Runtime {
        let mut runtime = Runtime::new();
        runtime.run("test", source).unwrap();
        runtime
    }

    #[test]
    fn evaluates_arithmetic_and_pervasion() {
        assert_eq!(run("3 4 +").stack_display(), "7");
        assert_eq!(run("[1 2 3] 10 *").stack_display(), "[10 20 30]");
        assert_eq!(run("[[1 2] [3]] 10 *").stack_display(), "([10 20] [30])");
    }

    #[test]
    fn definitions_are_late_bound_and_values_do_not_execute() {
        let runtime = run("(1 +) 'inc def 3 inc (10) 'data let data");
        assert_eq!(runtime.stack_display(), "4 [10]");
    }

    #[test]
    fn combinators_use_isolated_contract_checked_stacks() {
        assert_eq!(run("[1 2 3] (dup *) each").stack_display(), "[1 4 9]");
        assert_eq!(run("[1 2 3] 0 (+) fold").stack_display(), "6");
        let mut runtime = Runtime::new();
        let error = runtime.run("test", "[1] (dup) each").unwrap_err();
        assert_eq!(error.kind, ErrorKind::Contract);
    }

    #[test]
    fn binders_execute_their_point_free_lowering() {
        assert_eq!(run("5 (|x| x x *) call").stack_display(), "25");
        assert_eq!(run("10 3 (|lo hi| hi lo -) call").stack_display(), "-7");
    }

    #[test]
    fn dict_literals_are_isolated_and_round_trip() {
        assert_eq!(
            run("99 {'answer 40 2 +}").stack_display(),
            "99 {'answer 42}"
        );
    }

    #[test]
    fn failed_units_restore_only_the_stack() {
        let mut runtime = Runtime::new();
        runtime.run("test", "10").unwrap();
        assert!(runtime.run("test", "20 + missing").is_err());
        assert_eq!(runtime.stack_display(), "10");

        assert!(runtime.run("test", "(1 +) 'inc def missing").is_err());
        runtime.run("test", "2 inc").unwrap();
        assert_eq!(runtime.stack_display(), "10 3");
    }

    #[test]
    fn attempt_reifies_errors_without_touching_the_outer_stack() {
        let runtime = run("7 (1 0 /) attempt");
        assert!(runtime.stack_display().starts_with("7 {'err "));
    }

    #[test]
    fn canonical_output_executes_back_to_the_same_value() {
        let runtime = run("{'name \"ecl\" 'values [[1 2] [3]]} dup str parse call match");
        assert_eq!(runtime.stack_display(), "1");
        assert_eq!(run(r#""ab" [\a \b] match"#).stack_display(), "1");
    }

    #[test]
    fn loops_scans_and_membership_cover_the_control_slice() {
        assert_eq!(run("3 (dup 0 >) (1 -) while").stack_display(), "0");
        assert_eq!(run("[1 2 3] 0 (+) scan").stack_display(), "[1 3 6]");
        assert_eq!(run("[1 4] [1 2 3] in").stack_display(), "[1 0]");
    }

    #[test]
    fn rethrow_preserves_the_original_error_context() {
        let mut runtime = Runtime::new();
        let error = runtime.run("test", "(1 0 /) attempt ok!").unwrap_err();
        assert_eq!(error.word.as_deref(), Some("/"));
        assert_eq!(error.span.as_deref().map(|span| span.column), Some(6));
    }

    #[test]
    fn extreme_char_subtraction_is_an_ecl_error_not_a_host_panic() {
        let mut runtime = Runtime::new();
        let error = runtime
            .run("test", r"\a -9223372036854775808 -")
            .unwrap_err();
        assert_eq!(error.kind, ErrorKind::Overflow);
    }

    #[test]
    fn decision_22_float_rulings_hold() {
        assert_eq!(run("inf 1 +").stack_display(), "inf");
        assert_eq!(run("-inf").stack_display(), "-inf");
        assert_eq!(run("2.7 floor 2.2 ceil 2.5 round").stack_display(), "2 3 3");
        assert_eq!(run("0.0 -0.0 match").stack_display(), "1");

        let mut runtime = Runtime::new();
        let nan = runtime.run("test", "inf inf -").unwrap_err();
        assert_eq!(nan.kind, ErrorKind::Domain);
        let silent_overflow = runtime.run("test", "1.0e308 10.0 *").unwrap_err();
        assert_eq!(silent_overflow.kind, ErrorKind::Overflow);
    }

    #[test]
    fn each2_extends_atoms_like_broadcast() {
        assert_eq!(
            run("[1 2 3] 10 (pair) each2").stack_display(),
            "[[1 10] [2 10] [3 10]]"
        );
        assert_eq!(
            run("10 [1 2 3] (pair) each2").stack_display(),
            "[[10 1] [10 2] [10 3]]"
        );
    }

    #[test]
    fn char_lists_specialize_to_strings_at_construction() {
        assert_eq!(run(r#""ab" 1 +"#).stack_display(), "\"bc\"");
        assert_eq!(run(r"[\a \b]").stack_display(), "\"ab\"");
        assert_eq!(run(r#"["ab" "cd"] raze"#).stack_display(), "\"abcd\"");
        assert_eq!(run(r#"\a "bc" cons"#).stack_display(), "\"abc\"");
    }

    #[test]
    fn prelude_covers_dataflow_and_failure_words() {
        assert_eq!(run("5 (1 +) keep").stack_display(), "6 5");
        assert_eq!(run("5 (1 +) (2 *) bi").stack_display(), "6 10");
        assert_eq!(run("5 (1 +) (2 *) (3 -) tri").stack_display(), "6 10 2");
        assert_eq!(run("[10 20 30] 20 find").stack_display(), "1");
        assert_eq!(run("[10 20 30] 99 find").stack_display(), "3");

        let mut runtime = Runtime::new();
        let error = runtime.run("test", "\"boom\" fail").unwrap_err();
        assert_eq!(error.kind, ErrorKind::User);
        assert_eq!(error.message, "boom");
    }

    #[test]
    fn words_and_symbols_convert_explicitly() {
        assert_eq!(
            run("'+ to-word wrap (3 4) swap compose call").stack_display(),
            "7"
        );
        assert_eq!(run("(dup) first to-symbol").stack_display(), "'dup");
        assert_eq!(run("(dup) first 'dup match").stack_display(), "0");
    }

    #[test]
    fn recursion_uses_machine_frames_not_the_host_stack() {
        let runtime = run("(dup 0 > (1 - countdown) (pop) if) 'countdown def 20000 countdown");
        assert_eq!(runtime.stack_display(), "");
    }
}
