module Main (main) where

import Test.Hspec

import qualified Sequent.DeterminismSpec
import qualified Sequent.GoldenSpec
import qualified Sequent.IdSpec
import qualified Sequent.LayoutInvariantSpec
import qualified Sequent.MetricsSpec
import qualified Sequent.ParserSpec
import qualified Sequent.PerformanceSpec
import qualified Sequent.PrettySpec
import qualified Sequent.ResolveSpec
import qualified Sequent.SerializeSpec
import qualified Sequent.SpecRuleSpec
import qualified Sequent.XmlSpec

main :: IO ()
main = hspec $ do
  describe "Sequent.Camunda.Xml" Sequent.XmlSpec.spec
  describe "Sequent.Text.Metrics" Sequent.MetricsSpec.spec
  describe "Sequent.Language.Parser" Sequent.ParserSpec.spec
  describe "Sequent.Language.Resolve" Sequent.ResolveSpec.spec
  describe "Sequent.Language.Pretty" Sequent.PrettySpec.spec
  describe "Sequent.Bpmn.Id" Sequent.IdSpec.spec
  describe "Sequent.Camunda.Serialize" Sequent.SerializeSpec.spec
  describe "layout invariants" Sequent.LayoutInvariantSpec.spec
  describe "SPEC rules" Sequent.SpecRuleSpec.spec
  describe "determinism" Sequent.DeterminismSpec.spec
  describe "golden" Sequent.GoldenSpec.spec
  describe "performance" Sequent.PerformanceSpec.spec
