-- | Golden tests.
--
-- Two kinds, and they check different things:
--
--   * the canonical examples of SPEC §L, pinned to the /exact coordinates/ the
--     specification prints, so a change in the layout engine that drifts away
--     from the reference geometry fails here rather than being noticed by eye;
--   * whole-file BPMN goldens for @examples\/*.sq@, which pin the byte-exact
--     output and therefore catch any change in id policy, element order,
--     attribute order or geometry at once.
--
-- Set @SEQUENT_ACCEPT=1@ to rewrite the whole-file goldens.
module Sequent.GoldenSpec (spec) where

import Control.Monad (forM_)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath (replaceExtension, takeExtension, (</>))
import Test.Hspec

import Sequent.Compiler
import Sequent.Layout
import Sequent.Test.Support

spec :: Spec
spec = do
  describe "SPEC.md canonical examples" $ do
    it "pattern A: start -> task -> task -> end" $
      -- SPEC §L: centres (60,80) (190,80) (350,80) (480,80); bounds
      -- (42,40)-(498,120); every edge two waypoints and no bends.
      shapesOf "start s\ntask a \"Task A\"\ntask b \"Task B\"\nend e"
        ["StartEvent_s", "Activity_a", "Activity_b", "Event_e"]
        `shouldBe` [(42, 62, 36, 36), (140, 40, 100, 80), (300, 40, 100, 80), (462, 62, 36, 36)]

    it "pattern A: all edges are straight" $
      map (routeBends . routeOf (layoutOf patternA)) ["Flow_s_a", "Flow_a_b", "Flow_b_e"]
        `shouldBe` [0, 0, 0]

    it "pattern B: axis-locked xor keeps the rank-1 branch on the spine" $
      -- SPEC §L: Δaxis = 140 = TASK_H + BRANCH_GAP_Y; split and merge share cy;
      -- the axis branch has no bends and each off-axis leg has exactly one.
      let l = layoutOf patternB
          cy n = centreYOf l n
       in ( cy "Gateway_g" == cy "Gateway_g_join"
          , cy "Activity_approve" == cy "Gateway_g"
          , cy "Activity_reject" - cy "Gateway_g"
          , map (routeBends . routeOf l) ["Flow_g_approve", "Flow_g_reject", "Flow_reject_g_join"]
          )
            `shouldBe` (True, True, 140, [0, 1, 1])

    it "pattern C: three branches use upper / centre / lower" $
      let l = layoutOf patternC
          cy n = centreYOf l n
       in (cy "Activity_p2" == cy "Gateway_g", cy "Activity_p1" < cy "Gateway_g", cy "Activity_p3" > cy "Gateway_g")
            `shouldBe` (True, True, True)

    it "pattern D: parallel branches straddle the axis at +/- 70" $
      let l = layoutOf patternD
          g = centreYOf l "Gateway_g"
       in sort [centreYOf l "Activity_p" - g, centreYOf l "Activity_q" - g] `shouldBe` [-70, 70]

    it "pattern D: congruent branches occupy the same column" $
      let l = layoutOf patternD
       in leftOf l "Activity_p" `shouldBe` leftOf l "Activity_q"

    it "pattern E: the terminating branch ends as early as possible" $
      let l = layoutOf patternE
       in leftOf l "Event_stopped" `shouldSatisfy` (< leftOf l "Event_shipped")

    it "pattern F: the boundary event hangs on the host border and drops below" $
      let l = layoutOf patternF
          host = shapeOf l "Activity_pay"
          ev = shapeOf l "Event_failed"
          r = routeOf l "Flow_failed_compensate"
       in ( rectCenterY ev == rectBottom host
          , routeBends r
          , centreYOf l "Activity_compensate" > centreYOf l "Activity_pay"
          )
            `shouldBe` (True, 1, True)

    it "pattern G: the loopback runs in a corridor outside the region" $
      let l = layoutOf patternG
          r = routeOf l "Flow_g_fix"
          corridor = ptY (rtPoints r !! 1)
          spine = centreYOf l "Activity_fix"
       in (routeBends r, abs (corridor - spine) >= loopClearance) `shouldBe` (2, True)

    it "pattern H: the cross-lane Z jogs at the gap midpoint" $
      let l = layoutOf patternH
          pts = rtPoints (routeOf l "Flow_qualify_approve")
       in ( length pts
          , ptX (pts !! 1) == (rectRight (shapeOf l "Activity_qualify") + leftOf l "Activity_approve") `div` 2
          )
            `shouldBe` (4, True)

    it "pattern I: message flows connect the pools vertically" $
      let l = layoutOf patternI
          pts = rtPoints (routeOf l "MessageFlow_order_got")
       in (ptX (head pts) == ptX (pts !! 1), length pts >= 2) `shouldBe` (True, True)

    it "pattern J: the nested region centres on its own branch axis" $
      let l = layoutOf patternJ
       in ( centreYOf l "Gateway_h" == centreYOf l "Gateway_g"
          , centreYOf l "Activity_b1" /= centreYOf l "Gateway_g"
          )
            `shouldBe` (True, True)

  describe "examples" $ do
    sources <- runIO (sort . filter ((== ".sq") . takeExtension) <$> listDirectory "examples")

    it "has examples to check" $ sources `shouldSatisfy` (not . null)

    forM_ sources $ \name -> describe name $ do
      let src = "examples" </> name
          golden = replaceExtension src ".bpmn"

      it "compiles without errors" $ do
        out <- compileFile src
        T.unpack out `shouldContain` "<bpmn:definitions"

      it "matches the committed BPMN" $ do
        out <- compileFile src
        accept <- lookupEnv "SEQUENT_ACCEPT"
        exists <- doesFileExist golden
        case accept of
          Just _ -> TIO.writeFile golden out
          Nothing
            | not exists -> expectationFailure (golden <> " is missing; run with SEQUENT_ACCEPT=1")
            | otherwise -> do
                want <- TIO.readFile golden
                out `shouldBe` want

      it "is byte-identical when compiled twice" $ do
        a <- compileFile src
        b <- compileFile src
        a `shouldBe` b

-- Fixtures ---------------------------------------------------------------------

loopClearance :: Int
loopClearance = 30

patternA, patternB, patternC, patternD, patternE :: Text
patternA = "start s\ntask a \"Task A\"\ntask b \"Task B\"\nend e"
patternB = "start s\ntask a \"Task A\"\nxor g { branch \"Yes\" otherwise { task approve \"Approve\" } branch \"No\" when \"=n\" { task reject \"Reject\" } }\ntask b \"Task B\"\nend e"
patternC = "start s\ntask a \"Task A\"\nxor g { branch \"1\" when \"=a\" { task p1 \"Path 1\" } branch \"2\" otherwise { task p2 \"Path 2\" } branch \"3\" when \"=c\" { task p3 \"Path 3\" } }\ntask b \"Task B\"\nend e"
patternD = "start s\ntask a \"Task A\"\nand g { branch { task p \"Task P\" } branch { task q \"Task Q\" } }\ntask b \"Task B\"\nend e"
patternE = "start s\ntask check \"Check\"\nxor g { branch \"ok\" otherwise { task fulfil \"Fulfil\"\ntask ship \"Ship\"\nend shipped } branch \"rejected\" when \"=r\" { task notify \"Notify\"\nend stopped } }"

patternF, patternG, patternH, patternI, patternJ :: Text
patternF = "error boom \"BOOM\"\nprocess p { start s\nservice pay \"Call Payment\" { type \"pay\" }\ntask after \"Continue\"\nend e\non pay catch error boom as failed \"Failed\" { task compensate \"Compensate\"\nend aborted } }"
patternG = "start s\ntask fix \"Fix Data\"\ntask validate \"Validate\"\nxor g \"Valid?\" { branch \"valid\" otherwise\nbranch \"invalid\" when \"=n\" { goto fix } }\ntask cont \"Continue\"\nend e"
patternH = "lane sales \"Sales\" { start s\ntask qualify \"Qualify\" }\nlane finance \"Finance\" { task approve \"Approve\"\nend e }"
patternI = "collaboration c { pool customer \"Customer\" { start s\ntask order \"Order\"\nend done } pool supplier \"Supplier\" { start got \"Received\"\ntask accept \"Accept\"\nend shipped } order ~> got }"
patternJ = "start s\ntask a \"Task A\"\nxor g { branch \"A\" otherwise { xor h { branch \"A1\" otherwise { task a1 \"A1\" } branch \"A2\" when \"=x\" { task a2 \"A2\" } } } branch \"B\" when \"=y\" { task b1 \"B\" } }\ntask b \"Task B\"\nend e"

-- Helpers ---------------------------------------------------------------------

shapesOf :: Text -> [Text] -> [(Int, Int, Int, Int)]
shapesOf src names =
  [ (rX r, rY r, rW r, rH r)
  | n <- names
  , let r = shapeOf (layoutOf src) n
  ]

centreYOf :: LayoutResult -> Text -> Int
centreYOf l = rectCenterY . shapeOf l

leftOf :: LayoutResult -> Text -> Int
leftOf l = rX . shapeOf l

compileFile :: FilePath -> IO Text
compileFile path = do
  text <- TIO.readFile path
  let res = compileText defaultOptions path text
  case crXml res of
    Just x -> pure x
    Nothing -> fail (unlines (map show (crDiagnostics res)))
