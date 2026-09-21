@
# cobito — a web-first literate programming system

This document is cobito's own specification, told as a literate program. cobito
is a literate programming system (the command is `cob`): an author writes a
human-readable document first,
then shows how each part of the code comes together. This document holds itself to
that standard.

The specification does not live in one file any more. Each rule lives in the
module that implements it. A module opens with the prose that specifies its job,
then shows the code that meets it. This top-level document holds the parts that
cross every module — the goals, the vocabulary, the architecture — and points to
the module that owns each detail.

## Goals {#sec:teiT}

cob has six goals.

1. Web-first. The primary woven artifact is a multi-page website, not a PDF. Print
   is not a v1 concern.
2. noweb-compatible. Source files are genuine \code{.cob} files. \code{notangle} consumes
   them unchanged. cob is language-agnostic because noweb is.
3. Static generator only. cob is the weaver and the tangler. It ships no server.
   Margin commenting is a separate tool with its own spec, \code{ANNOTATIONS.md}; cob's
   sole obligation to it is annotation-ready HTML (\code{rewrite.rs}).
4. JSON is the contract. Every HTML page is a pure function of a JSON document. No
   exceptions (\code{site.rs}).
5. Review loop. An AI agent reads annotations and proposes revisions to the \code{.cob}
   source (see "The review loop" below).
6. Self-hosting. cob is written in itself: each \code{.cob} file tangles to its part of
   the Rust crate (see "Self-hosting" below).

## Non-goals {#sec:68J6}

- PDF or print output. A \code{--tex} backend may come later.
- Pretty-printing or code reformatting. cob never reflows, re-indents, or rewrites
  the bytes a reader sees. Code chunks render exactly as written — noweb's
  position, and cob keeps it. Syntax highlighting only colors those unchanged
  bytes (\code{highlight.rs}), so this line still stands.
- cweb's \code{@d} macros. noweb has no equivalent, because \code{#define} is C-specific.
  Named chunks cover the need.
- A WYSIWYG authoring UI.
- A comment or annotation server. That is a separate tool (\code{ANNOTATIONS.md}).
- Multi-user real-time collaboration. Comments are asynchronous.

## Vocabulary {#sec:lxbi}

```table
\caption{The words this document uses.}
| Term | Meaning |
|---|---|
| project | A directory with a \code{cob.toml}. It holds one or more documents. |
| document | An ordered list of \code{.cob} files woven into one site with unified numbering. It has an id, used in URLs. |
| chunk | noweb's unit: a docs chunk (prose) or a code chunk (named, tangleable). |
| section | cob's unit of anchoring and rendering. One chunk makes one section. |
| page | An output HTML file. It holds a contiguous run of sections. |
| root | A code chunk that tangles to a file on disk. |
| node | An addressable heading and the content under it, up to the next heading at the same or a shallower level. The heading nesting is the node tree. |
| transclusion | Showing one node a second time in another place, as a scoped copy with a backlink, not a link. |
```

A document may span several \code{.cob} files, because \code{markup} accepts several and
emits a file marker between them. The numbering, the labels, and the chunk
resolution are all document-wide.

## Architecture {#sec:8GfD}

cob shells out to noweb's front end, not its back end. \code{markup} converts a \code{.cob}
file into noweb's line-oriented pipeline format. cob consumes that as its IR and
owns everything downstream. cob never uses \code{noweave}: it owns prose-to-HTML
regardless, and the pipeline format hands it the chunk structure as data rather
than as generated markup it would have to scrape back.

```verbatim
  PHASE 1 — static generator (no Python, no server)

  *.cob ──> markup ──> pipeline IR ──┐
                                    │
   ┌────────────────────────────────┴───────────────────────────┐
   │ Rust                                                        │
   │  1. parse IR       → chunk list                             │
   │  2. resolve        → chunk graph, defs/uses, continuations  │
   │  3. prose pipeline → math out, HTML parse, refs, ids        │
   │  4. number         → figures, tables, equations, chunks     │
   │  5. split          → pages, nav tree, prev/next             │
   │  6. serialize      → site.json                              │
   │  7. render         → minijinja + templates/                 │
   └────────────────────────────────┬───────────────────────────┘
                                    │
                              _site/{*.html,*.json,static/}

  *.cob ──> notangle -R'src/main.rs' ──> src/main.rs


  ANNOTATION LAYER — separate tool, separate spec (ANNOTATIONS.md)

  _site/*.html ──(overlay / embed)──> margin comments on woven pages
        │  HTML carries provenance attributes (rewrite.rs)
        ▼
  annotations (W3C JSON) ──> cob review ──> unified diff against *.cob
```

