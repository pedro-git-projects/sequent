module Sequent.MetricsSpec (spec) where

import qualified Data.Text as T
import Test.Hspec

import Sequent.Layout.Constants
import Sequent.Layout.Labels
import Sequent.Text.Metrics

spec :: Spec
spec = do
  describe "text measurement" $ do
    it "is a compiled-in table, not a per-character average" $
      -- "iii" and "mmm" are the same length and very different widths; an
      -- average-width fallback cannot tell them apart, and every label-driven
      -- growth decision would then be wrong for narrow and wide text alike.
      measure helvetica12 "iii" `shouldSatisfy` (< measure helvetica12 "mmm")

    it "is deterministic for the same input" $
      measure helvetica12 "Validate order" `shouldBe` measure helvetica12 "Validate order"

    it "grows monotonically with text" $
      measure helvetica12 "Validate" `shouldSatisfy` (<= measure helvetica12 "Validate order")

    it "reports zero for the empty string" $
      measure helvetica12 "" `shouldBe` 0

    it "lets a test substitute synthetic metrics" $
      measure monospaceMetrics "abcd" `shouldBe` measure monospaceMetrics "mmmm"

  describe "wrapping (LABEL-001)" $ do
    it "breaks on whitespace first" $
      tbLines (wrapText helvetica12 90 4 "Validate the incoming order")
        `shouldSatisfy` \ls -> length ls > 1 && all (not . T.isInfixOf "  ") ls

    it "breaks inside a word only when the word does not fit alone" $
      tbLines (wrapText helvetica12 40 4 "Extraordinarily") `shouldSatisfy` ((> 1) . length)

    it "breaks after a slash" $
      tbLines (wrapText helvetica12 60 4 "receive/validate/dispatch")
        `shouldSatisfy` any (T.isSuffixOf "/")

    it "clamps to the line budget with an ellipsis" $
      let box = wrapText helvetica12 90 2 "one two three four five six seven eight nine ten"
       in (length (tbLines box), T.isSuffixOf "\x2026" (last (tbLines box))) `shouldBe` (2, True)

  describe "the growth ladder (LAYOUT-029)" $ do
    it "leaves a short label at the canonical size" $
      activityGrowthLadder helvetica12 False "Ship" `shouldBe` (taskW, taskH)

    it "widens in 2U steps before heightening" $
      let (w, h) = activityGrowthLadder helvetica12 False (T.replicate 6 "Reconciliation ")
       in (w `mod` (2 * u), h >= taskH) `shouldBe` (0, True)

    it "never exceeds the maxima" $
      let (w, h) = activityGrowthLadder helvetica12 False (T.replicate 40 "long ")
       in (w <= taskWMax, h <= taskHMax) `shouldBe` (True, True)

    it "reserves the marker band when a marker is present" $
      let plain = snd (activityGrowthLadder helvetica12 False label)
          marked = snd (activityGrowthLadder helvetica12 True label)
          label = "Pick every line of the order and stage it"
       in marked `shouldSatisfy` (>= plain)

  describe "boundary-event host width (LAYOUT-016)" $ do
    it "keeps the canonical width for a single event" $
      hostWidthForBoundaries 1 `shouldBe` taskW

    it "grows to fit three events" $
      hostWidthForBoundaries 3 `shouldSatisfy` (>= requiredHostW 3)

    it "never exceeds TASK_W_MAX" $
      hostWidthForBoundaries 9 `shouldBe` taskWMax
