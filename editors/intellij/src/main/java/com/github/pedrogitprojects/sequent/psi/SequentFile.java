package com.github.pedrogitprojects.sequent.psi;

import com.github.pedrogitprojects.sequent.SequentFileType;
import com.github.pedrogitprojects.sequent.SequentLanguage;
import com.intellij.extapi.psi.PsiFileBase;
import com.intellij.openapi.fileTypes.FileType;
import com.intellij.psi.FileViewProvider;
import org.jetbrains.annotations.NotNull;

public final class SequentFile extends PsiFileBase {
    public SequentFile(@NotNull FileViewProvider viewProvider) {
        super(viewProvider, SequentLanguage.INSTANCE);
    }

    @Override
    public @NotNull FileType getFileType() {
        return SequentFileType.INSTANCE;
    }

    @Override
    public String toString() {
        return "Sequent File";
    }
}
