module Sequent.IdSpec (spec) where

import Data.List (nub, sort)
import Data.Text (Text)
import Test.Hspec

import Sequent.Bpmn.Id
import Sequent.Bpmn.Semantic
import Sequent.Test.Support

spec :: Spec
spec = do
  describe "the id policy" $ do
    it "names ids after the declared symbolic names" $
      ids "start submitted\nservice validate { type \"v\" }\nxor decide { branch }\nend done"
        `shouldSatisfy` \is ->
          all
            (`elem` is)
            ["StartEvent_submitted", "Activity_validate", "Gateway_decide", "Event_done"]

    it "names flows after both endpoints" $
      flowIds "start a\nend b" `shouldBe` ["Flow_a_b"]

    it "names a derived merge after its split" $
      ids "start s\nxor g { branch \"y\" otherwise { task a } branch \"n\" when \"=n\" { task b } }\nend e"
        `shouldSatisfy` elem "Gateway_g_join"

    it "does not change ids when a label changes" $
      ids "start s \"One label\"\ntask t \"Another\"\nend e"
        `shouldBe` ids "start s \"Completely different\"\ntask t \"Also different\"\nend e"

    it "does not renumber a node when an unrelated edge is added" $
      let idsAfter = ids "start s\ntask a\ntask b\nend e\nflow a -> e"
       in ids "start s\ntask a\ntask b\nend e" `shouldSatisfy` all (`elem` idsAfter)

    it "suffixes only on collision" $ do
      -- An end event named t_timer wants the id the boundary timer on t wants.
      let src = "start s\ntask t\nend t_timer\non t catch timer \"PT1M\" as spare { goto t_timer }"
      ids src `shouldSatisfy` elem "Event_t_timer"
      ids src `shouldSatisfy` elem "Event_spare"

    it "emits ids that are valid NCNames" $
      allIds "start s\nservice x { type \"t\" }\nxor g { branch }\nend e"
        `shouldSatisfy` all isValidNCName

    it "emits no duplicate ids" $
      let is = allIds "start s\nservice x { type \"t\" }\nxor g { branch \"a\" otherwise { task p } branch \"b\" when \"=b\" { task q } }\nend e"
       in sort is `shouldBe` sort (nub is)

  describe "sanitisation" $ do
    it "replaces characters an NCName cannot hold" $
      sanitize "a b/c" `shouldBe` "a_b_c"

    it "prefixes a leading digit" $
      sanitize "1st" `shouldBe` "_1st"

    it "never produces the empty string" $
      sanitize "" `shouldBe` "_"

  describe "derived names" $ do
    it "derives the DI id from the element id" $
      diId "Activity_x" `shouldBe` "Activity_x_di"

    it "derives the event definition id from its owner" $
      defId "Event_x" `shouldBe` "Event_x_def"

    it "derives a data object id by swapping the class prefix" $
      dataObjectIdFor "DataObjectReference_receipt" `shouldBe` "DataObject_receipt"

-- Helpers --------------------------------------------------------------------

nodesOf :: Text -> [FlowNode]
nodesOf src = case sgProcesses (graphOf src) of
  (p : _) -> concatMap scNodes (allScopes (procScope p))
  [] -> []

ids :: Text -> [Text]
ids = map (unNodeId . fnId) . nodesOf

flowIds :: Text -> [Text]
flowIds src = case sgProcesses (graphOf src) of
  (p : _) -> [unFlowId (sfId f) | sc <- allScopes (procScope p), f <- scFlows sc]
  [] -> []

allIds :: Text -> [Text]
allIds src = ids src ++ flowIds src ++ [unProcessId (procId p) | p <- sgProcesses (graphOf src)]
