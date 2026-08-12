use std::process::{Command, Stdio};

fn ecl() -> Command {
    Command::new(env!("CARGO_BIN_EXE_ecl"))
}

#[test]
fn calculator_mode_prints_the_result() {
    let output = ecl().arg("3 4 +").output().unwrap();
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), "7\n");
    assert!(output.stderr.is_empty());
}

#[test]
fn script_errors_are_data_on_stderr_and_nonzero() {
    let output = ecl().arg("1 0 /").output().unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("'kind 'domain"), "{stderr}");
    assert!(stderr.contains("'word '/"), "{stderr}");
}

#[test]
fn piped_stdin_is_one_unit() {
    let mut child = ecl()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"5 range 1 +")
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap(), "[1 2 3 4 5]\n");
}

#[test]
fn invalid_utf8_source_is_a_parse_error() {
    let path = std::env::temp_dir().join(format!("ecl-invalid-{}.ecl", std::process::id()));
    std::fs::write(&path, [0xff, 0xfe]).unwrap();
    let output = ecl().arg(&path).output().unwrap();
    std::fs::remove_file(path).unwrap();

    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("'kind 'parse"), "{stderr}");
    assert!(stderr.contains("not valid UTF-8"), "{stderr}");
}

#[test]
fn isolated_let_does_not_leak_into_the_session() {
    let output = ecl()
        .args(["-e", "[1 2 3] (dup 'k let k *) each pop k"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("'kind 'undefined-word"), "{stderr}");
    assert!(stderr.contains("'word 'k"), "{stderr}");
}
