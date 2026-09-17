package com.github.pedrogitprojects.sequent;

import com.intellij.lang.Language;

public final class SequentLanguage extends Language {
    public static final SequentLanguage INSTANCE = new SequentLanguage();

    private SequentLanguage() {
        super("Sequent");
    }
}
