# sequent 0.2.0.0-alpha.1

This is the first pre-alpha binary release of sequent, a declarative process
language that compiles a `.sq` source file to a Camunda 8 `.bpmn` file with the
diagram geometry included. The `.sq` source is the truth; the `.bpmn` is a build
artifact with deterministic ids, deterministic XML, and a layout derived from the
normative layout specification in `SPEC.md`.

## Platform

- Windows x86-64

## Installation

No installation is required.

Download `sequent-0.2.0.0-alpha.1-windows-x86_64.zip`, extract it, and run:

```powershell
.\sequent.exe --help
```

GHC, Cabal and Stack are not required. Nothing is written to the registry, the
system PATH, Program Files, or any machine-wide location. Extract the ZIP to any
directory you can write to and run the executable from there.

## What is in the archive

```
sequent-0.2.0.0-alpha.1-windows-x86_64/
├── sequent.exe      the compiler
├── sequent.cmd      optional wrapper; runs sequent.exe from the archive directory
├── README.txt
├── VERSION
└── examples/        .sq sources, plus hello.bpmn for trying `import`
```

## Runtime dependencies

None beyond Windows itself.

`sequent` is pure Haskell. It has no FFI imports, no `c-sources`, no
`extra-libraries` and no `pkgconfig-depends`, so the Haskell libraries are
statically linked into the executable by GHC in the normal way and the import
table contains only standard Windows system DLLs. No third-party or toolchain
DLLs are redistributed, because none are needed. The release workflow records
the executable's import table on every build, so this claim is checked rather
than assumed.

## Commands

```
build FILE      compile a .sq file to .bpmn
check FILE      report diagnostics without writing output
fmt FILE        print the file in canonical form
report FILE     print the layout quality report
import FILE     read a .bpmn file and write the .sq that produces it
rules           list the implemented specification rules
```

Each command accepts `--help` for its own options, for example:

```powershell
.\sequent.exe build --help
```

## Verifying the download

```powershell
Get-FileHash -Algorithm SHA256 .\sequent-0.2.0.0-alpha.1-windows-x86_64.zip
```

Compare the result with `sequent-0.2.0.0-alpha.1-windows-x86_64.zip.sha256`.

## Status

This release is pre-alpha software. Features, syntax, command-line options and
output formats may change without notice.

## Known limitations

- Windows x86-64 is the only platform published in this release. There is no
  32-bit Windows, macOS or Linux artifact.
- There is no `--version` flag. The version is recorded in the `VERSION` file
  inside the archive.
- The executable is not code-signed. Windows SmartScreen or a corporate
  application-control policy may warn about it, or block it outright, on first
  run.
- `build` overwrites its output file without prompting.
- `fmt --write` rewrites the source file in place.
- The compiler reads and writes only the files named on the command line. It
  does not launch external programs and does not access the network.

## Licensing

sequent is distributed under the **Apache License, Version 2.0**. The full
license text ships in the archive as `LICENSE`, and is also in the repository
root.

```
Copyright 2026 Pedro

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0
```
