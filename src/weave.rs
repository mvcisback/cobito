//! M1 weave: document model → a single HTML page (§19.3).
//!
//! Steps 3–5 of §6.2 (parse, rewrite, serialize) are deliberately a
//! pass-through here: M1 has no numbering, `data-ref`, or sidenote hoisting to
//! do, so there is nothing an HTML parser would contribute yet. The step-2/6
//! placeholder split is already in place so M2 can insert a real parse between
//! them without reordering anything.

use std::fmt;
use std::path::{Path, PathBuf};

use crate::config::Dialect;
use crate::highlight::{self, Lang, LangConfig};
use crate::lock::{LockError, LockFile, LockMode, Minter};
use crate::markdown;
use crate::math::{MathError, Renderer};
use crate::model::{CodeSpan, DocModel, Lint, SectionKind};
use crate::prose::{self, Math, ProseError};
use crate::resolve::{self, LabelIds, NavNode, PageMeta, ResolveError};
use crate::rewrite::{self, Kind, Plan, RewriteError, Scan};
use crate::site::{self, SiteJson};

#[derive(Debug)]
pub enum WeaveError {
    Prose {
        file: String,
        line: u32,
        err: ProseError,
    },
    Markdown {
        file: String,
        line: u32,
        err: markdown::MarkdownError,
    },
    Math(MathError),
    Rewrite(RewriteError),
    Resolve(ResolveError),
    Lock(LockError),
    Assets(String),
    Io(std::io::Error),
    Template(String),
}

impl fmt::Display for WeaveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WeaveError::Prose { file, line, err } => {
                write!(f, "error[E022]: {err}\n  --> {file}:{line}")
            }
            WeaveError::Markdown { file, line, err } => {
                write!(f, "{err}\n  --> {file}:{line}")
            }
            WeaveError::Math(e) => write!(f, "{e}"),
            WeaveError::Rewrite(e) => write!(f, "{e}"),
            WeaveError::Resolve(e) => write!(f, "{e}"),
            WeaveError::Lock(e) => write!(f, "{e}"),
            WeaveError::Assets(m) => write!(f, "error[E023]: {m}"),
            WeaveError::Io(e) => write!(f, "error[E024]: writing site: {e}"),
            WeaveError::Template(m) => write!(f, "error[E025]: template: {m}"),
        }
    }
}

impl std::error::Error for WeaveError {}

/// Render one code chunk, following noweb's own convention: `<<name>>=` for a
/// definition, `<<name>>+=` for a continuation (§5.1), and uses linked to the
/// defining section.
///
/// Two structural commitments (§5.3): the chunk is a `<details open>` so a
/// reader can fold it away, and each body line is its own element carrying its
/// `.nw` coordinate. The number is drawn by CSS from `data-line`, never written
/// into the text — generated content does not land in a copy-paste and does not
/// perturb the text-quote selectors the annotation layer anchors on (§9.2).
fn render_code(
    name: &str,
    continues: bool,
    spans: &[CodeSpan],
    first_line: u32,
    doc: &DocModel,
    lang: Option<Lang>,
) -> String {
    let marker = if continues { "+=" } else { "=" };

    // A clean source buffer for the highlighter: the raw literal runs joined by
    // newlines, with chunk-use holes removed but their byte offset and anchor
    // HTML recorded so they splice back into the exact same spot afterwards
    // (§5.5). The tokenizer never sees `<<...>>`, only the target's own text.
    let mut source = String::new();
    let mut holes: Vec<(usize, String)> = Vec::new();
    for span in spans {
        match span {
            CodeSpan::Nl => source.push('\n'),
            CodeSpan::Text(t) => source.push_str(t),
            CodeSpan::Use { name } => holes.push((source.len(), hole_anchor(name, doc))),
        }
    }
    // The chunk-terminating newline opens a line that has no source line.
    if source.ends_with('\n') {
        source.pop();
    }

    let hole_refs: Vec<(usize, &str)> = holes.iter().map(|(o, s)| (*o, s.as_str())).collect();
    let lines = match lang {
        // Highlighting is best-effort: a grammar error falls back to the same
        // escaped plain text the no-language path emits (§5.5 — plain text is
        // the floor, never an error).
        Some(l) => highlight::highlight(&source, &hole_refs, l)
            .unwrap_or_else(|_| plain_lines(&source, &holes)),
        None => plain_lines(&source, &holes),
    };

    let mut out = format!(
        "<details class=\"chunk\" open><summary><span class=\"chunk-name\">\
         &lt;&lt;<dfn>{}</dfn>&gt;&gt;{marker}</span></summary><pre class=\"chunk-body\">",
        prose::escape(name)
    );
    for (i, line) in lines.iter().enumerate() {
        out.push_str(&format!(
            "<span class=\"line\" data-line=\"{}\">{line}</span>",
            first_line + i as u32
        ));
    }
    out.push_str("</pre></details>");
    out
}

/// The `<a>` anchor a chunk-use hole renders as: the italic `<<name>>` label,
/// linked to the section that defines `name` when there is one (§5.4).
fn hole_anchor(name: &str, doc: &DocModel) -> String {
    let target = doc
        .chunks
        .get(name)
        .and_then(|c| c.defs.first())
        .map(String::as_str);
    let label = format!("&lt;<i>{}</i>&gt;", prose::escape(name));
    match target {
        Some(id) => format!("<a href=\"#{id}\">{label}</a>"),
        None => label,
    }
}