## Where each part lives {#sec:Fv9U}

Each module carries the specification for its own job. This is the reading order.

```table
\caption{Each concern and the module that owns it.}
| Concern | Module |
|---|---|
| The noweb boundary: the IR, verified noweb behavior, \code{markup} | \code{src/noweb.rs.cob} |
| The document model: chunk continuation, roots, line counting | \code{src/model.rs.cob} |
| The project manifest, the prose dialect, config keys | \code{src/config.rs.cob} |
| The prose pipeline: reassembly, math substitution, ordering | \code{src/prose.rs.cob} |
| The Markdown dialect and fenced-float directives | \code{src/markdown.rs.cob} |
| Math rendering: KaTeX at weave time, the cache | \code{src/math.rs.cob} |
| Labels, numbering, cross-references, the resolver | \code{src/resolve.rs.cob} |
| Stable ids and the lock file | \code{src/lock.rs.cob} |
| Source-side section anchors: auto ids, \code{rename-label} | \code{src/section.rs.cob} |
| Prose rewriting, the HTML parser, the annotation contract | \code{src/rewrite.rs.cob} |
| The \code{site.json} contract and page boundaries | \code{src/site.rs.cob} |
| The weaver: rendering a code chunk | \code{src/weave.rs.cob} |
| Syntax highlighting | \code{src/highlight.rs.cob} |
| The node model and transclusion | \code{src/transclude.rs.cob} |
| Tangling | \code{src/tangle.rs.cob} |
| Long-form diagnostics | \code{src/diag.rs.cob} |
| The CLI | \code{src/main.rs.cob} |
| The build, told as a literate program | \code{flake.nix.cob} |
```

## The review loop {#sec:av7Q}

\code{cob review} closes the loop from a reader's margin comment back to the source. It
runs in six steps.

1. It fetches the open annotations as W3C Web Annotation JSON from the configured
   backend. A backend is an adapter; the agent codes against the W3C shape only.
2. It maps each annotation to source. The annotation's exact-quote selector locates
   the text on the woven page. The enclosing section's provenance attributes locate
   the \code{.cob} region.
3. It asks for a unified diff against the \code{.cob} source — never against the woven
   HTML.
4. It validates the patch: the patch applies cleanly, \code{cob weave} still succeeds,
   and \code{cob tangle} output is unchanged unless a thread explicitly asked for a code
   change.
5. It presents a reviewable diff. Nothing auto-commits.
6. On acceptance, the addressed threads resolve with a pointer to the resulting
   revision.

Step 4 holds the important safety property: prose feedback must not silently alter
the program.

## Self-hosting {#sec:7p6J}

cob is written in itself. The path had three stages. First, cob was written
normally in Rust. Second, once weave and tangle were stable, each module was ported
into a \code{.cob} file that tangles into the existing tree; CI ran \code{cob tangle --check}
to assert the committed \code{.rs} matched what the literate source made. Third, the
flip: the \code{.cob} files became the only source of truth.

The flip is done. The whole Rust crate and the stylesheet are literate, and no
\code{.rs} or \code{.css} is committed — each one comes from a \code{.cob}. The one authority is the
set of \code{.cob} files. The flake build is two stages. A tangler must exist before
anything can be tangled, so stage 0 uses \code{notangle}, noweb's own tangler, which
needs no \code{cob}. \code{notangle} tangles every \code{.cob} into a tree that \code{cargo} builds, and
stage 1's \code{cob} tangles every \code{.cob} again. Both trees compile to a working \code{cob}.

