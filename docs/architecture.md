# Architecture

Struo is a Free Pascal program that builds itself. This document is the map of
the source tree and the rules that keep it navigable.

## Source layout

Units marked *planned* are not written yet; everything else exists.

```
src/
├── struo.pas                     program entry point: argv -> exit code
├── cli/
│   ├── Struo.Cli.Output.pas      all terminal output; colour and verbosity
│   ├── Struo.Cli.Args.pas        argv -> flags, options, positionals
│   └── Struo.Cli.Command.pas     the command registry, dispatch and help
├── core/
│   ├── Struo.Types.pas           shared types and the Struo exception root
│   ├── Struo.Paths.pas           STRUO_HOME, caches, target dirs
│   ├── Struo.SemVer.pas          versions and version requirements
│   ├── Struo.Manifest.pas        the Struo.toml model, load and validate
│   ├── Struo.Targets.pas         target inference from the layout
│   ├── Struo.Workspace.pas       finding the package a command acts on
│   ├── Struo.Compiler.pas        FPC discovery and invocation
│   ├── Struo.Manifest.Editor.pas surgical edits, for add and remove
│   ├── Struo.Lockfile.pas        Struo.lock read and write
│   ├── Struo.Resolver.pas        requirements -> a resolved graph
│   ├── Struo.Source.pas          fetching path and git sources
│   └── Struo.Registry.pas        planned: index, search, download
├── commands/
│   ├── Struo.Cmd.New.pas         new, init
│   ├── Struo.Cmd.Build.pas       build, check
│   ├── Struo.Cmd.Run.pas         run
│   ├── Struo.Cmd.Test.pas        test
│   ├── Struo.Cmd.Clean.pas       clean
│   ├── Struo.Cmd.Doctor.pas      doctor
│   ├── Struo.Cmd.Toolchain.pas   toolchain
│   ├── Struo.Cmd.Deps.pas        add, remove, update, tree
│   └── Struo.Cmd.Registry.pas    planned: search, publish, login, logout
├── toml/
│   ├── Struo.Toml.Value.pas      the value tree (ordered tables)
│   ├── Struo.Toml.Lexer.pas      text -> tokens
│   ├── Struo.Toml.Parser.pas     tokens -> value tree
│   └── Struo.Toml.Writer.pas     value tree -> text (generated files only)
└── util/
    ├── Struo.Util.Strings.pas    string helpers Free Pascal lacks
    ├── Struo.Util.Fs.pas         paths, BOM-aware reads, atomic writes
    └── Struo.Util.Proc.pas       run a child process, capture its output
```

Help text has no unit of its own. A command declares its options to
`Struo.Cli.Args`, and both the parser and the help screen are generated from
that one declaration, so they cannot disagree about what the command accepts.

Unit names mirror their path: `src/core/Struo.Manifest.pas` is unit
`Struo.Manifest`. Dotted unit names work in `{$mode objfpc}`, so the namespace
is real, not a prefix convention.

## Dependency direction

```
commands  ->  core  ->  toml
    |          |          |
    +----------+----------+---->  util
    |
    +---->  cli
```

Layers only depend downward. In particular:

- **`util` depends on nothing of ours.** Pure helpers, no Struo concepts.
- **`toml` knows nothing about manifests.** It is a general TOML subset parser;
  the manifest model interprets its output.
- **`core` never writes to the terminal.** It raises `EStruoError` with a
  message and, where useful, a hint. The CLI layer decides how to render it.
- **`commands` is the only layer that may call `cli`.** A command reads argv,
  asks `core` to do the work, and reports.

`Struo.Cli.Output` is the single exception to the layering rules: anything may
use it to emit `--verbose` trace lines, because tracing is cross-cutting.

## Error handling

`core` raises; it does not print and does not call `Halt`.

```pascal
raise EStruoError.CreateHint(
  Format('no package found in `%s`', [ADir]),
  'run `struo init` to create one'
);
```

