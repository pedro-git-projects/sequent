package com.github.pedrogitprojects.sequent.psi;

import com.github.pedrogitprojects.sequent.SequentLanguage;
import com.intellij.psi.tree.IElementType;
import org.jetbrains.annotations.NonNls;
import org.jetbrains.annotations.NotNull;

public final class SequentTokenType extends IElementType {
    public SequentTokenType(@NonNls @NotNull String debugName) {
        super(debugName, SequentLanguage.INSTANCE);
    }

    @Override
    public String toString() {
        return "Sequent:" + super.toString();
    }
}
