package com.github.pedrogitprojects.sequent.editor;

import com.github.pedrogitprojects.sequent.psi.SequentTokenTypes;
import com.intellij.lang.BracePair;
import com.intellij.lang.PairedBraceMatcher;
import com.intellij.psi.PsiFile;
import com.intellij.psi.tree.IElementType;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

public final class SequentBraceMatcher implements PairedBraceMatcher {
    // Structural: a `{` always opens a block, which is what makes the pair
    // worth showing in the gutter and in the breadcrumb.
    private static final BracePair[] PAIRS = {
            new BracePair(SequentTokenTypes.LBRACE, SequentTokenTypes.RBRACE, true),
    };

    @Override
    public BracePair @NotNull [] getPairs() {
        return PAIRS;
    }

    @Override
    public boolean isPairedBracesAllowedBeforeType(@NotNull IElementType lbraceType, @Nullable IElementType contextType) {
        return true;
    }

    @Override
    public int getCodeConstructStart(PsiFile file, int openingBraceOffset) {
        return openingBraceOffset;
    }
}