With no committed \code{.rs} to check a tangle against, \code{checks.selfhost} proves the
bootstrap another way: \code{notangle} and \code{cob tangle} must make byte-identical output
for every module. The tangle differential (§15) already proves the two agree on a
fixture; self-host extends it to the whole crate. Their agreement is the whole
safety of the loop — because the two tanglers make the same source, the shipped
binary is the same whichever one built stage 0.

Removing the committed seed also removes the one risk self-hosting used to add: a
weaver bug can no longer poison a committed artifact, because there is none. The
bootstrap rests on \code{notangle}, a stable external tool, not on cob itself.

The one file that stays committed is \code{flake.nix}, because Nix must read it before
any tangle can run. \code{flake.nix.cob} is cob's own build file told as a literate
program; it tangles byte-for-byte into the committed \code{flake.nix}. \code{checks.dogfood}
runs \code{cob tangle --check} so the literate source and this one bootstrap file never
drift, and it weaves the page to prove the Nix grammar colored it — self-hosting the
highlighter, which is why Nix is the second grammar.

## Nix {#sec:JPcq}

The build is flake-based. \code{pkgs.noweb} is a genuine runtime dependency in phase 1,
not merely a test oracle, so the CLI is wrapped to put both \code{\${noweb}/bin} and
\code{\${noweb}/lib/noweb} on PATH — the pipeline stages are not on \code{bin/}. The shape is
deliberately minimal: a plain \code{rustPlatform.buildRustPackage}, no extra flake
inputs, with crane or a rust overlay held back until a concrete need appears.

The flake carries the checks that guard cob's invariants: a build with the hermetic
cargo tests, a noweb-drift check that diffs \code{markup} output against the pinned
fixtures, a determinism check that weaves twice and byte-diffs, a tangle
differential against \code{notangle}, and the self-host and dogfood checks above. Because
a flake sees only git-tracked files, a new file must be added to git before any
\code{nix} command will see it. The full build lives in \code{flake.nix.cob}.

## Testing {#sec:LEQV}

Each layer has its own strategy.

```table
\caption{The test strategy for each layer.}
| Layer | Strategy |
|---|---|
| IR parser | Golden tests over pinned \code{markup} output; guards against noweb version drift. |
| Prose pipeline | Snapshot tests per stage, especially math-extraction edge cases. |
| Numbering and refs | Property test: every reference resolves; numbers are dense and monotonic. |
| Split | Property test: concatenating all pages' sections reproduces the section list. |
| Tangle | Differential against \code{notangle} on a fixture corpus. |
| Determinism | Weave twice, diff. |
| Annotation contract | Assert every section carries its id and provenance and a margin slot. |
```

## Milestones {#sec:UnND}

Phase 1, the static generator, is complete: the flake and IR parser (M0), the prose
pipeline and math (M1), numbering and page splitting and templates (M2), tangle via
notangle (M3), and \code{site.json} with the manifest and diagnostics (M4).

Phase 2 is annotation integration, where the annotation layer itself is the
separate tool of \code{ANNOTATIONS.md}: the annotation-ready HTML contract (M5), \code{cob
review} (M6), and a reserved slot for the annotation-layer fallback (M7).

Phase 3 is done in its shipped slices: the Markdown dialect (M8), stable ids and
the lock file (M11), self-hosting and the flip (M13), syntax highlighting (M14),
and the node model with same-document transclusion (M12, first slice). Math macros
(M9) and citations (M10) are the remaining phase-3 work. The deferred transclusion
slices — floats as nodes, per-node atomic pages, and cross-document transclusion —
are recorded in \code{transclude.rs.cob}.

The native reader is the first slice of M15: cob reads its own \code{.cob} source with a
Rust reader (\code{markup.rs}), so no \code{markup} process runs at read time and cob can ship
as one binary. The reader is a formal PEG grammar that the \code{peg} crate builds into a
parser at compile time (\code{markup.rs.cob}). noweb does not go away. \code{notangle} still
does tangle, and \code{markup} stays as the reader's test oracle — the differential test
and the flake \code{reader} check diff the reader against real \code{markup} for every module.
Replacing \code{notangle} too stays a contingency with explicit triggers, recorded in
\code{tangle.rs.cob}.

## Open questions {#sec:QznE}

- One review patch per run, or per thread? Per-thread accepts granularly but
  conflicts when two threads touch the same prose. The lean is one patch per run
  with per-thread attribution in the diff.
