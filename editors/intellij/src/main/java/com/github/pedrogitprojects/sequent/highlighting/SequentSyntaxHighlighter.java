package com.github.pedrogitprojects.sequent.highlighting;

import com.github.pedrogitprojects.sequent.lexer.SequentLexer;
import com.github.pedrogitprojects.sequent.psi.SequentTokenTypes;
import com.intellij.lexer.Lexer;
import com.intellij.openapi.editor.colors.TextAttributesKey;
import com.intellij.openapi.fileTypes.SyntaxHighlighterBase;
import com.intellij.psi.TokenType;
import com.intellij.psi.tree.IElementType;
import org.jetbrains.annotations.NotNull;

import java.util.HashMap;
import java.util.Map;

public final class SequentSyntaxHighlighter extends SyntaxHighlighterBase {
    private static final TextAttributesKey[] EMPTY = new TextAttributesKey[0];
    private static final Map<IElementType, TextAttributesKey> KEYS = buildKeys();

    @Override
    public @NotNull Lexer getHighlightingLexer() {
        return new SequentLexer();
    }

    @Override
    public TextAttributesKey @NotNull [] getTokenHighlights(IElementType tokenType) {
        TextAttributesKey key = KEYS.get(tokenType);
        return key == null ? EMPTY : new TextAttributesKey[]{key};
    }

    private static Map<IElementType, TextAttributesKey> buildKeys() {
        Map<IElementType, TextAttributesKey> m = new HashMap<>();
        m.put(SequentTokenTypes.DECLARATION_KEYWORD, SequentColors.DECLARATION_KEYWORD);
        m.put(SequentTokenTypes.NODE_KEYWORD, SequentColors.NODE_KEYWORD);
        m.put(SequentTokenTypes.GATEWAY_KEYWORD, SequentColors.GATEWAY_KEYWORD);
        m.put(SequentTokenTypes.PROPERTY_KEYWORD, SequentColors.PROPERTY_KEYWORD);
        m.put(SequentTokenTypes.KEYWORD, SequentColors.KEYWORD);
        m.put(SequentTokenTypes.IDENTIFIER, SequentColors.IDENTIFIER);
        m.put(SequentTokenTypes.NUMBER, SequentColors.NUMBER);
        m.put(SequentTokenTypes.STRING, SequentColors.STRING);
        m.put(SequentTokenTypes.FEEL_STRING, SequentColors.FEEL_STRING);
        m.put(SequentTokenTypes.LINE_COMMENT, SequentColors.LINE_COMMENT);
        m.put(SequentTokenTypes.BLOCK_COMMENT, SequentColors.BLOCK_COMMENT);
        m.put(SequentTokenTypes.LBRACE, SequentColors.BRACES);
        m.put(SequentTokenTypes.RBRACE, SequentColors.BRACES);
        m.put(SequentTokenTypes.EQ, SequentColors.OPERATOR);
        m.put(SequentTokenTypes.ARROW, SequentColors.OPERATOR);
        m.put(SequentTokenTypes.MESSAGE_ARROW, SequentColors.OPERATOR);
        m.put(TokenType.BAD_CHARACTER, SequentColors.BAD_CHARACTER);
        return m;
    }
}
