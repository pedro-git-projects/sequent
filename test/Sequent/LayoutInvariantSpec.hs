-- | Layout invariants — the hard constraints of SPEC §C, asserted over a
-- corpus of processes rather than over one hand-picked case.
--
-- These are the properties that make a diagram a diagram at all. They are
-- checked structurally, from the rendered geometry, so a regression anywhere in
-- the fourteen phases shows up here regardless of which phase caused it.
module Sequent.LayoutInvariantSpec (spec) where

import Control.Monad (forM_)
import Data.List (tails)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Sequent.Bpmn.Semantic
import Sequent.Layout
import Sequent.Layout.Constants
import Sequent.Test.Support

-- | The corpus. Every invariant below is asserted over all of it.
corpus :: [(String, Text)]
corpus =
  [ ("linear", "start s\ntask a\ntask b\nend e")
  , ("two-branch xor", "start s\nxor g { branch \"yes\" otherwise { task a } branch \"no\" when \"=n\" { task b } }\nend e")
  , ("three-way xor", "start s\nxor g { branch \"a\" otherwise { task p } branch \"b\" when \"=b\" { task q } branch \"c\" when \"=c\" { task r } }\nend e")
  , ("parallel", "start s\nand g { branch { task p } branch { task q } }\nend e")
  , ("terminating branch", "start s\nxor g { branch \"ok\" otherwise { task a\ntask b\nend done } branch \"stop\" when \"=n\" { task c\nend stopped } }")
  , ("boundary", "error boom \"BOOM\"\nprocess p { start s\ntask t\nend e\non t catch error boom as failed { task h\nend aborted } }")
  , ("loopback", "start s\ntask a\ntask b\nxor g { branch \"ok\" otherwise\nbranch \"retry\" when \"=r\" { goto a } }\ntask c\nend e")
  , ("cross-lane", "lane one \"One\" { start s\ntask a }\nlane two \"Two\" { task b\nend e }")
  , ("nested gateways", "start s\nxor g { branch \"a\" otherwise { xor h { branch \"a1\" otherwise { task p } branch \"a2\" when \"=x\" { task q } } } branch \"b\" when \"=y\" { task r } }\nend e")
  , ("subprocess", "start s\nsubprocess sub { start b\ntask t\nend d }\nend e")
  , ("multiple ends", "start s\nxor g { branch \"a\" otherwise { end x } branch \"b\" when \"=b\" { end y } branch \"c\" when \"=c\" { end z } }")
  , ("artifacts", "start s\ntask t\nend e\nnote n \"why\" on t\ndata d \"Doc\" from t")
    -- A branch whose only content is a 36 px event: the band pitch comes from
    -- the branch gap, but the stub the router needs is measured from the
    -- gateway's border, so a small node centred in that band can sit closer to
    -- the split than MIN_SEG allows (HC-005).
  , ("small event branches", "start s\nxor g { branch \"a\" when \"=a\" { wait w1 { timer \"PT5M\" } }\nbranch \"b\" when \"=b\" { wait w2 { timer \"PT9M\" } } }\nend e")
  , ("event gateway", "start s\nevent g { branch { wait w1 { timer \"PT5M\" } }\nbranch { wait w2 { timer \"PT9M\" } }\nbranch { wait w3 { timer \"PT8M\" } } }\nend e")
  , ("small event branches across lanes", "lane one \"One\" { start s\nxor g { branch \"a\" when \"=a\" { wait w1 { timer \"PT1M\" } }\nbranch \"b\" when \"=b\" { wait w2 { timer \"PT2M\" } } } }\nlane two \"Two\" { end e }")
    -- An expanded subprocess whose content hangs below its own spine, so the
    -- box centre is not the line the flow runs on (LAYOUT-020).
  , ("subprocess below its own spine", "error boom \"BOOM\"\nprocess p {\nstart s\nsubprocess sub \"Sub\" {\nstart b\ntask t \"Inner task\"\nend d\non t catch error boom as failed \"Inner failure\" { task h \"Handle it\"\nend aborted \"Given up\" } }\nend e }")
    -- A boundary handler that returns to a step on the host's own band: the
    -- canonical exception route would turn inside the host (EDGE-014, HC-004).
  , ("boundary goto onto the host's band", "message resolved \"resolved\" correlation \"=k\"\nprocess p {\nstart s\nservice alert \"Open alert incident\" { type \"alert\" }\nend handled \"Alert handled\"\non alert catch message resolved as fixed \"Incident is resolved\" { goto handled } }")
    -- Two captions longer than the host is wide, on boundary events one BE_GAP
    -- apart (LABEL-004, LABEL-006).
  , ("two labelled boundary events", "error one \"ONE\"\nerror two \"TWO\"\nprocess p {\nstart s\ntask t \"Do the thing\"\nend e\non t catch error one as first \"The first exceptional situation\" { end a \"A\" }\non t catch error two as second \"The second exceptional situation\" { end b \"B\" } }")
    -- A main path that reaches a normal end and an escalation end, beside a
    -- one-event branch, in an open region where every branch terminates
    -- (BRANCH-007, BRANCH-014, BRANCH-019).
  , ("a branch with mixed outcomes", "escalation esc \"ESC\" \"Finished\"\nerror boom \"BOOM\"\nprocess p \"P\" {\nstart s\nservice hub \"Hub\" { type \"h\" }\nxor pick \"Q?\" {\nbranch \"yes\" when \"=y\" { end stopped \"Stopped\" { terminate } }\nbranch \"no\" otherwise { and split \"Both\" {\nbranch { call rep \"Report\" { calls \"r\" }\nend reported \"Reported\" }\nbranch { end escalated \"Escalated\" { escalation esc } } } } }\nend aside \"Aside\"\nflow hub -> aside \"also\"\non hub catch error boom as failed \"Failed\" { end abandoned \"Abandoned\" { terminate } } }")
  ]