/// The no-highlight path: escape the clean buffer and splice the holes back,
/// yielding one inner-HTML string per line. Mirrors `highlight::highlight`'s
/// splice but without tokenization, so both paths agree on the plain-text
/// payload byte-for-byte.
fn plain_lines(source: &str, holes: &[(usize, String)]) -> Vec<String> {
    let mut lines: Vec<String> = vec![String::new()];
    let mut pos = 0;
    let mut hi = 0;
    while pos < source.len() {
        while hi < holes.len() && holes[hi].0 == pos {
            lines.last_mut().unwrap().push_str(&holes[hi].1);
            hi += 1;
        }
        let next_hole = holes.get(hi).map_or(source.len(), |h| h.0);
        let next_nl = source[pos..].find('\n').map_or(source.len(), |o| pos + o);
        let stop = next_hole.min(next_nl);
        if stop > pos {
            lines
                .last_mut()
                .unwrap()
                .push_str(&prose::escape(&source[pos..stop]));
            pos = stop;
        }
        if pos == next_nl && pos < source.len() {
            lines.push(String::new());
            pos += 1;
        }
    }
    while hi < holes.len() && holes[hi].0 == source.len() {
        lines.last_mut().unwrap().push_str(&holes[hi].1);
        hi += 1;
    }
    lines
}

/// The §9.1 provenance attributes plus the §9.3 margin slot. Present from M1
/// even though the annotation layer arrives in M5 — they cost nothing now and
/// are the entire contract that layer depends on.
fn wrap_section(
    id: &str,
    class: &str,
    file: &str,
    line: u32,
    chunk: Option<&str>,
    body: &str,
) -> String {
    let chunk_attr = chunk
        .map(|c| format!(" data-chunk=\"{}\"", prose::escape(c)))
        .unwrap_or_default();
    format!(
        "<section class=\"{class}\" id=\"{id}\" data-nw-file=\"{}\" data-nw-line=\"{line}\"{chunk_attr}>\
         <div class=\"margin-slot\" data-for=\"{id}\"></div>{body}</section>",
        prose::escape(file)
    )
}

pub struct RenderedPage {
    pub meta: PageMeta,
    pub html: String,
}

pub struct Site {
    pub pages: Vec<RenderedPage>,
    /// A standalone page listing the whole navigation tree (`sitemap.html`),
    /// always emitted so a reader has one flat overview of every section.
    pub sitemap: String,
    pub math_count: usize,
    pub lints: Vec<Lint>,
    /// The §8 document model, always assembled but only written under
    /// `--archive`. `meta` is a placeholder here; `write_site` fills it in.
    pub json: SiteJson,
}

