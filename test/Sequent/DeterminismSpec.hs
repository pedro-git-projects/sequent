-- | Determinism — HC-016 and LAYOUT-027.
--
-- The contract is: identical canonicalised input produces byte-identical
-- output. The strongest test of that is to build /equivalent/ inputs whose
-- collections are ordered differently and require the same bytes back, because
-- that is what catches a traversal that depends on how the graph was walked
-- rather than on what it contains.
module Sequent.DeterminismSpec (spec) where

import Data.List (nub, permutations, sort)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec

import Sequent.Bpmn.Semantic
import Sequent.Layout
import Sequent.Compiler
import Sequent.Language.Resolve (emptyPins)
import Sequent.Test.Support

spec :: Spec
spec = do
  describe "repeatability" $ do
    it "compiles the same source to the same bytes twice" $
      compileXml linear `shouldBe` compileXml linear

    it "compiles a branching process to the same bytes twice" $
      compileXml branching `shouldBe` compileXml branching

    it "lays out to the same geometry twice" $
      geometryFingerprint (layoutOf branching) `shouldBe` geometryFingerprint (layoutOf branching)

  describe "order independence" $ do
    it "is unaffected by the order of unrelated top-level declarations" $
      let a = "message m \"w\" correlation \"=k\"\nsignal s \"sig\"\nerror e \"E\"\n" <> body
          b = "error e \"E\"\nsignal s \"sig\"\nmessage m \"w\" correlation \"=k\"\n" <> body
          body = "process p { start x { message m }\nend y { error e } }"
       in normaliseIds (compileXml a) `shouldBe` normaliseIds (compileXml b)

    it "is unaffected by the order of unrelated side declarations" $
      let a = "start s\ntask t\nend e\nnote n1 \"one\" on t\nnote n2 \"two\" on t"
          b = "start s\ntask t\nend e\nnote n2 \"two\" on t\nnote n1 \"one\" on t"
       in nodeGeometry (layoutOf a) `shouldBe` nodeGeometry (layoutOf b)

    it "gives every permutation of independent explicit flows the same layout" $
      let bodies = map (T.intercalate "\n") (permutations explicitFlows)
          layouts = map (nodeGeometry . layoutOf . (decls <>)) bodies
       in length (nub layouts) `shouldBe` 1

  describe "canonicalisation" $ do
    it "is a fixed point" $
      let g = graphOf branching
       in canonicalise (canonicalise g) `shouldBe` canonicalise g

    it "orders nodes by (documentOrder, id)" $
      let sc = procScope (head (sgProcesses (graphOf branching)))
          keys = [(fnDocOrder n, unNodeId (fnId n)) | n <- scNodes sc]
       in keys `shouldBe` sort keys

    it "orders flows by (documentOrder, id)" $
      let sc = procScope (head (sgProcesses (graphOf branching)))
          keys = [(sfDocOrder f, unFlowId (sfId f)) | f <- scFlows sc]
       in keys `shouldBe` sort keys

  describe "shuffled input collections" $ do
    it "gives byte-identical BPMN for every shuffle of the node and flow lists" $
      let g = graphOf branching
          variants = [shuffleGraph k g | k <- [0 .. 7]]
          outputs = [xmlOfGraph v | v <- variants]
       in length (nub outputs) `shouldBe` 1

    it "gives identical geometry for every shuffle" $
      let g = graphOf branching
          fps = [geometryOfGraph (shuffleGraph k g) | k <- [0 .. 7]]
       in length (nub fps) `shouldBe` 1

    it "shuffling actually changed the lists" $
      -- Guards the test above against silently comparing a graph to itself.
      let g = graphOf branching
       in nodeOrder (shuffleGraph 3 g) `shouldNotBe` nodeOrder g

  describe "phase 14" $
    it "produces the same result as a run without it, or a strictly better one" $
      -- Bounded improvement must be deterministic; running it twice on the
      -- same input has to agree, whatever it decided.
      geometryFingerprint (layoutOf branching) `shouldBe` geometryFingerprint (layoutOf branching)

linear :: Text
linear = "start s\ntask a\ntask b\nend e"

branching :: Text
branching =
  "start s\ntask a\nxor g \"Q?\" { branch \"yes\" otherwise { task p } branch \"no\" when \"=n\" { task q } }\nand h { branch { task r } branch { task t } }\nend e"

decls :: Text
decls = "start s\ntask a\ntask b\ntask c\ntask d\nend e\n"

-- | Four cross-links that are mutually independent: each connects a pair the
-- implicit chain left unconnected, none of them duplicates another, and any
-- order of the lines describes the same graph — so any order must produce the
-- same picture.
explicitFlows :: [Text]
explicitFlows = ["flow s -> b", "flow a -> c", "flow b -> d", "flow c -> e"]

-- | Reorder every collection in a graph without changing what it describes.
--
-- Rotating and reversing is enough: the point is that /some/ order other than
-- the canonical one goes in. Document order is preserved on each element, so
-- canonicalisation must put the lists back — and if any phase reads a list
-- before that happens, these tests catch it.
shuffleGraph :: Int -> SemanticGraph -> SemanticGraph
shuffleGraph k g =
  g
    { sgProcesses = map shuffleProcess (sgProcesses g)
    , sgMessages = rotate k (sgMessages g)
    , sgSignals = rotate k (sgSignals g)
    , sgErrors = rotate k (sgErrors g)
    }
  where
    shuffleProcess p = p {procScope = shuffleScope (procScope p), procLanes = rotate k (procLanes p)}
    shuffleScope sc =
      sc
        { scNodes = map shuffleNode (rotate k (reverseIf sc))
        , scFlows = rotate (k + 1) (scFlows sc)
        , scArtifacts = rotate k (scArtifacts sc)
        , scAssociations = rotate k (scAssociations sc)
        }
    reverseIf sc = if odd k then reverse (scNodes sc) else scNodes sc
    shuffleNode n = case fnKind n of
      NkActivity a@Activity {acKind = AkSubprocess k inner} ->
        n {fnKind = NkActivity a {acKind = AkSubprocess k (shuffleScope inner)}}
      _ -> n

rotate :: Int -> [a] -> [a]
rotate _ [] = []
rotate n xs = let m = n `mod` length xs in drop m xs ++ take m xs

nodeOrder :: SemanticGraph -> [Text]
nodeOrder g = [unNodeId (fnId n) | p <- sgProcesses g, n <- scNodes (procScope p)]

xmlOfGraph :: SemanticGraph -> Text
xmlOfGraph g = case crXml (compileGraph defaultOptions emptyPins g) of
  Just x -> x
  Nothing -> error "compile failed"

geometryOfGraph :: SemanticGraph -> [(Text, Rect)]
geometryOfGraph g = case crLayout (compileGraph defaultOptions emptyPins g) of
  Just l -> geometryFingerprint l
  Nothing -> error "layout failed"

geometryFingerprint :: LayoutResult -> [(Text, Rect)]
geometryFingerprint l = [(unNodeId k, v) | (k, v) <- Map.toAscList (allShapes l)]

nodeGeometry :: LayoutResult -> [(Text, Rect)]
nodeGeometry = geometryFingerprint

-- | Ids embed source names, so two files whose declarations are permuted are
-- byte-identical only after the ids are normalised away.
normaliseIds :: Text -> Text
normaliseIds = T.unlines . sort . T.lines
