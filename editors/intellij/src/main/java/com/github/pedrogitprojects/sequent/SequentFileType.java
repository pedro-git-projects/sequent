package com.github.pedrogitprojects.sequent;

import com.intellij.openapi.fileTypes.LanguageFileType;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import javax.swing.Icon;

public final class SequentFileType extends LanguageFileType {
    public static final SequentFileType INSTANCE = new SequentFileType();

    private SequentFileType() {
        super(SequentLanguage.INSTANCE);
    }

    @Override
    public @NotNull String getName() {
        return "Sequent";
    }

    @Override
    public @NotNull String getDescription() {
        return "Sequent workflow source";
    }

    @Override
    public @NotNull String getDefaultExtension() {
        return "sq";
    }

    @Override
    public @Nullable Icon getIcon() {
        return SequentIcons.FILE;
    }
}
