package com.github.pedrogitprojects.sequent.psi;

import com.intellij.psi.tree.IElementType;
import com.intellij.psi.tree.TokenSet;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;

/**
 * The token alphabet of {@code .sq}.
 *
 * <p>Reserved words are split into four groups that get their own colour key.
 * The lexer cannot tell a {@code message} declaration from a {@code message}
 * trigger inside a {@code wait} block, and does not try to: a word belongs to
 * exactly one group, chosen by where it is most often written.
 *
 * <p>The word lists are the IDE-side copy of {@code reservedWords} in
 * {@code src/Sequent/Language/Parser.hs}. Adding a keyword to the grammar means
 * adding it here too, or it highlights as an identifier.
 */
public final class SequentTokenTypes {
    // Structure.
    public static final IElementType LBRACE = new SequentTokenType("LBRACE");
    public static final IElementType RBRACE = new SequentTokenType("RBRACE");

    // Operators: `=` binds a property, `->` chains a flow, `~>` a message flow.
    public static final IElementType EQ = new SequentTokenType("EQ");
    public static final IElementType ARROW = new SequentTokenType("ARROW");
    public static final IElementType MESSAGE_ARROW = new SequentTokenType("MESSAGE_ARROW");

    // Literals and names.
    public static final IElementType IDENTIFIER = new SequentTokenType("IDENTIFIER");
    public static final IElementType NUMBER = new SequentTokenType("NUMBER");
    public static final IElementType STRING = new SequentTokenType("STRING");
    /** A string whose first character is {@code =}: a FEEL expression, not a label. */
    public static final IElementType FEEL_STRING = new SequentTokenType("FEEL_STRING");

    // Comments.
    public static final IElementType LINE_COMMENT = new SequentTokenType("LINE_COMMENT");
    public static final IElementType BLOCK_COMMENT = new SequentTokenType("BLOCK_COMMENT");

    // Keyword groups.
    public static final IElementType DECLARATION_KEYWORD = new SequentTokenType("DECLARATION_KEYWORD");
    public static final IElementType NODE_KEYWORD = new SequentTokenType("NODE_KEYWORD");
    public static final IElementType GATEWAY_KEYWORD = new SequentTokenType("GATEWAY_KEYWORD");
    public static final IElementType PROPERTY_KEYWORD = new SequentTokenType("PROPERTY_KEYWORD");
    public static final IElementType KEYWORD = new SequentTokenType("KEYWORD");

    public static final TokenSet COMMENTS = TokenSet.create(LINE_COMMENT, BLOCK_COMMENT);
    public static final TokenSet STRINGS = TokenSet.create(STRING, FEEL_STRING);

    private static final Map<String, IElementType> KEYWORDS = buildKeywords();

    /** The token type for a word, or {@link #IDENTIFIER} when it is not reserved. */
    public static IElementType keywordOrIdentifier(String word) {
        return KEYWORDS.getOrDefault(word, IDENTIFIER);
    }

    private static Map<String, IElementType> buildKeywords() {
        Map<String, IElementType> m = new HashMap<>();

        // Top-level declarations and the blocks that introduce a scope.
        put(m, DECLARATION_KEYWORD,
                "process", "collaboration", "pool", "lane", "subprocess",
                "message", "signal", "error", "escalation",
                "note", "data", "doc");

        // Node kinds: every one of these introduces a step.
        put(m, NODE_KEYWORD,
                "start", "end", "task", "service", "user", "manual", "script",
                "business", "send", "receive", "call", "wait", "throw");

        // Gateway kinds.
        put(m, GATEWAY_KEYWORD, "xor", "and", "or", "event", "complex");

        // Properties written inside a node block.
        put(m, PROPERTY_KEYWORD,
                "type", "retries", "input", "output", "header", "form",
                "assignee", "groups", "users", "due", "expression", "result",
                "decision", "calls", "propagate", "each", "in", "collect",
                "timer", "link", "terminate", "compensation", "sequential",
                "correlation", "priority");

        // Everything else the grammar gives meaning to: control and wiring.
        put(m, KEYWORD,
                "on", "catch", "noninterrupting", "as", "from", "to", "pin",
                "at", "flow", "goto", "join", "branch", "when", "otherwise");

        return Collections.unmodifiableMap(m);
    }

    private static void put(Map<String, IElementType> m, IElementType type, String... words) {
        for (String w : words) {
            m.put(w, type);
        }
    }

    private SequentTokenTypes() {
    }
}
