package com.github.pedrogitprojects.sequent.highlighting;

import com.github.pedrogitprojects.sequent.SequentIcons;
import com.intellij.openapi.editor.colors.TextAttributesKey;
import com.intellij.openapi.fileTypes.SyntaxHighlighter;
import com.intellij.openapi.options.colors.AttributesDescriptor;
import com.intellij.openapi.options.colors.ColorDescriptor;
import com.intellij.openapi.options.colors.ColorSettingsPage;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import javax.swing.Icon;
import java.util.Map;

public final class SequentColorSettingsPage implements ColorSettingsPage {
    private static final AttributesDescriptor[] DESCRIPTORS = {
            new AttributesDescriptor("Keywords//Declaration", SequentColors.DECLARATION_KEYWORD),
            new AttributesDescriptor("Keywords//Node kind", SequentColors.NODE_KEYWORD),
            new AttributesDescriptor("Keywords//Gateway kind", SequentColors.GATEWAY_KEYWORD),
            new AttributesDescriptor("Keywords//Property", SequentColors.PROPERTY_KEYWORD),
            new AttributesDescriptor("Keywords//Control", SequentColors.KEYWORD),
            new AttributesDescriptor("Identifier", SequentColors.IDENTIFIER),
            new AttributesDescriptor("Number", SequentColors.NUMBER),
            new AttributesDescriptor("String//Label", SequentColors.STRING),
            new AttributesDescriptor("String//FEEL expression", SequentColors.FEEL_STRING),
            new AttributesDescriptor("Comments//Line comment", SequentColors.LINE_COMMENT),
            new AttributesDescriptor("Comments//Block comment", SequentColors.BLOCK_COMMENT),
            new AttributesDescriptor("Braces", SequentColors.BRACES),
            new AttributesDescriptor("Operator", SequentColors.OPERATOR),
            new AttributesDescriptor("Bad character", SequentColors.BAD_CHARACTER),
    };

    @Override
    public @Nullable Icon getIcon() {
        return SequentIcons.FILE;
    }

    @Override
    public @NotNull SyntaxHighlighter getHighlighter() {
        return new SequentSyntaxHighlighter();
    }

    @Override
    public @NotNull String getDemoText() {
        return """
                # Order fulfilment: a decision, a boundary error and a rework loop.

                message payment_confirmed "payment-confirmed" correlation "=orderId"
                error payment_failed "PAYMENT_FAILED" "Payment failed"

                /* Blocks are braces. Indentation carries no meaning, so a merge
                   that shifts it cannot change what the process does. */
                process order_fulfilment "Order fulfilment" {
                  doc "From a placed order to a shipped parcel."

                  start placed "Order placed"

                  service charge "Charge card" {
                    type "payment-charge"
                    retries 3
                    input amount = "=order.total"
                    output transactionId = "=result.transactionId"
                  }

                  xor is_valid "Order valid?" {
                    branch "valid" otherwise
                    branch "invalid" when "=not(valid)" {
                      user fix "Correct the order" {
                        groups "order-desk"
                      }
                      goto charge
                    }
                  }

                  wait await_payment "Await confirmation" {
                    message payment_confirmed
                  }

                  end shipped "Shipped"

                  on charge catch error payment_failed as charge_failed "Payment failed" {
                    end payment_aborted "Order abandoned" { terminate }
                  }
                }

                collaboration orders "Orders" {
                  pool customer "Customer"
                  customer ~> order_fulfilment "places order"
                }
                """;
    }

    @Override
    public @Nullable Map<String, TextAttributesKey> getAdditionalHighlightingTagToDescriptorMap() {
        return null;
    }

    @Override
    public AttributesDescriptor @NotNull [] getAttributeDescriptors() {
        return DESCRIPTORS;
    }

    @Override
    public ColorDescriptor @NotNull [] getColorDescriptors() {
        return ColorDescriptor.EMPTY_ARRAY;
    }

    @Override
    public @NotNull String getDisplayName() {
        return "Sequent";
    }
}