- Should cob watch and rebuild for a local authoring loop? The feedback loop is poor
  without it.

Resolved questions are recorded where they were settled: the one prose dialect lives
in \code{config.rs.cob}, the two-pass rewriter in \code{rewrite.rs.cob}, and the choice to skip
\code{noweave} in this document's architecture section.

## Risks {#sec:4y6v}

- KaTeX via a JS engine adds build weight and weave latency. The cache mitigates it.
- Self-hosting could make a weaver bug a bootstrap risk. The mitigation is that
  stage 0 bootstraps from \code{notangle}, a stable external tool, not from \code{cob}, so no
  cob bug can break the bootstrap or poison a committed artifact — there is none.
- Re-anchoring quality is the annotation layer's concern, tracked in
  \code{ANNOTATIONS.md}, because the anchoring is done by its selector machinery rather
  than by heuristics cob invents.

## Error codes {#sec:oXEK}

cob reports one diagnostic format from every stage (\code{diag.rs.cob}). Each code is
stable, so a test or a suppression can name one error and no other. When a module
introduces a code, it claims the next free number in this registry.

```table
\caption{The error and warning codes.}
| Code | Meaning | Module |
|---|---|---|
| E001 | malformed IR line from \code{markup} | \code{noweb.rs} |
| E002 | \code{markup} failed, \code{@fatal}, or not found | \code{noweb.rs} |
| E010 | use of an undefined chunk | \code{model.rs} |
| E014 | duplicate label | \code{resolve.rs} |
| E015 | unresolved reference | \code{resolve.rs} |
| E020 | math render failure | \code{math.rs} |
| E022 | unterminated math delimiter | \code{prose.rs} |
| E023 | KaTeX assets missing | \code{weave.rs} |
| E024 | writing the site failed | \code{weave.rs} |
| E025 | template render failure | \code{weave.rs} |
| E026 | rewriting prose HTML failed | \code{rewrite.rs} |
| E027 | retired (was \code{notangle} failure); cob tangles natively | \code{tangle.rs} |
| E028 | writing tangled output failed | \code{tangle.rs} |
| E029 | \code{cob.toml} unreadable or malformed | \code{config.rs} |
| E030 | malformed fence modifier | \code{markdown.rs} |
| E031 | label absent from \code{cob.lock} under \code{--locked} | \code{lock.rs}, \code{weave.rs} |
| E032 | \code{cob.lock} unreadable, malformed, or unwritable | \code{lock.rs} |
| E033 | a highlight key names an unknown language | \code{main.rs} |
| E034 | bare or unknown fence kind | \code{markdown.rs} |
| E035 | recursive chunk expansion (cycle) | \code{tangle.rs} |
| W102 | chunk defined but never used | \code{model.rs} |
| W103 | figure or table without a caption | \code{resolve.rs} |
| W104 | code chunk resolved to no known language | \code{weave.rs} |
| W105 | transclusion cycle | \code{transclude.rs} |
| W106 | transclusion of an unknown target | \code{transclude.rs} |
```

## Conventions {#sec:zBDS}

- Dependencies are added reluctantly, one at a time, only when a task needs them.
  Never add one speculatively.
- No panics outside tests. Everything user-facing goes through the diagnostic format
  with a code.
- Every noweb-boundary discovery gets a fixture. A minimal \code{.cob} plus regenerated
  \code{.markup} pair and a test is how the verified-noweb prose stays true.
- noweb does not go away, but cob reads its own source now: a native Rust reader
  (\code{markup.rs}) replaces the \code{markup} process (M15), and \code{markup} stays as its test
  oracle. Do not reimplement \code{notangle}; the removal triggers are in \code{tangle.rs.cob}
  and none have fired.
- Determinism is a feature. No timestamps, and no HashMap iteration order in output —
  a \code{BTreeMap} or an explicit sort.
- When a decision conflicts with observed reality, verification wins: probe the real
  binary, record the finding, update the prose.

All \code{.cob} prose follows ASD-STE100 Simplified Technical English: short active
present-tense sentences, one idea each, approved plain verbs, and the reason before
the mechanism.
@
