mod config;
mod diag;
mod lock;
mod markdown;
mod math;
mod model;
mod noweb;
mod prose;
mod resolve;
mod rewrite;
mod site;
mod tangle;
mod weave;

use std::path::Path;
use std::process::ExitCode;

const USAGE: &str = "\
lit — web-first literate programming (early scaffold)

USAGE:
    lit weave <file.nw>...        weave to _site/ (single page; M2 adds splitting)
    lit lock <file.nw>...         mint frozen ids for every label into lit.lock (§7.1)
    lit labels <file.nw>          list the file's label → id map from lit.lock
    lit id <file.nw> <label>      print the frozen id for one label
    lit dump-ir <file.nw>...      run noweb markup, print the parsed IR events
    lit dump-model <file.nw>...   fold the IR into the document model, print it
    lit tangle <file.nw>...       tangle every root chunk (via notangle)

    lit --explain <CODE>         print the long form of a diagnostic (e.g. E014)

OPTIONS:
    --out <dir>                   weave: output dir (default: _site)
                                  tangle: root dir for tangled files (default: .)
    --archive                     weave: also emit site.json + per-page JSON (§8)
    --locked                      weave: never mint ids; error if a label is not
                                  in lit.lock (CI / read-only sandbox; §7.1)
    --deny-warnings               weave: exit nonzero if any lint fires (CI)
    -R <name>                     tangle: write one chunk to stdout instead
    --check                       tangle: diff roots against disk, exit 1 on drift
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // `--explain <CODE>` is informational and stage-independent (§12): it may
    // sit after any subcommand (`lit weave --explain E014`) or stand alone.
    if let Some(pos) = args.iter().position(|a| a == "--explain") {
        return explain_cmd(args.get(pos + 1).map(String::as_str));
    }
    match args.split_first().map(|(cmd, rest)| (cmd.as_str(), rest)) {
        Some(("dump-ir", files)) if !files.is_empty() => dump_ir(files),
        Some(("dump-model", files)) if !files.is_empty() => dump_model(files),
        Some(("weave", args)) if !args.is_empty() => weave_cmd(args),
        Some(("lock", files)) if !files.is_empty() => lock_cmd(files),
        Some(("labels", files)) if files.len() == 1 => labels_cmd(&files[0]),
        Some(("id", rest)) if rest.len() == 2 => id_cmd(&rest[0], &rest[1]),
        Some(("tangle", args)) if !args.is_empty() => tangle_cmd(args),
        Some(("--version" | "-V", _)) => {
            println!("lit {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        _ => {
            eprint!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn explain_cmd(code: Option<&str>) -> ExitCode {
    match code {
        Some(code) => match diag::explain(code) {
            Some(text) => {
                println!("{code}: {text}");
                ExitCode::SUCCESS
            }
            None => {
                eprintln!("lit: no explanation for `{code}`");
                ExitCode::FAILURE
            }
        },
        None => {
            eprintln!("lit: --explain needs an error code (e.g. E014)");
            ExitCode::from(2)
        }
    }
}

fn weave_cmd(args: &[String]) -> ExitCode {
    let mut out = "_site".to_string();
    let mut archive = false;
    let mut deny_warnings = false;
    let mut locked = false;
    let mut files = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--out" => match it.next() {
                Some(dir) => out = dir.clone(),
                None => {
                    eprintln!("lit: --out needs a directory");
                    return ExitCode::from(2);
                }
            },
            "--archive" => archive = true,
            "--deny-warnings" => deny_warnings = true,
            "--locked" => locked = true,
            _ => files.push(a.clone()),
        }
    }
    if files.is_empty() {
        eprintln!("lit: weave needs at least one .nw file");
        return ExitCode::from(2);
    }

    let events = match noweb::run_markup(&files) {
        Ok(events) => events,
        Err(e) => {
            eprintln!("lit: {e}");
            return ExitCode::FAILURE;
        }
    };
    let doc = match model::build(&events) {
        Ok(doc) => doc,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let mut warnings = 0usize;
    for lint in doc.lints() {
        eprintln!("{lint}");
        warnings += 1;
    }
    let cfg = match config::Config::load(Path::new(".")) {
        Ok(c) => c.unwrap_or_default(),
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let doc_cfg = cfg.document().cloned().unwrap_or_default();
    // A declared file set is the document's own definition of its sources;
    // fall back to the CLI arguments when `lit.toml` names none.
    let source_files = if doc_cfg.files.is_empty() {
        files.clone()
    } else {
        doc_cfg.files.clone()
    };
    let dialect = doc_cfg.dialect;
    let meta = site::Meta {
        id: doc_cfg.id,
        title: doc_cfg.title,
        authors: doc_cfg.authors,
        source_files,
    };
    let mode = if locked {
        lock::LockMode::Locked
    } else {
        lock::LockMode::Mint
    };
    match weave::write_site(
        &doc,
        Path::new(&out),
        Path::new(".lit-cache"),
        Path::new("lit.lock"),
        meta,
        dialect,
        archive,
        mode,
    ) {
        Ok(site) => {
            for lint in &site.lints {
                eprintln!("{lint}");
                warnings += 1;
            }
            println!(
                "wove {} sections ({} math) across {} page(s) to {out}/",
                doc.sections.len(),
                site.math_count,
                site.pages.len()
            );
            // `--deny-warnings` turns lints into a nonzero exit for CI (§12); the
            // site is still written, so the artifact is available to inspect.
            if deny_warnings && warnings > 0 {
                eprintln!("lit: {warnings} warning(s); failing due to --deny-warnings");
                return ExitCode::FAILURE;
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// Run noweb + fold the IR into the model + resolve the prose dialect — the front
/// half shared by `weave` and `lock`. Diagnostics are printed here; the `Err`
/// carries the process exit code.
fn build_doc(files: &[String]) -> Result<(model::DocModel, config::Dialect), ExitCode> {
    let events = noweb::run_markup(files).map_err(|e| {
        eprintln!("lit: {e}");
        ExitCode::FAILURE
    })?;
    let doc = model::build(&events).map_err(|e| {
        eprintln!("{e}");
        ExitCode::FAILURE
    })?;
    let cfg = config::Config::load(Path::new("."))
        .map_err(|e| {
            eprintln!("{e}");
            ExitCode::FAILURE
        })?
        .unwrap_or_default();
    let dialect = cfg.document().map(|d| d.dialect).unwrap_or_default();
    Ok((doc, dialect))
}

/// `lit lock`: mint a frozen id for every label into `lit.lock` without rendering
/// (§7.1). Ids already present are left untouched; new ones are written back so a
/// later `--locked` weave finds them.
fn lock_cmd(files: &[String]) -> ExitCode {
    let (doc, dialect) = match build_doc(files) {
        Ok(pair) => pair,
        Err(code) => return code,
    };
    let path = Path::new("lit.lock");
    let mut lock = match lock::LockFile::load(path) {
        Ok(lock) => lock,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let before = lock.count();
    let mut minter = lock::Minter::from_entropy();
    if let Err(e) = weave::mint_lock(&doc, dialect, &mut lock, &mut minter) {
        eprintln!("{e}");
        return ExitCode::FAILURE;
    }
    if let Err(e) = lock.save(path) {
        eprintln!("{e}");
        return ExitCode::FAILURE;
    }
    println!(
        "lit.lock: {} label(s), {} newly minted",
        lock.count(),
        lock.count() - before
    );
    ExitCode::SUCCESS
}

/// `lit labels <file>`: print the file's `label → id (kind)` map from `lit.lock`,
/// in sorted order (the committed lock is the greppable source of truth; §7.1).
fn labels_cmd(file: &str) -> ExitCode {
    let lock = match lock::LockFile::load(Path::new("lit.lock")) {
        Ok(lock) => lock,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    for (label, entry) in lock.labels(file) {
        println!("{label}\t{}\t{}", entry.id, entry.kind.word());
    }
    ExitCode::SUCCESS
}

/// `lit id <file> <label>`: print the frozen id for one label, or exit nonzero if
/// the label is not in `lit.lock`.
fn id_cmd(file: &str, label: &str) -> ExitCode {
    let lock = match lock::LockFile::load(Path::new("lit.lock")) {
        Ok(lock) => lock,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    match lock.get(file, label) {
        Some(entry) => {
            println!("{}", entry.id);
            ExitCode::SUCCESS
        }
        None => {
            eprintln!("lit: no id for label `{label}` in {file} (run `lit lock`)");
            ExitCode::FAILURE
        }
    }
}

fn tangle_cmd(args: &[String]) -> ExitCode {
    let mut out: Option<String> = None;
    let mut single: Option<String> = None;
    let mut check = false;
    let mut files = Vec::new();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--out" => match it.next() {
                Some(dir) => out = Some(dir.clone()),
                None => {
                    eprintln!("lit: --out needs a directory");
                    return ExitCode::from(2);
                }
            },
            "-R" => match it.next() {
                Some(name) => single = Some(name.clone()),
                None => {
                    eprintln!("lit: -R needs a chunk name");
                    return ExitCode::from(2);
                }
            },
            "--check" => check = true,
            _ => files.push(a.clone()),
        }
    }
    if files.is_empty() {
        eprintln!("lit: tangle needs at least one .nw file");
        return ExitCode::from(2);
    }

    let cfg = match config::Config::load(Path::new(".")) {
        Ok(c) => c.unwrap_or_default(),
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let pragmas = cfg.tangle_pragmas();
    // Precedence: explicit `--out`, then `lit.toml`'s `[tangle] outdir`, then cwd.
    let out = out
        .or_else(|| cfg.tangle.outdir.clone())
        .unwrap_or_else(|| ".".to_string());

    // `-R name` is a direct passthrough to notangle: no model needed, and it
    // never touches disk — the caller redirects stdout where they want it. The
    // per-root pragma still applies so the stdout form matches the on-disk form.
    if let Some(name) = single {
        let pragma = pragmas.get(&name).map(String::as_str);
        return match tangle::tangle_root(&name, &files, pragma) {
            Ok(code) => {
                print!("{code}");
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("{e}");
                ExitCode::FAILURE
            }
        };
    }

    // The whole-document modes enumerate roots from the model, which also
    // surfaces E010 (use of an undefined chunk) before we spawn notangle.
    let events = match noweb::run_markup(&files) {
        Ok(events) => events,
        Err(e) => {
            eprintln!("lit: {e}");
            return ExitCode::FAILURE;
        }
    };
    let doc = match model::build(&events) {
        Ok(doc) => doc,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    let roots = doc.roots();
    if roots.is_empty() {
        eprintln!("lit: no root chunks (path-shaped names) to tangle");
        return ExitCode::from(2);
    }
    let outdir = Path::new(&out);

    if check {
        return match tangle::check(&roots, &files, outdir, &pragmas) {
            Ok(drift) if drift.is_empty() => {
                println!("tangle --check: {} root(s) in sync", roots.len());
                ExitCode::SUCCESS
            }
            Ok(drift) => {
                for (root, d) in &drift {
                    let why = match d {
                        tangle::Drift::Missing => "not on disk",
                        tangle::Drift::Differs => "differs from disk",
                    };
                    eprintln!("drift: {root} {why}");
                }
                ExitCode::FAILURE
            }
            Err(e) => {
                eprintln!("{e}");
                ExitCode::FAILURE
            }
        };
    }

    match tangle::tangle_to_dir(&roots, &files, outdir, &pragmas) {
        Ok(report) => {
            for (root, wrote) in &report {
                let verb = match wrote {
                    tangle::Wrote::Created => "created",
                    tangle::Wrote::Updated => "updated",
                    tangle::Wrote::Unchanged => "unchanged",
                };
                println!("{verb} {root}");
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

fn dump_model(files: &[String]) -> ExitCode {
    let events = match noweb::run_markup(files) {
        Ok(events) => events,
        Err(e) => {
            eprintln!("lit: {e}");
            return ExitCode::FAILURE;
        }
    };
    let doc = match model::build(&events) {
        Ok(doc) => doc,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    for lint in doc.lints() {
        eprintln!("{lint}");
    }
    println!("files: {:?}", doc.files);
    println!("roots: {:?}", doc.roots());
    for section in &doc.sections {
        println!(
            "{} {}:{} {:?}",
            section.id, section.file, section.line, section.kind
        );
    }
    for (name, info) in &doc.chunks {
        println!(
            "chunk {name:?} root={} defs={:?} uses={:?}",
            info.root, info.defs, info.uses
        );
    }
    ExitCode::SUCCESS
}

fn dump_ir(files: &[String]) -> ExitCode {
    match noweb::run_markup(files) {
        Ok(events) => {
            for event in &events {
                println!("{event:?}");
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("lit: {e}");
            ExitCode::FAILURE
        }
    }
}