`struo.pas` has the only `try..except` that reaches the user. It renders the
message as `error: <message>` and the hint as `hint: <hint>`, then exits `1`.
Command-line mistakes raise `EStruoUsageError`, which exits `2`.

## Output conventions

Struo copies Cargo's output shape because it reads well and Pascal developers
coming from Rust will recognise it: a twelve-column right-aligned green verb,
then the detail.

```
   Compiling hello v0.1.0 (C:\dev\hello)
    Finished `debug` profile [unoptimized + debuginfo] in 0.41s
     Running `target\debug\hello.exe`
```

Every line goes through `Struo.Cli.Output`, which owns the column width, the
ANSI codes, and the `--quiet`/`--color` decisions. Nothing else writes to
stdout or stderr directly.

## The build pipeline

`struo build` is the backbone; the other commands are variations on it.

1. **Discover.** Walk up from the working directory to the nearest
   `Struo.toml` (`Struo.Workspace`).
2. **Load.** Parse the manifest, validate it, infer targets from the layout
   (`Struo.Manifest`, `Struo.Targets`).
3. **Resolve.** Read `Struo.lock` if it is current; otherwise resolve
   requirements to concrete versions and write a new lockfile
   (`Struo.Resolver`, `Struo.Lockfile`).
4. **Fetch.** Make sure every resolved package is on disk, under
   `$STRUO_HOME/cache` for registry and git sources (`Struo.Source`).
5. **Compile.** Topologically order the graph, then compile each package into
   `target/<profile>/deps/<name>-<version>/`, accumulating `-Fu` paths as we
   go (`Struo.Compiler`).
6. **Link.** Compile this package's targets with the accumulated unit paths,
   emitting binaries into `target/<profile>/`.

Steps 3 through 5 are no-ops for a package with no dependencies, which is why
`struo new` + `struo build` works before the resolver exists.

## Target inference asks the file what it is

A directory of `.pas` files is not a directory of programs. `tests/` typically
holds test programs beside a shared helper unit, and treating that unit as a
test target would produce a target that compiles perfectly and yields no
executable — a failure with no cause the user could act on.

So inference reads each candidate's leading declaration
(`Struo.Targets.PascalSourceKind`) and only infers a binary, test or example
from a file that says `program`, and a library from one that says `unit`. A
`library` or `package` declaration is left alone: those need an explicit
target in the manifest.

Struo's own `tests/` directory is the worked example. `Struo.Test.pas` is the
harness and is not a test; the three `test_*.pas` programs are.

## The toolchain is Struo's, not the machine's

A release archive carries a Free Pascal installation at `toolchain/`, beside
the binary, and `Struo.Compiler` prefers it over anything on the machine. Two
consequences are worth knowing before changing that code.

First, a bundled compiler runs with `-n`: it reads no `fpc.cfg` at all, and
every search path comes from `Struo.Compiler.BuildArguments`. Free Pascal
looks for a config in the user's home directory and in `C:\ProgramData`
before its own, so without `-n` a file left by an unrelated Pascal install
could point a Struo build at another installation's units, and the failure
would look like a bug in the user's package.

Second, an explicit choice still wins: `STRUO_FPC` and `STRUO_TOOLCHAIN` beat
the bundled toolchain, and keep their configuration, because someone setting
them is saying something Struo should not second-guess.

`packaging/release.ps1` builds the archive and refuses to zip one whose
toolchain cannot compile, link and run a test program. `docs/toolchain.md` is
the user-facing version of all this.

## Testing

`tests/` holds one program per area, each exiting non-zero on failure:

```console
$ ./bootstrap/build.ps1 -Tests     # or, once struo is on your PATH:
$ struo test
```

Struo is self-hosting from here: the `Struo.toml` at the repository root
describes Struo itself, so `struo build` and `struo test` work on this
repository. `bootstrap/` exists only to produce the first binary.

Unit-level tests cover the TOML parser, SemVer comparison and requirement
matching, manifest validation, and the compiler argument builder — the four
places where a silent bug would be expensive.
