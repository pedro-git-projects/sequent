# sequent for IntelliJ

Syntax highlighting for `.sq` files in IntelliJ IDEA and the other JetBrains
IDEs. Targets 2025.2 (build 252) and later.

## What it does

* **Highlighting.** Five keyword groups — declarations (`process`, `pool`,
  `message`), node kinds (`service`, `user`, `wait`), gateway kinds (`xor`,
  `and`, `event`), step properties (`type`, `retries`, `input`) and control
  words (`on`, `catch`, `goto`) — plus identifiers, numbers, labels, comments,
  braces and the `=`, `->`, `~>` operators.
* **FEEL expressions read apart from labels.** A string starting with `=` is an
  expression, not presentation text, so `"=order.total"` is coloured
  differently from `"Charge card"`. That distinction runs through the whole
  language and is the one the eye most wants help with.
* **Brace matching** on `{}`, with the usual gutter markers and Ctrl+Shift+M.
* **Comment toggling.** Ctrl+/ writes `#`, matching the examples and the output
  of `sequent fmt`; Ctrl+Shift+/ writes `/* */`.

Colours are configurable under *Settings | Editor | Color Scheme | Sequent*.
Every key falls back to a standard one, so the plugin follows whatever scheme
is active without shipping its own.

## Building

Needs a JDK 21. There is no checked-in Gradle wrapper JAR; either open
`editors/intellij` as a Gradle project in IntelliJ, which reads
`gradle/wrapper/gradle-wrapper.properties` and fetches the distribution itself,
or generate the wrapper once with a system Gradle:

```bash
cd editors/intellij
gradle wrapper        # once, if you want ./gradlew
./gradlew buildPlugin  # -> build/distributions/sequent-intellij-0.1.0.zip
```

Install the zip with *Settings | Plugins | ⚙ | Install Plugin from Disk…*.

To try it without installing, `./gradlew runIde` starts a sandbox IDE with the
plugin loaded.

## Keeping up with the grammar

The keyword lists in
`src/main/java/com/github/pedrogitprojects/sequent/psi/SequentTokenTypes.java`
are the IDE-side copy of `reservedWords` in
`src/Sequent/Language/Parser.hs`. They agree word for word today (69 of them).
A keyword added to the grammar and not added here highlights as an identifier,
which is the only way the two can drift.

## Design notes

The lexer is hand-written (`lexer/SequentLexer.java`) rather than generated from
a JFlex grammar. The token alphabet is small and every token is recognisable
from its first character, so a generator buys little and costs a code-generation
step in the build.

`SequentParserDefinition` folds the token stream into a single file node without
building structure. Highlighting needs only the lexer, but a `ParserDefinition`
is what gives the file a PSI tree, which the commenter and brace matcher work
against. Real productions can be grown there later — a structure view of
processes and steps, folding of `{}` blocks, go-to-definition on a `goto` target
— without changing any of the registration around it.

One deliberate divergence from the grammar: an unterminated string ends at the
newline. The parser would read on across lines, but painting the rest of a file
as a string because of one stray quote is worse in an editor than ending the
token early.
