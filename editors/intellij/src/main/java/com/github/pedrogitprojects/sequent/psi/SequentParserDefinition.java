package com.github.pedrogitprojects.sequent.psi;

import com.github.pedrogitprojects.sequent.SequentLanguage;
import com.github.pedrogitprojects.sequent.lexer.SequentLexer;
import com.intellij.extapi.psi.ASTWrapperPsiElement;
import com.intellij.lang.ASTNode;
import com.intellij.lang.ParserDefinition;
import com.intellij.lang.PsiParser;
import com.intellij.lexer.Lexer;
import com.intellij.openapi.project.Project;
import com.intellij.psi.FileViewProvider;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiFile;
import com.intellij.psi.tree.IFileElementType;
import com.intellij.psi.tree.TokenSet;
import org.jetbrains.annotations.NotNull;

/**
 * A flat parser: it folds the whole token stream into the file node without
 * building any structure.
 *
 * <p>Highlighting only needs the lexer, but a {@code ParserDefinition} is what
 * gives the file a real PSI tree, and that is what the commenter and the brace
 * matcher work against. Real productions can be grown here later without any of
 * the surrounding registration changing.
 */
public final class SequentParserDefinition implements ParserDefinition {
    public static final IFileElementType FILE = new IFileElementType(SequentLanguage.INSTANCE);

    @Override
    public @NotNull Lexer createLexer(Project project) {
        return new SequentLexer();
    }

    @Override
    public @NotNull PsiParser createParser(Project project) {
        return (root, builder) -> {
            var marker = builder.mark();
            while (!builder.eof()) {
                builder.advanceLexer();
            }
            marker.done(root);
            return builder.getTreeBuilt();
        };
    }

    @Override
    public @NotNull IFileElementType getFileNodeType() {
        return FILE;
    }

    @Override
    public @NotNull TokenSet getCommentTokens() {
        return SequentTokenTypes.COMMENTS;
    }

    @Override
    public @NotNull TokenSet getStringLiteralElements() {
        return SequentTokenTypes.STRINGS;
    }

    @Override
    public @NotNull PsiElement createElement(ASTNode node) {
        return new ASTWrapperPsiElement(node);
    }

    @Override
    public @NotNull PsiFile createFile(@NotNull FileViewProvider viewProvider) {
        return new SequentFile(viewProvider);
    }
}
