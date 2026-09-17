package com.github.pedrogitprojects.sequent.lexer;

import com.github.pedrogitprojects.sequent.psi.SequentTokenTypes;
import com.intellij.lexer.LexerBase;
import com.intellij.psi.TokenType;
import com.intellij.psi.tree.IElementType;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

/**
 * A hand-written lexer for {@code .sq}.
 *
 * <p>The grammar is whitespace-insensitive with {@code {}} blocks, so there is
 * no indentation state to carry and every token can be recognised from its
 * first character. That is why {@link #getState()} is always {@code 0}: the IDE
 * may restart this lexer at any token boundary and get the same answer, which
 * is what makes incremental re-highlighting correct.
 */
public final class SequentLexer extends LexerBase {
    private CharSequence buffer = "";
    private int endOffset;
    private int tokenStart;
    private int tokenEnd;
    private IElementType tokenType;

    @Override
    public void start(@NotNull CharSequence buffer, int startOffset, int endOffset, int initialState) {
        this.buffer = buffer;
        this.endOffset = endOffset;
        this.tokenStart = startOffset;
        this.tokenEnd = startOffset;
        advance();
    }

    @Override
    public int getState() {
        return 0;
    }

    @Override
    public @Nullable IElementType getTokenType() {
        return tokenType;
    }

    @Override
    public int getTokenStart() {
        return tokenStart;
    }

    @Override
    public int getTokenEnd() {
        return tokenEnd;
    }

    @Override
    public @NotNull CharSequence getBufferSequence() {
        return buffer;
    }

    @Override
    public int getBufferEnd() {
        return endOffset;
    }

    @Override
    public void advance() {
        tokenStart = tokenEnd;
        if (tokenStart >= endOffset) {
            tokenType = null;
            return;
        }

        char c = buffer.charAt(tokenStart);

        if (Character.isWhitespace(c)) {
            emit(TokenType.WHITE_SPACE, scanWhitespace(tokenStart));
            return;
        }

        switch (c) {
            case '#':
                emit(SequentTokenTypes.LINE_COMMENT, scanToEndOfLine(tokenStart));
                return;
            case '/':
                if (peekIs(tokenStart + 1, '/')) {
                    emit(SequentTokenTypes.LINE_COMMENT, scanToEndOfLine(tokenStart));
                } else if (peekIs(tokenStart + 1, '*')) {
                    emit(SequentTokenTypes.BLOCK_COMMENT, scanBlockComment(tokenStart));
                } else {
                    emit(TokenType.BAD_CHARACTER, tokenStart + 1);
                }
                return;
            case '"':
                scanString(tokenStart);
                return;
            case '{':
                emit(SequentTokenTypes.LBRACE, tokenStart + 1);
                return;
            case '}':
                emit(SequentTokenTypes.RBRACE, tokenStart + 1);
                return;
            case '=':
                emit(SequentTokenTypes.EQ, tokenStart + 1);
                return;
            case '-':
                emitPairOrBad(SequentTokenTypes.ARROW);
                return;
            case '~':
                emitPairOrBad(SequentTokenTypes.MESSAGE_ARROW);
                return;
            default:
                break;
        }

        if (isDigit(c)) {
            emit(SequentTokenTypes.NUMBER, scanDigits(tokenStart));
            return;
        }

        if (isWordStart(c)) {
            int end = scanWord(tokenStart);
            emit(SequentTokenTypes.keywordOrIdentifier(buffer.subSequence(tokenStart, end).toString()), end);
            return;
        }

        emit(TokenType.BAD_CHARACTER, tokenStart + 1);
    }

    /** {@code ->} and {@code ~>} are the only two-character tokens; a lone lead is junk. */
    private void emitPairOrBad(IElementType paired) {
        if (peekIs(tokenStart + 1, '>')) {
            emit(paired, tokenStart + 2);
        } else {
            emit(TokenType.BAD_CHARACTER, tokenStart + 1);
        }
    }

    private void emit(IElementType type, int end) {
        tokenType = type;
        tokenEnd = end;
    }

    private int scanWhitespace(int from) {
        int i = from;
        while (i < endOffset && Character.isWhitespace(buffer.charAt(i))) {
            i++;
        }
        return i;
    }

    private int scanToEndOfLine(int from) {
        int i = from;
        while (i < endOffset && buffer.charAt(i) != '\n') {
            i++;
        }
        return i;
    }

    /** {@code /* ... *}{@code /}, which does not nest. Unterminated runs to EOF. */
    private int scanBlockComment(int from) {
        int i = from + 2;
        while (i < endOffset) {
            if (buffer.charAt(i) == '*' && peekIs(i + 1, '/')) {
                return i + 2;
            }
            i++;
        }
        return endOffset;
    }

    /**
     * A double-quoted string with {@code \" \\ \n \t \r} escapes.
     *
     * <p>A string that starts with {@code =} is a FEEL expression rather than a
     * label, and gets its own token so it can be coloured apart.
     *
     * <p>An unterminated string stops at the newline. The grammar would happily
     * read on, but painting the rest of the file as a string because of one
     * stray quote is worse in an editor than ending the token early.
     */
    private void scanString(int from) {
        boolean feel = peekIs(from + 1, '=');
        int i = from + 1;
        while (i < endOffset) {
            char c = buffer.charAt(i);
            if (c == '\n') {
                break;
            }
            if (c == '\\') {
                i += 2;
                continue;
            }
            i++;
            if (c == '"') {
                break;
            }
        }
        emit(feel ? SequentTokenTypes.FEEL_STRING : SequentTokenTypes.STRING, Math.min(i, endOffset));
    }

    private int scanDigits(int from) {
        int i = from;
        while (i < endOffset && isDigit(buffer.charAt(i))) {
            i++;
        }
        return i;
    }

    private int scanWord(int from) {
        int i = from;
        while (i < endOffset && isWordPart(buffer.charAt(i))) {
            i++;
        }
        return i;
    }

    private boolean peekIs(int index, char expected) {
        return index < endOffset && buffer.charAt(index) == expected;
    }

    private static boolean isDigit(char c) {
        return c >= '0' && c <= '9';
    }

    // Mirrors the parser: `isAlpha c || c == '_'` to start, `isAlphaNum c || c == '_'` after.
    private static boolean isWordStart(char c) {
        return Character.isLetter(c) || c == '_';
    }

    private static boolean isWordPart(char c) {
        return Character.isLetterOrDigit(c) || c == '_';
    }
}
