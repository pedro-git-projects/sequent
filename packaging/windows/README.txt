sequent @VERSION@
PRE-ALPHA RELEASE

This is an experimental pre-alpha build.

sequent is a declarative process language that compiles a .sq source file
to a Camunda 8 .bpmn file, diagram geometry included. The .sq source is the
truth; the .bpmn is a build artifact with deterministic ids, deterministic
XML and a layout derived from the layout specification.

No installation is required.

Requirements:
- 64-bit Windows
- No Haskell installation required (GHC, Cabal and Stack are NOT needed)

Usage:

1. Extract the entire ZIP to a directory you can write to.

2. Open PowerShell or Command Prompt in that directory.

3. Run:

   .\sequent.exe --help

Example:

   .\sequent.exe build examples\hello.sq

   This writes examples\hello.bpmn next to the source file. Open that file
   in Camunda Modeler, or import it into a Camunda 8 cluster.

Commands:

   build FILE      compile a .sq file to .bpmn
   check FILE      report diagnostics without writing output
   fmt FILE        print the file in canonical form
   report FILE     print the layout quality report
   import FILE     read a .bpmn file and write the .sq that produces it
   rules           list the implemented specification rules

Every command accepts --help for its own options, for example:

   .\sequent.exe build --help

More examples:

   .\sequent.exe check examples\order.sq
   .\sequent.exe report examples\order.sq
   .\sequent.exe fmt examples\hello.sq
   .\sequent.exe import examples\hello.bpmn
   .\sequent.exe rules

The examples\ directory contains .sq sources you can compile. The file
examples\hello.bpmn is included so the import command can be tried directly.

Note: there is no --version option in this release. The version is recorded
in the VERSION file next to this README.

License:

sequent is distributed under the Apache License, Version 2.0. The full text
is in the LICENSE file included in this archive.

Important:
- Keep all files from the ZIP together.
- Do not move individual DLL/resource files away from the executable.
- This is a pre-alpha release and interfaces or behavior may change.

Optional:
  sequent.cmd is a thin wrapper that runs sequent.exe from this directory
  regardless of your current working directory. It is not required; running
  sequent.exe directly is the normal way to use this release.
