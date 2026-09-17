package com.github.pedrogitprojects.sequent.highlighting;

import com.intellij.openapi.editor.DefaultLanguageHighlighterColors;
import com.intellij.openapi.editor.HighlighterColors;
import com.intellij.openapi.editor.colors.TextAttributesKey;

import static com.intellij.openapi.editor.colors.TextAttributesKey.createTextAttributesKey;

/**
 * The colour keys the highlighter assigns, each falling back to a standard key
 * so the plugin looks right in every scheme without shipping one.
 *
 * <p>The four keyword groups default to the same keyword colour: uniform out of
 * the box, and separable by anyone who wants node kinds to stand apart from
 * gateways. Properties are the exception — they read as attributes of a step
 * rather than as structure, so they default to the metadata colour.
 */
public final class SequentColors {
    public static final TextAttributesKey DECLARATION_KEYWORD =
            createTextAttributesKey("SEQUENT_DECLARATION_KEYWORD", DefaultLanguageHighlighterColors.KEYWORD);
    public static final TextAttributesKey NODE_KEYWORD =
            createTextAttributesKey("SEQUENT_NODE_KEYWORD", DefaultLanguageHighlighterColors.KEYWORD);
    public static final TextAttributesKey GATEWAY_KEYWORD =
            createTextAttributesKey("SEQUENT_GATEWAY_KEYWORD", DefaultLanguageHighlighterColors.KEYWORD);
    public static final TextAttributesKey KEYWORD =
            createTextAttributesKey("SEQUENT_KEYWORD", DefaultLanguageHighlighterColors.KEYWORD);
    public static final TextAttributesKey PROPERTY_KEYWORD =
            createTextAttributesKey("SEQUENT_PROPERTY_KEYWORD", DefaultLanguageHighlighterColors.METADATA);

    public static final TextAttributesKey IDENTIFIER =
            createTextAttributesKey("SEQUENT_IDENTIFIER", DefaultLanguageHighlighterColors.IDENTIFIER);
    public static final TextAttributesKey NUMBER =
            createTextAttributesKey("SEQUENT_NUMBER", DefaultLanguageHighlighterColors.NUMBER);
    public static final TextAttributesKey STRING =
            createTextAttributesKey("SEQUENT_STRING", DefaultLanguageHighlighterColors.STRING);
    public static final TextAttributesKey FEEL_STRING =
            createTextAttributesKey("SEQUENT_FEEL_STRING", DefaultLanguageHighlighterColors.VALID_STRING_ESCAPE);

    public static final TextAttributesKey LINE_COMMENT =
            createTextAttributesKey("SEQUENT_LINE_COMMENT", DefaultLanguageHighlighterColors.LINE_COMMENT);
    public static final TextAttributesKey BLOCK_COMMENT =
            createTextAttributesKey("SEQUENT_BLOCK_COMMENT", DefaultLanguageHighlighterColors.BLOCK_COMMENT);

    public static final TextAttributesKey BRACES =
            createTextAttributesKey("SEQUENT_BRACES", DefaultLanguageHighlighterColors.BRACES);
    public static final TextAttributesKey OPERATOR =
            createTextAttributesKey("SEQUENT_OPERATOR", DefaultLanguageHighlighterColors.OPERATION_SIGN);

    public static final TextAttributesKey BAD_CHARACTER =
            createTextAttributesKey("SEQUENT_BAD_CHARACTER", HighlighterColors.BAD_CHARACTER);

    private SequentColors() {
    }
}
