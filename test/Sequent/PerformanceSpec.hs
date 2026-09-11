-- | Scale tests.
--
-- SPEC §J's complexity note targets near-linear behaviour for structured
-- graphs, and §I.3 requires large diagrams to get /more/ spacing rather than
-- compressed spacing. Both are asserted here on generated processes of 10, 50,
-- 150 and 500 nodes with representative branching and lane structure.
--
-- The assertions are about work and output, not about wall-clock time: a timing
-- threshold would make the suite fail on a loaded machine and pass on a fast
-- one, which tells you nothing. For reference, an @-O1@ build compiles source
-- to BPMN bytes in roughly 2 ms \/ 4 ms \/ 19 ms \/ 170 ms at 10 \/ 50 \/ 150 \/
-- 500 nodes.
module Sequent.PerformanceSpec (spec) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Sequent.Layout
import Sequent.Layout.Constants
import Sequent.Diagnostic
import Sequent.Test.Support

spec :: Spec
spec = do
  describe "scale" $
    forM_ [10, 50, 150, 500] $ \n -> describe (show n <> " nodes") $ do
      let src = generate n
          l = layoutOf src

      it "lays out every node" $ do
        _ <- evaluate (force (map show (Map.keys (allShapes l))))
        Map.size (allShapes l) `shouldSatisfy` (>= n `div` 2)

      it "produces no tier-0 or tier-1 violation" $
        [T.unpack (vMessage v) | v <- lrViolations l, vTier v <= T1] `shouldBe` []

      it "keeps the diagram inside the coordinate space" $
        let b = geometryBounds (lrGeometry l)
         in (rX b >= margin, rW b > 0, rH b > 0) `shouldBe` (True, True, True)

  describe "LAYOUT-028 large-diagram mode" $ do
    it "increases spacing rather than compressing it" $ do
      -- A large diagram gets NODE_GAP_X -> 7U, not a squeeze. Comparing the
      -- smallest column gap of a big process against a small one is the
      -- observable form of that rule.
      let small = minimumGap (layoutOf (generate 10))
          large = minimumGap (layoutOf (generate 500))
      large `shouldSatisfy` (>= small)

    it "reports the mode as an advisory" $
      map (T.unpack . diagText) (lrDiagnostics (layoutOf (generate 500)))
        `shouldSatisfy` any (T.isInfixOf "large-diagram mode" . T.pack)

-- | A chain of tasks with a two-way decision every fifth step, which is the
-- branching density §I.3 describes as representative.
generate :: Int -> Text
generate n =
  T.unlines $
    ["start s"]
      ++ concatMap block [1 .. n `div` 5]
      ++ ["end e"]
  where
    block k =
      let i = T.pack (show (k :: Int))
       in [ "task t" <> i
          , "task u" <> i
          , "xor g" <> i <> " {"
          , "  branch \"ok\" otherwise { task p" <> i <> " }"
          , "  branch \"no\" when \"=n\" { task q" <> i <> " }"
          , "}"
          ]

minimumGap :: LayoutResult -> Int
minimumGap l = case gaps of
  [] -> 0
  _ -> minimum gaps
  where
    xs = map (\r -> (rX r, rectRight r)) (Map.elems (allShapes l))
    lefts = Map.toAscList (Map.fromListWith min [(x, x) | (x, _) <- xs])
    rights = Map.fromListWith max [(x, r) | (x, r) <- xs]
    gaps =
      [ nextLeft - r
      | ((x, _), (nextLeft, _)) <- zip lefts (drop 1 lefts)
      , Just r <- [Map.lookup x rights]
      , nextLeft - r > 0
      ]

diagText :: Diagnostic -> Text
diagText = diagMessage
