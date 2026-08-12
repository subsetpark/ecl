use std::env;
use std::io::{self, IsTerminal, Read, Write};
use std::path::Path;
use std::process::ExitCode;

use ecl::{EclError, ReadStatus, Reader, Runtime, SourceSpan};

const HELP: &str = "\
ecl — a walking-skeleton concatenative array calculator

USAGE:
    ecl                         Start a REPL (or read one script from stdin)
    ecl -e <SOURCE> [ARGS...]  Evaluate source and print the resulting stack
    ecl <FILE> [ARGS...]       Run a UTF-8 script file
    ecl <SOURCE>               Evaluate source; e.g. ecl '3 4 +'

OPTIONS:
    -e, --eval <SOURCE>        Evaluate source text
    -h, --help                 Show this help
    -V, --version              Show the version
";

fn main() -> ExitCode {
    match entry(env::args().skip(1).collect()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn entry(arguments: Vec<String>) -> Result<(), EclError> {
    let Some(first) = arguments.first() else {
        return if io::stdin().is_terminal() {
            repl()
        } else {
            run_stdin()
        };
    };

    match first.as_str() {
        "-h" | "--help" => {
            print!("{HELP}");
            Ok(())
        }
        "-V" | "--version" => {
            println!("ecl {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        "-e" | "--eval" => {
            let Some(source) = arguments.get(1) else {
                return Err(EclError::new(
                    ecl::ErrorKind::Io,
                    format!("{first} requires source text"),
                ));
            };
            let mut runtime = Runtime::with_args(arguments.iter().skip(2).cloned());
            runtime.run("<command>", source)?;
            print_stack(&runtime);
            Ok(())
        }
        "-" => {
            let source = read_stdin_utf8()?;
            let mut runtime = Runtime::with_args(arguments.iter().skip(1).cloned());
            runtime.run("<stdin>", &source)?;
            print_stack(&runtime);
            Ok(())
        }
        _ if Path::new(first).is_file() => {
            let source = read_file_utf8(first)?;
            let mut runtime = Runtime::with_args(arguments.iter().skip(1).cloned());
            runtime.run(first, &source)
        }
        _ if first.ends_with(".ecl") => Err(EclError::new(
            ecl::ErrorKind::Io,
            format!("script file `{first}` does not exist"),
        )),
        _ => {
            let mut runtime = Runtime::with_args(arguments.iter().skip(1).cloned());
            runtime.run("<command>", first)?;
            print_stack(&runtime);
            Ok(())
        }
    }
}

fn run_stdin() -> Result<(), EclError> {
    let source = read_stdin_utf8()?;
    let mut runtime = Runtime::new();
    runtime.run("<stdin>", &source)?;
    print_stack(&runtime);
    Ok(())
}

fn repl() -> Result<(), EclError> {
    let mut runtime = Runtime::new();
    let reader = Reader::new("<repl>");
    let stdin = io::stdin();
    let mut pending = String::new();
    let mut continuation = false;

    loop {
        print!("{}", if continuation { ".. " } else { "ecl> " });
        io::stdout().flush().map_err(io_error)?;

        let mut line = String::new();
        if stdin.read_line(&mut line).map_err(io_error)? == 0 {
            if pending.trim().is_empty() {
                println!();
                return Ok(());
            }
            return match reader.read(&pending) {
                Ok(_) => Ok(()),
                Err(failure) => Err(failure.0),
            };
        }
        pending.push_str(&line);

        match reader.read_status(&pending) {
            Ok(ReadStatus::Incomplete { .. }) => continuation = true,
            Ok(ReadStatus::Complete(forms)) => {
                match runtime.run_forms(forms) {
                    Ok(()) => print_stack(&runtime),
                    Err(error) => eprintln!("{error}"),
                }
                pending.clear();
                continuation = false;
            }
            Err(error) => {
                eprintln!("{error}");
                pending.clear();
                continuation = false;
            }
        }
    }
}

fn print_stack(runtime: &Runtime) {
    let rendered = runtime.stack_display();
    if !rendered.is_empty() {
        println!("{rendered}");
    }
}

fn io_error(error: io::Error) -> EclError {
    EclError::new(ecl::ErrorKind::Io, error.to_string())
}

fn read_file_utf8(path: &str) -> Result<String, EclError> {
    let bytes = std::fs::read(path).map_err(io_error)?;
    decode_source(bytes, path)
}

fn read_stdin_utf8() -> Result<String, EclError> {
    let mut bytes = Vec::new();
    io::stdin().read_to_end(&mut bytes).map_err(io_error)?;
    decode_source(bytes, "<stdin>")
}

fn decode_source(bytes: Vec<u8>, source: &str) -> Result<String, EclError> {
    String::from_utf8(bytes).map_err(|error| {
        EclError::parse(
            format!(
                "source is not valid UTF-8 (invalid byte at offset {})",
                error.utf8_error().valid_up_to()
            ),
            Some(SourceSpan::new(source, 1, 1)),
        )
    })
}