spec :: Spec
spec = forM_ corpus $ \(name, src) -> describe name $ do
  let l = layoutOf src
      shapes = Map.toAscList (allShapes l)
      routes = Map.toAscList (allRoutes l)
      nodes = nodesOf src
      byId = Map.fromList [(fnId n, n) | n <- nodes]
      hostOf n = Map.lookup n byId >>= boundaryHost >>= (Just . baHost)
      attached a b = hostOf a == Just b
      plainActivity n = case Map.lookup n byId of
        Just fn -> case fnKind fn of
          NkActivity a -> case acKind a of
            AkSubprocess _ _ -> False
            _ -> True
          _ -> False
        Nothing -> False

  it "HC-001: every connector segment is axis-parallel" $
    [f | (f, r) <- routes, s <- routeSegments (rtPoints r), not (segIsOrthogonal s)]
      `shouldBe` []

  it "HC-002: no two node boxes overlap" $
    [ (a, b)
    | (a, ra) : rest <- tails shapes
    , (b, rb) <- rest
    , not (attached a b || attached b a)
    , not (rectContains ra rb || rectContains rb ra)
    , rectsOverlap ra rb
    ]
      `shouldBe` []

  it "LABEL-006: no two label boxes overlap" $
    -- Labels are geometry (LABEL-011), so two of them overlapping is a defect,
    -- not a cosmetic detail. The anchor ladder exists to prevent it.
    [ (unNodeId (NodeId (labelName a)), unNodeId (NodeId (labelName b)))
    | (a, la) : rest <- tails (Map.toAscList (geoLabels (lrGeometry l)))
    , (b, lb) <- rest
    , rectsOverlap (lbRect la) (lbRect lb)
    ]
      `shouldBe` []

  it "LABEL-011: no label sits on a connector" $
    -- EDGE-018: a connector is an obstacle for a label exactly like a node box.
    -- Text with a line drawn through it is unreadable however well the boxes
    -- are placed.
    [ (labelName k, unFlowId f)
    | (k, lb) <- Map.toAscList (geoLabels (lrGeometry l))
    , (f, r) <- routes
    , not (ownsFlow k f)
    , any (`segIntersectsRect` lbRect lb) (routeSegments (rtPoints r))
    ]
      `shouldBe` []

  it "HC-010: no degenerate or collinear waypoints" $
    [f | (f, r) <- routes, degenerate (rtPoints r)] `shouldBe` []

  it "HC-011: coordinates are non-negative" $
    [n | (n, r) <- shapes, rX r < 0 || rY r < 0] `shouldBe` []

  it "HC-011: shape centres lie on the U grid" $
    [n | (n, r) <- shapes, rectCenterX r `mod` grid /= 0 || rectCenterY r `mod` grid /= 0]
      `shouldBe` []

  it "HC-011: waypoints are non-negative" $
    [f | (f, r) <- routes, p <- rtPoints r, ptX p < 0 || ptY p < 0] `shouldBe` []

  it "LAYOUT-003: activities keep the canonical height unless a rule permits growth" $
    [n | (n, r) <- shapes, plainActivity n, rH r /= taskH] `shouldBe` []

  it "LAYOUT-031: the diagram starts at the margin" $ do
    let b = geometryBounds (lrGeometry l)
    (rX b >= margin, rY b >= margin, rX b < margin + grid, rY b < margin + grid)
      `shouldBe` (True, True, True, True)

  it "EDGE-007: no connector exceeds the absolute bend limit" $
    [f | (f, r) <- routes, routeBends r > 6] `shouldBe` []

  it "HC-006: every boundary event sits on its host's border" $
    [ unNodeId (fnId n)
    | n <- nodes
    , Just att <- [boundaryHost n]
    , Just r <- [maybeShapeOf l (unNodeId (fnId n))]
    , Just hr <- [maybeShapeOf l (unNodeId (baHost att))]
    , not (onBorder hr r)
    ]
      `shouldBe` []

  it "T0/T1: the quality gates pass" $
    [T.unpack (vMessage v) | v <- lrViolations l, vTier v <= T1] `shouldBe` []

  it "is stable under recompilation" $
    Map.toAscList (allShapes (layoutOf src)) `shouldBe` shapes

-- Helpers --------------------------------------------------------------------

nodesOf :: Text -> [FlowNode]
nodesOf src = case sgProcesses (graphOf src) of
  (p : _) -> concatMap scNodes (allScopes (procScope p))
  [] -> []

onBorder :: Rect -> Rect -> Bool
onBorder hr r =
  let cx = rectCenterX r
      cy = rectCenterY r
      onH = cx >= rX hr && cx <= rectRight hr
      onV = cy >= rY hr && cy <= rectBottom hr
   in (onH && (cy == rY hr || cy == rectBottom hr)) || (onV && (cx == rX hr || cx == rectRight hr))

-- | EDGE-018: an edge may pass through its own label, which is drawn offset
-- from the segment it annotates. No other connector may.
ownsFlow :: LabelKey -> FlowId -> Bool
ownsFlow k f = case k of
  LkFlow g -> g == f
  _ -> False

labelName :: LabelKey -> Text
labelName k = case k of
  LkNode n -> unNodeId n
  LkFlow f -> unFlowId f
  LkArtifact a -> unArtifactId a

degenerate :: [Point] -> Bool
degenerate ps =
  or (zipWith (==) ps (drop 1 ps))
    || or
      [ (ptX a == ptX b && ptX b == ptX c) || (ptY a == ptY b && ptY b == ptY c)
      | (a, b, c) <- zip3 ps (drop 1 ps) (drop 2 ps)
      ]