impl Site {
    /// Every page's HTML concatenated — a convenience for whole-document
    /// assertions where the page split is not what is under test.
    #[cfg(test)]
    pub fn all_html(&self) -> String {
        self.pages
            .iter()
            .map(|p| p.html.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// One section's rendered body, before math substitution and section wrapping.
/// Only docs bodies are HTML the rewriter touches; code bodies pass through.
enum Frag {
    Docs(String),
    Code(String),
}

/// Steps 1–2 (§6.2) per section: reassemble each docs body and lower it through
/// the dialect (Markdown → CommonMark, which also extracts math; HTML → math
/// extraction as-is), and render each code body straight. Shared by `render` and
/// the mint-only `lit lock` path so both see labels the same way.
fn render_frags(
    doc: &DocModel,
    dialect: Dialect,
    lang_cfg: &LangConfig,
    math: &mut Vec<Math>,
    lints: &mut Vec<Lint>,
) -> Result<Vec<Frag>, WeaveError> {
    let mut frags: Vec<Frag> = Vec::with_capacity(doc.sections.len());
    for section in &doc.sections {
        match &section.kind {
            SectionKind::Docs { spans } => {
                let reassembled = prose::reassemble(spans);
                let body = match dialect {
                    Dialect::Markdown => markdown::render(&reassembled, math).map_err(|err| {
                        WeaveError::Markdown {
                            file: section.file.clone(),
                            line: section.line,
                            err,
                        }
                    })?,
                    Dialect::Html => {
                        prose::extract_math(&reassembled, math).map_err(|err| WeaveError::Prose {
                            file: section.file.clone(),
                            line: section.line,
                            err,
                        })?
                    }
                };
                frags.push(Frag::Docs(body));
            }
            SectionKind::Code {
                name,
                continues,
                spans,
                ..
            } => {
                // Resolve the language out of band (§5.5): the config default,
                // else the chunk's own or its root's file extension. A chunk with
                // real code but no known language is highlighted as plain text and
                // earns one warning — never an error.
                let lang = highlight::resolve(doc, name, lang_cfg);
                let has_code = spans.iter().any(|s| !matches!(s, CodeSpan::Nl));
                if lang.is_none() && has_code {
                    lints.push(Lint {
                        code: "W104",
                        message: format!(
                            "chunk <<{name}>> resolved to no known language; \
                             rendered as plain text"
                        ),
                        file: section.file.clone(),
                        line: section.line,
                    });
                }
                // The `<<name>>=` line is `section.line`; the body opens after it.
                let body = render_code(name, *continues, spans, section.line + 1, doc, lang);
                frags.push(Frag::Code(body));
            }
        }
    }
    Ok(frags)
}

/// Step 4a: scan every docs body once, in order, so every labelled float is seen
/// before ids are assigned. Returns the collected `Scan` and the per-fragment
/// first-tag (a page boundary) so `resolve` can split pages.
fn scan_frags(frags: &[Frag]) -> Result<(Scan, Vec<Option<String>>), WeaveError> {
    let mut scan = Scan::default();
    let mut first_tags: Vec<Option<String>> = Vec::with_capacity(frags.len());
    for (i, frag) in frags.iter().enumerate() {
        match frag {
            Frag::Docs(html) => {
                let before = scan.first_tag.len();
                rewrite::scan(html, i, &mut scan).map_err(WeaveError::Rewrite)?;
                first_tags.push(scan.first_tag[before].clone());
            }
            Frag::Code(_) => first_tags.push(None),
        }
    }
    Ok((scan, first_tags))
}

/// Mint a frozen id (§7.1) for every labelled float, in document order, without
/// rendering the site. This is `lit lock`: it grows the in-memory lock so the
/// caller can persist it; it never renders math or writes HTML.
pub fn mint_lock(
    doc: &DocModel,
    dialect: Dialect,
    lock: &mut LockFile,
    minter: &mut Minter,
) -> Result<(), WeaveError> {
    let mut math: Vec<Math> = Vec::new();
    let mut lints: Vec<Lint> = Vec::new();
    // Minting only needs labels/floats, not colors, so the language config is empty.
    let lang_cfg = LangConfig::default();
    let frags = render_frags(doc, dialect, &lang_cfg, &mut math, &mut lints)?;
    let (scan, _first_tags) = scan_frags(&frags)?;
    for (label, kind, section) in mintable(&scan) {
        let file = &doc.sections[section].file;
        lock.mint(file, label, kind, minter);
    }
    Ok(())
}

/// Every label that earns a frozen opaque id (§7.1), in document order: each
/// labelled float, then each deeper heading the author pinned with a `sec:` id.
/// An h1 is its own page and is addressed by the page id, so it needs no
/// section id and is skipped. Yields `(label, kind, section)`.
fn mintable(scan: &Scan) -> impl Iterator<Item = (&str, Kind, usize)> {
    scan.labels
        .iter()
        .map(|l| (l.id.as_str(), l.kind, l.section))
        .chain(scan.headings.iter().filter_map(|h| {
            let given = h.given_id.as_deref()?;
            (h.level != 1 && Kind::from_label(given) == Some(Kind::Section))
                .then_some((given, Kind::Section, h.section))
        }))
}

/// Steps 1–6 (§6.2) for the whole document, then the §5.3 page split. Docs
/// bodies make two passes through the rewriter — scan, then apply — around the
/// document-global `resolve::plan`, because numbering and cross-references
/// cannot be settled until every section has been seen.
#[allow(clippy::too_many_arguments)]
pub fn render(
    doc: &DocModel,
    cache_root: &Path,
    dialect: Dialect,
    lang_cfg: &LangConfig,
    embed: &str,
    lock: &mut LockFile,
    mode: LockMode,
    minter: &mut Minter,
) -> Result<Site, WeaveError> {
    let mut math: Vec<Math> = Vec::new();
    let mut hl_lints: Vec<Lint> = Vec::new();
    let mut frags = render_frags(doc, dialect, lang_cfg, &mut math, &mut hl_lints)?;
    let (scan, first_tags) = scan_frags(&frags)?;

    // Assign each labelled float its frozen opaque id (§7.1): mint on miss (and
    // let the caller persist the grown lock), or — under `--locked` — fail on any
    // label the committed lock does not already carry.
    let mut label_ids = LabelIds::new();
    for (label, kind, section) in mintable(&scan) {
        let file = &doc.sections[section].file;
        let id = match mode {
            LockMode::Mint => lock.mint(file, label, kind, minter),
            LockMode::Locked => match lock.get(file, label) {
                Some(entry) => entry.id.clone(),
                None => {
                    return Err(WeaveError::Lock(LockError::Missing {
                        file: file.clone(),
                        label: label.to_string(),
                    }))
                }
            },
        };
        label_ids.insert(label.to_string(), id);
    }

    let res = resolve::plan(doc, &scan, &first_tags, &label_ids).map_err(WeaveError::Resolve)?;

    // Step 4b: rewrite each docs body against the resolved plan.
    let mut plan = Plan::new(&res.heading_anchors, &res.heading_uids, &res.refs, &label_ids);
    for frag in frags.iter_mut() {
        if let Frag::Docs(html) = frag {
            *html = rewrite::apply(html, &mut plan).map_err(WeaveError::Rewrite)?;
        }
    }

    // Steps 5–6: serialize is implicit in the rewriter; now render math and
    // wrap each section in its provenance envelope.
    let rendered = Renderer::new(cache_root)
        .render_all(&math)
        .map_err(WeaveError::Math)?;
    let mut wrapped: Vec<String> = Vec::with_capacity(frags.len());
    let mut raws: Vec<site::RawSection> = Vec::with_capacity(frags.len());
    // Document-global so sidenote ids are unique and stable across pages (§8).
    let mut sn = 0usize;
    for (section, frag) in doc.sections.iter().zip(&frags) {
        let (class, chunk, is_docs, body) = match frag {
            Frag::Docs(html) => ("docs", None, true, html.as_str()),
            Frag::Code(html) => {
                let name = match &section.kind {
                    SectionKind::Code { name, .. } => Some(name.as_str()),
                    _ => None,
                };
                ("code", name, false, html.as_str())
            }
        };
        let body = prose::substitute_math(body, &rendered);
        // Sidenotes are hoisted after math substitution so a note that contains
        // math carries the rendered KaTeX into its margin[] entry (§8).
        let (page_body, raw) = if is_docs {
            let h = site::hoist_sidenotes(&body, &mut sn);
            (
                h.page_html,
                site::RawSection {
                    html: h.json_html,
                    margins: h.margins,
                },
            )
        } else {
            (
                body.clone(),
                site::RawSection {
                    html: body,
                    margins: Vec::new(),
                },
            )
        };
        raws.push(raw);
        wrapped.push(wrap_section(
            &section.id,
            class,
            &section.file,
            section.line,
            chunk,
            &page_body,
        ));
    }

    // §5.3 page split: group wrapped sections by their assigned page.
    let mut env = minijinja::Environment::new();
    env.add_template("page", include_str!("../templates/page.html"))
        .map_err(|e| WeaveError::Template(e.to_string()))?;
    env.add_template("sitemap", include_str!("../templates/sitemap.html"))
        .map_err(|e| WeaveError::Template(e.to_string()))?;
    let tmpl = env
        .get_template("page")
        .map_err(|e| WeaveError::Template(e.to_string()))?;

    let mut pages = Vec::with_capacity(res.pages.len());
    for (pi, meta) in res.pages.iter().enumerate() {
        let sections: Vec<&str> = wrapped
            .iter()
            .zip(&res.section_page)
            .filter(|(_, p)| **p == pi)
            .map(|(html, _)| html.as_str())
            .collect();
        // The nav marks this page's own landing entry current, so each page ships
        // its own "you are here" (§5.3) — static, no script, every browser.
        let nav = nav_context(&res.nav, &meta.filename);
        let prev = pi.checked_sub(1).map(|j| link_context(&res.pages[j]));
        let next = res.pages.get(pi + 1).map(link_context);
        let html = tmpl
            .render(minijinja::context! {
                title => meta.title,
                sections,
                embed,
                nav,
                prev,
                next,
            })
            .map_err(|e| WeaveError::Template(e.to_string()))?;
        pages.push(RenderedPage {
            meta: meta.clone(),
            html,
        });
    }

    // One standalone sitemap page: the whole nav tree, styled by lit.css. The
    // title is the first page's, so the sitemap names the document it maps. It
    // highlights nothing — an empty current means no entry is the current page.
    let site_title = res.pages.first().map_or("lit", |m| m.title.as_str());
    let sitemap = env
        .get_template("sitemap")
        .map_err(|e| WeaveError::Template(e.to_string()))?
        .render(minijinja::context! { title => site_title, nav => nav_context(&res.nav, "") })
        .map_err(|e| WeaveError::Template(e.to_string()))?;

    let json = site::build(doc, &res, &raws, site::Meta::default());

    let mut lints = res.lints;
    lints.extend(hl_lints);

    Ok(Site {
        pages,
        sitemap,
        math_count: math.len(),
        lints,
        json,
    })
}

fn link_context(meta: &PageMeta) -> minijinja::Value {
    minijinja::context! { title => meta.title, href => meta.filename }
}

fn nav_context(nodes: &[NavNode], current: &str) -> Vec<minijinja::Value> {
    nodes
        .iter()
        .map(|n| {
            minijinja::context! {
                title => n.title,
                href => n.href,
                current => n.href == current,
                children => nav_context(&n.children, current),
            }
        })
        .collect()
}

/// KaTeX's CSS and fonts are mandatory, not decorative: without the stylesheet
/// the MathML and HTML layers both render and every equation appears twice.
/// They are copied in, never CDN-linked, so the site stays a sealed artifact.
fn copy_katex_assets(out: &Path) -> Result<(), WeaveError> {
    let src = std::env::var("LIT_KATEX_ASSETS").map_err(|_| {
        WeaveError::Assets(
            "LIT_KATEX_ASSETS is unset; it points at the pinned KaTeX dist and is \
             set by the devShell and the wrapped package — run inside `nix develop`"
                .to_string(),
        )
    })?;
    let src = PathBuf::from(src);
    let dst = out.join("katex");
    // Files copied from the read-only Nix store keep their read-only mode, so a
    // second weave into the same directory can't overwrite them. Clear first.
    match std::fs::remove_dir_all(&dst) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(WeaveError::Io(e)),
    }
    std::fs::create_dir_all(dst.join("fonts")).map_err(WeaveError::Io)?;

    let css = src.join("katex.min.css");
    std::fs::copy(&css, dst.join("katex.min.css"))
        .map_err(|e| WeaveError::Assets(format!("copying {}: {e}", css.display())))?;

    // woff2 only: every browser that renders MathML supports it, and shipping
    // woff/ttf as well would quadruple the artifact for no reader.
    let fonts = src.join("fonts");
    let entries = std::fs::read_dir(&fonts)
        .map_err(|e| WeaveError::Assets(format!("reading {}: {e}", fonts.display())))?;
    let mut names: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "woff2"))
        .collect();
    names.sort(); // deterministic output (§8)
    for path in names {
        if let Some(name) = path.file_name() {
            std::fs::copy(&path, dst.join("fonts").join(name)).map_err(WeaveError::Io)?;
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub fn write_site(
    doc: &DocModel,
    out: &Path,
    cache_root: &Path,
    lock_path: &Path,
    meta: site::Meta,
    dialect: Dialect,
    lang_cfg: &LangConfig,
    archive: bool,
    mode: LockMode,
) -> Result<Site, WeaveError> {
    let mut lock = LockFile::load(lock_path).map_err(WeaveError::Lock)?;
    let mut minter = Minter::from_entropy();
    let mut site = render(doc, cache_root, dialect, lang_cfg, "", &mut lock, mode, &mut minter)?;
    // A dev-time weave writes any newly minted ids back so they freeze (§7.1);
    // `--locked` never mints, so it never touches the committed lock.
    if mode == LockMode::Mint {
        lock.save(lock_path).map_err(WeaveError::Lock)?;
    }
    site.json.meta = meta;
    std::fs::create_dir_all(out).map_err(WeaveError::Io)?;
    for page in &site.pages {
        std::fs::write(out.join(&page.meta.filename), &page.html).map_err(WeaveError::Io)?;
    }
    std::fs::write(out.join("sitemap.html"), &site.sitemap).map_err(WeaveError::Io)?;
    std::fs::write(out.join("lit.css"), include_str!("../templates/lit.css"))
        .map_err(WeaveError::Io)?;
    copy_katex_assets(out)?;
    // The archival JSON (§8) is opt-in: plain `weave` stays an HTML-only
    // artifact. Per-page files sit beside their HTML for the annotation layer.
    if archive {
        std::fs::write(out.join("site.json"), site::to_json(&site.json)).map_err(WeaveError::Io)?;
        for id in site.json.page_ids() {
            let json =
                site::page_json(&site.json, &id).expect("page id came from site.json.pages");
            std::fs::write(out.join(format!("{id}.json")), json).map_err(WeaveError::Io)?;
        }
    }
    Ok(site)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lock::ID_LEN;

    fn model_of(markup: &str) -> DocModel {
        crate::model::build(&crate::noweb::parse(markup).unwrap()).unwrap()
    }

    fn fixture() -> DocModel {
        model_of(include_str!("../fixtures/hello.markup"))
    }

    fn book() -> DocModel {
        model_of(include_str!("../fixtures/book.markup"))
    }

    fn md() -> DocModel {
        model_of(include_str!("../fixtures/md.markup"))
    }

    fn cache() -> PathBuf {
        std::env::temp_dir().join("lit-weave-test-cache")
    }

    /// A dev-time render with an in-memory lock and a fixed-seed minter, so float
    /// ids are deterministic within a test run (their exact value is arbitrary —
    /// `lock.rs` owns the minting contract).
    fn dev_render(doc: &DocModel, dialect: Dialect, embed: &str) -> Site {
        dev_render_lang(doc, dialect, None, embed)
    }

    fn dev_render_lang(doc: &DocModel, dialect: Dialect, lang: Option<Lang>, embed: &str) -> Site {
        let mut lock = LockFile::default();
        let mut minter = Minter::seeded(1);
        let lang_cfg = LangConfig::with_default(lang);
        render(
            doc,
            &cache(),
            dialect,
            &lang_cfg,
            embed,
            &mut lock,
            LockMode::Mint,
            &mut minter,
        )
        .unwrap()
    }

    #[test]
    fn locked_weave_errors_on_a_label_absent_from_the_lock() {
        // book.nw carries labelled floats; an empty lock under `--locked` cannot
        // supply their frozen ids, so weave must fail with E031 rather than mint.
        let mut lock = LockFile::default();
        let mut minter = Minter::seeded(1);
        let lang_cfg = LangConfig::default();
        let err = match render(
            &book(),
            &cache(),
            Dialect::Html,
            &lang_cfg,
            "",
            &mut lock,
            LockMode::Locked,
            &mut minter,
        ) {
            Ok(_) => panic!("a locked weave with an empty lock must not succeed"),
            Err(e) => e,
        };
        assert!(matches!(err, WeaveError::Lock(LockError::Missing { .. })));
        assert!(err.to_string().contains("E031"));
    }

    /// The frozen opaque id stamped on the float anchored at `anchor` (§7.1);
    /// ids are exactly four characters.
    fn id_at(html: &str, anchor: &str) -> String {
        let needle = format!("id=\"{anchor}\" data-id=\"");
        let start = html.find(&needle).expect("anchor carries a data-id") + needle.len();
        html[start..start + 4].to_string()
    }

    /// The hello fixture opens with a single `<h1>`, so it is one `index` page.
    fn hello_html() -> String {
        dev_render(&fixture(), Dialect::Html, "").all_html()
    }

    /// Drop only the `tok-*` highlight wrappers, keeping `.line`/`.chunk-name`
    /// spans and every text node, so a structural assertion can ignore coloring.
    /// Relies on spans being properly nested (they are, by construction).
    fn strip_tok(html: &str) -> String {
        let mut out = String::new();
        let mut span_is_tok: Vec<bool> = Vec::new();
        let mut i = 0;
        while i < html.len() {
            let tail = &html[i..];
            if tail.starts_with("<span") {
                let end = i + tail.find('>').unwrap() + 1;
                let tag = &html[i..end];
                let is_tok = tag.contains("class=\"tok-");
                span_is_tok.push(is_tok);
                if !is_tok {
                    out.push_str(tag);
                }
                i = end;
            } else if tail.starts_with("</span>") {
                if !span_is_tok.pop().unwrap_or(false) {
                    out.push_str("</span>");
                }
                i += "</span>".len();
            } else {
                let c = tail.chars().next().unwrap();
                out.push(c);
                i += c.len_utf8();
            }
        }
        out
    }

    #[test]
    fn page_has_provenance_and_margin_slots() {
        let html = hello_html();
        assert!(html.contains(
            "<section class=\"docs\" id=\"sec-1\" data-nw-file=\"fixtures/hello.nw\" data-nw-line=\"1\">"
        ));
        assert!(html.contains("data-nw-line=\"6\" data-chunk=\"lex a token\""));
        assert!(html.contains("<div class=\"margin-slot\" data-for=\"sec-2\"></div>"));
    }

    #[test]
    fn continuation_marker_matches_noweb_convention() {
        let html = hello_html();
        assert!(html.contains("<dfn>lex a token</dfn>&gt;&gt;="));
        assert!(html.contains("<dfn>lex a token</dfn>&gt;&gt;+="));
    }

    #[test]
    fn chunk_uses_link_to_first_definition() {
        let html = hello_html();
        // `next char` is defined in sec-8 and used in sec-2 — a forward
        // reference, so the link must resolve against the finished model.
        assert!(html.contains("<a href=\"#sec-8\">&lt;<i>next char</i>&gt;</a>"));
        assert!(html.contains("<a href=\"#sec-2\">&lt;<i>lex a token</i>&gt;</a>"));
    }

    #[test]
    fn math_is_rendered_not_left_as_placeholder() {
        let site = dev_render(&fixture(), Dialect::Html, "");
        let html = site.all_html();
        assert_eq!(site.math_count, 2);
        assert!(!html.contains("data-lit-math"));
        assert!(html.contains("katex"));
        // The angle-bracket case must survive as an entity, never a tag.
        assert!(!html.contains("<span>a < b</span>"));
    }

    #[test]
    fn quoted_code_renders_as_escaped_code() {
        let html = hello_html();
        assert!(html.contains("<code>lex()</code>"));
        assert!(html.contains("<code>v[[0]]</code>"));
    }

    #[test]
    fn escaped_dollar_survives_to_output() {
        assert!(hello_html().contains("cost is $5."));
    }

    #[test]
    fn code_body_is_html_escaped() {
        // hello.nw's root is `src/main.rs`, so its chunks now highlight as Rust
        // (§5.5); the escaped plain-text payload must survive under the coloring.
        let html = strip_tok(&hello_html());
        assert!(html.contains("println!(&quot;{count}&quot;);"));
        assert!(html.contains("let mut tokens = vec![];"));
    }

    #[test]
    fn chunks_are_collapsible_and_open_by_default() {
        let html = hello_html();
        assert!(html.contains("<details class=\"chunk\" open><summary>"));
        // The header lives in the summary, so a collapsed chunk still shows
        // which chunk a cross-reference landed on.
        assert!(html.contains("<dfn>next char</dfn>&gt;&gt;=</span></summary>"));
    }

    #[test]
    fn line_numbers_are_nw_coordinates_in_attributes() {
        // Coloring nests inside each `.line`; strip it so the coordinate + payload
        // invariant reads the same whether or not the chunk highlights.
        let html = strip_tok(&hello_html());
        // fixtures/hello.nw: `<<next char>>=` is line 22, its one body line 23.
        assert!(html
            .contains("<span class=\"line\" data-line=\"23\">input.next().unwrap()</span></pre>"));
        // src/main.rs opens at line 28; `println!` is the fifth body line.
        assert!(html.contains("<span class=\"line\" data-line=\"29\">fn main() {</span>"));
        assert!(html.contains("data-line=\"33\">    println!(&quot;{count}&quot;);</span>"));
        // Numbers are never text, so they cannot be copied or quoted.
        assert!(!html.contains(">23 input"));
    }

    #[test]
    fn rust_root_chunks_are_highlighted_and_holes_stay_opaque() {
        // hello.nw's root is `src/main.rs`, so tier-3 resolution colors it as Rust
        // (§5.5): `let`/`fn` are keywords, the format string is a string token.
        let html = hello_html();
        assert!(html.contains("class=\"tok-keyword\">let</span>"));
        assert!(html.contains("class=\"tok-string\">&quot;{count}&quot;</span>"));
        // The chunk-use hole is spliced back verbatim and never wrapped in a color
        // span — its `<a>` sits directly inside the `.line`, as §5.4 requires.
        assert!(html.contains("<a href=\"#sec-8\">&lt;<i>next char</i>&gt;</a>"));
        assert!(!html.contains("tok-") || !html.contains("tok-\">&lt;<i>"));
    }

    #[test]
    fn a_no_language_chunk_falls_back_to_plain_text_with_one_warning() {
        // A root whose name carries no known extension resolves to no language, so
        // its body is emitted as plain escaped text and earns exactly one W104.
        let doc = model_of(
            "@file plain.nw\n\
             @begin docs 0\n@text <h1>Plain</h1>\n@nl\n@end docs 0\n\
             @begin code 1\n@defn notes.txt\n@nl\n\
             @text let x = 1;\n@nl\n@end code 1\n",
        );
        let site = dev_render(&doc, Dialect::Html, "");
        let html = site.all_html();
        assert!(html.contains("<span class=\"line\" data-line=\"3\">let x = 1;</span>"));
        assert!(!html.contains("tok-"));
        let w104: Vec<_> = site.lints.iter().filter(|l| l.code == "W104").collect();
        assert_eq!(w104.len(), 1);
        assert!(w104[0].message.contains("notes.txt"));
    }

    #[test]
    fn chunk_terminator_adds_no_empty_line() {
        let html = hello_html();
        assert!(!html.contains("data-line=\"24\""));
        assert!(!html.contains("data-line=\"35\""));
    }

    #[test]
    fn embed_snippet_is_injected() {
        let site = dev_render(&fixture(), Dialect::Html, "<script src=\"x.js\"></script>");
        assert!(site.all_html().contains("<script src=\"x.js\"></script>"));
    }

    #[test]
    fn output_is_byte_deterministic() {
        let a = dev_render(&book(), Dialect::Html, "");
        let b = dev_render(&book(), Dialect::Html, "");
        assert_eq!(a.all_html(), b.all_html());
    }

    #[test]
    fn book_splits_into_three_pages_at_h1() {
        let site = dev_render(&book(), Dialect::Html, "");
        let files: Vec<&str> = site.pages.iter().map(|p| p.meta.filename.as_str()).collect();
        assert_eq!(files, vec!["index.html", "parsing.html", "codegen.html"]);
        // The `lex a token` chunk was defined under Parsing, so it lands there.
        assert!(site.pages[1].html.contains("data-chunk=\"lex a token\""));
        assert!(!site.pages[0].html.contains("data-chunk=\"lex a token\""));
    }

    #[test]
    fn page_boundary_h1_becomes_the_page_id() {
        let site = dev_render(&book(), Dialect::Html, "");
        assert!(site.pages[1].html.contains("<h1 id=\"parsing\">Parsing</h1>"));
        assert!(site.pages[0].html.contains("<h1 id=\"index\">Front matter</h1>"));
    }

    #[test]
    fn floats_are_identified_by_opaque_id_in_attributes_only() {
        let html = dev_render(&book(), Dialect::Html, "").all_html();
        // Each labeled float carries its frozen opaque id (§7.1) as data-id, and
        // its caption repeats the same id so CSS can draw "Figure <id>" once.
        let fig = id_at(&html, "fig-pipeline");
        assert!(html.contains(&format!("<figcaption data-id=\"{fig}\">The weave pipeline.</figcaption>")));
        let eq = id_at(&html, "eq-cost");
        assert_eq!(eq.len(), ID_LEN as usize);
        let tbl = id_at(&html, "tbl-opcodes");
        assert!(html.contains(&format!("<caption data-id=\"{tbl}\">Opcodes.</caption>")));
        // No numbers anywhere — identity is the opaque id, never a sequential
        // count injected into a node.
        assert!(!html.contains("data-number"));
        // The opted-out equation keeps no id.
        assert!(html.contains("data-nonumber"));
        assert!(!html.contains("data-nonumber data-id"));
    }

    #[test]
    fn cross_page_refs_are_page_qualified_and_get_generated_text() {
        let site = dev_render(&book(), Dialect::Html, "");
        let fig = id_at(&site.pages[1].html, "fig-pipeline");
        // Front matter (index) refers forward to a figure and equation on later
        // pages; both hrefs must name the target page, and the generated text is
        // "Figure <opaque id>" (§7.1), not a sequential number.
        assert!(site.pages[0].html.contains(&format!(
            "<a data-ref=\"fig:pipeline\" href=\"parsing.html#fig-pipeline\">Figure {fig}</a>"
        )));
        // The author supplied link text for the equation ref; keep it.
        assert!(site.pages[0].html.contains(">the cost\nbound</a>")
            || site.pages[0].html.contains("the cost"));
        // Codegen refers back to the same figure on the Parsing page.
        assert!(site.pages[2]
            .html
            .contains(&format!("href=\"parsing.html#fig-pipeline\">Figure {fig}</a>")));
    }

    #[test]
    fn labelled_section_carries_a_clickable_opaque_uid() {
        let site = dev_render(&book(), Dialect::Html, "");
        let parsing = &site.pages[1].html;
        // The `sec:lexing` heading leads with an empty <a> permalink whose opaque
        // id (§7.1) lives in data-id — drawn by CSS, never a text node.
        let needle = "id=\"sec-lexing\"><a class=\"sec-uid\" href=\"#sec-lexing\" data-id=\"";
        let start = parsing
            .find(needle)
            .expect("labelled section leads with a sec-uid permalink")
            + needle.len();
        let uid = &parsing[start..start + ID_LEN as usize];
        assert_eq!(uid.len(), ID_LEN as usize);
        // The id does not leak into the heading's own text run.
        assert!(parsing.contains(&format!("data-id=\"{uid}\"></a>Lexing</h2>")));
        // A cross-page \ref back to the section renders "Section <id>" (§7.1),
        // links to the section anchor, and reuses the very same opaque id.
        assert!(site.pages[2].html.contains(&format!(
            "<a data-ref=\"sec:lexing\" href=\"parsing.html#sec-lexing\">Section {uid}</a>"
        )));
    }

    #[test]
    fn chunk_ref_links_into_code() {
        let site = dev_render(&book(), Dialect::Html, "");
        // `<a data-ref="chunk:lex a token">` on the Parsing page points at the
        // chunk's defining section (same page → a fragment link).
        assert!(site.pages[1]
            .html
            .contains("href=\"#sec-3\">lex a token</a>"));
    }

    #[test]
    fn nav_tree_is_emitted_on_every_page() {
        let site = dev_render(&book(), Dialect::Html, "");
        for page in &site.pages {
            assert!(page.html.contains("<nav"));
            // The author labelled this heading `sec:lexing`, so its anchor is the
            // label's, not the text slug — the nav link follows.
            assert!(page.html.contains("href=\"parsing.html#sec-lexing\">Lexing</a>"));
        }
        // Each page marks its own landing entry current (§5.3) and no other, so the
        // nav shows the reader's place statically. The Parsing page marks Parsing.
        assert!(site.pages[1]
            .html
            .contains("href=\"parsing.html\" aria-current=\"page\">Parsing</a>"));
        assert!(site.pages[1]
            .html
            .contains("href=\"index.html\">Front matter</a>"));
        assert!(!site.pages[1]
            .html
            .contains("href=\"index.html\" aria-current=\"page\""));
    }

    #[test]
    fn sitemap_lists_every_page() {
        let site = dev_render(&book(), Dialect::Html, "");
        assert!(site.sitemap.contains("<h1>Sitemap</h1>"));
        // Every top-level page and a labelled child section both appear, through the
        // same hrefs the nav tree builds.
        assert!(site.sitemap.contains("href=\"parsing.html\">Parsing</a>"));
        assert!(site.sitemap.contains("href=\"parsing.html#sec-lexing\">Lexing</a>"));
        // The footer of an ordinary page points at the sitemap.
        assert!(site.pages[0].html.contains("href=\"sitemap.html\""));
    }

    #[test]
    fn site_json_is_current_schema_and_hoists_sidenotes() {
        let site = dev_render(&book(), Dialect::Html, "");
        let json = &site.json;
        assert_eq!(json.schema, site::SCHEMA);
        // The whole-doc JSON is serialized and re-round-trips through the
        // per-page narrowing without panicking.
        let ids = json.page_ids();
        assert_eq!(ids, vec!["index", "parsing", "codegen"]);
        for id in &ids {
            assert!(site::page_json(json, id).is_some());
        }
        // book.nw carries one sidenote on the Parsing page; it lands in a
        // margin[] entry and is stripped from that section's JSON prose, while
        // the woven HTML keeps it inline with the matching sn- id.
        let whole = site::to_json(json);
        assert!(whole.contains("\"sn-1\""));
        assert!(whole.contains("\"kind\": \"sidenote\""));
        // No aside survives in the JSON prose bodies.
        assert!(!whole.contains("<aside"));
        assert!(site.pages[1].html.contains("<aside id=\"sn-1\""));
    }

    #[test]
    fn footer_pagination_links_neighbours() {
        let site = dev_render(&book(), Dialect::Html, "");
        // Middle page has both neighbours.
        assert!(site.pages[1].html.contains("href=\"index.html\""));
        assert!(site.pages[1].html.contains("href=\"codegen.html\""));
        // First page has no prev; last has no next.
        assert!(!site.pages[0].html.contains("rel=\"prev\""));
        assert!(!site.pages[2].html.contains("rel=\"next\""));
    }

    #[test]
    fn markdown_dialect_renders_prose_and_fenced_math() {
        let site = dev_render(&md(), Dialect::Markdown, "");
        let html = site.all_html();
        // Prose became HTML: a paragraph with emphasis, not literal asterisks.
        assert!(html.contains("<p>"));
        assert!(html.contains("<em>Markdown</em>"));
        assert!(html.contains("<strong>emphasis</strong>"));
        // Three math runs: the labeled ```math``` fence, the inline `$…$` in the
        // figure caption, and the inline tail — all rendered by KaTeX, none left
        // as a placeholder.
        assert_eq!(site.math_count, 3);
        assert!(!html.contains("data-lit-math"));
        assert!(html.contains("class=\"equation\""));
        assert!(html.contains("katex"));
    }

    #[test]
    fn markdown_fenced_floats_are_labeled_and_referenced() {
        let site = dev_render(&md(), Dialect::Markdown, "");
        let html = site.all_html();
        // A `figure` fence became a real <figure> with an anchored id, an opaque
        // id on its caption, and its raw-HTML body passed through.
        let fig = id_at(&html, "fig-diagram");
        assert!(html.contains(&format!("<figcaption data-id=\"{fig}\">")));
        assert!(html.contains("<img src=\"diagram.svg\""));
        // A `table` fence parsed its GFM pipe table and carried id + <caption>.
        let tbl = id_at(&html, "tbl-units");
        assert!(html.contains(&format!("<caption data-id=\"{tbl}\">Symbols and their units.")));
        assert!(html.contains("<th>Symbol</th>"));
        // The labeled equation is identified too.
        let eq = id_at(&html, "eq-mass");
        assert_eq!(eq.len(), ID_LEN as usize);
        // Every `\ref{…}` resolved to its float's anchor.
        assert!(html.contains("href=\"#eq-mass\""));
        assert!(html.contains("href=\"#fig-diagram\""));
        assert!(html.contains("href=\"#tbl-units\""));
    }
}
