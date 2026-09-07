-- | Camunda 8 (Zeebe) execution metadata.
--
-- This is deliberately a separate model from "Sequent.Bpmn.Semantic". The
-- semantic graph carries an 'ExecutionMeta' on each flow node and never looks
-- inside it: nothing in name resolution, region detection, layering, banding,
-- routing or scoring may branch on a Zeebe attribute. That keeps the layout
-- engine a function of BPMN meaning alone, and it keeps "what Camunda needs in
-- the XML" from leaking into the compiler's shape.
--
-- Only "Sequent.Camunda.Validate" and "Sequent.Camunda.Serialize" interpret
-- these values.
module Sequent.Camunda.Model
  ( ExecutionMeta (..)
  , noExecution
  , FeelExpr (..)
  , feel
  , isFeel
  , ZeebeTask (..)
  , emptyZeebeTask
  , UserTaskSpec (..)
  , emptyUserTask
  , ScriptSpec (..)
  , DecisionSpec (..)
  , CalledElement (..)
  , Mapping (..)
  , Header (..)
  , LoopSpec (..)
  , ioOf
  , headersOf
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | A FEEL expression as Camunda wants it: with the leading @=@ present.
-- Construct with 'feel', which adds the @=@ when the author omitted it.
newtype FeelExpr = FeelExpr {unFeel :: Text}
  deriving (Eq, Ord, Show)

-- | Camunda expects FEEL expressions to carry a leading @=@; authors routinely
-- forget it, and the failure mode (a literal string where an expression was
-- meant) is silent at deploy time. Normalising here is a documented deviation
-- from "the source is the truth": the formatter also writes the @=@ back, so
-- the source converges on the normalised form rather than diverging from it.
feel :: Text -> FeelExpr
feel t
  | isFeel t = FeelExpr t
  | otherwise = FeelExpr ("=" <> t)

isFeel :: Text -> Bool
isFeel = T.isPrefixOf "=" . T.stripStart

-- | The execution metadata a single flow node carries. Most nodes carry none.
data ExecutionMeta
  = ExNone
  | ExService ZeebeTask
  | ExUser UserTaskSpec
  | ExScript ScriptSpec
  | ExDecision DecisionSpec
  | ExCall CalledElement
  deriving (Eq, Show)

noExecution :: ExecutionMeta
noExecution = ExNone

-- | One @zeebe:input@ or @zeebe:output@: an expression and the variable it
-- lands in.
data Mapping = Mapping
  { mapTarget :: Text
  , mapSource :: FeelExpr
  }
  deriving (Eq, Show)

data Header = Header
  { hdrKey   :: Text
  , hdrValue :: Text
  }
  deriving (Eq, Show)

-- | @zeebe:taskDefinition@ plus the @ioMapping@ and @taskHeaders@ that hang off
-- the same @extensionElements@.
data ZeebeTask = ZeebeTask
  { ztType    :: Text
  , ztRetries :: Maybe Int
  , ztInputs  :: [Mapping]
  , ztOutputs :: [Mapping]
  , ztHeaders :: [Header]
  }
  deriving (Eq, Show)

emptyZeebeTask :: Text -> ZeebeTask
emptyZeebeTask t = ZeebeTask t Nothing [] [] []

-- | @zeebe:userTask@ plus its form and assignment definitions.
data UserTaskSpec = UserTaskSpec
  { utForm           :: Maybe Text
  , utAssignee       :: Maybe FeelExpr
  , utCandidateGroups :: Maybe FeelExpr
  , utCandidateUsers :: Maybe FeelExpr
  , utDueDate        :: Maybe FeelExpr
  , utInputs         :: [Mapping]
  , utOutputs        :: [Mapping]
  }
  deriving (Eq, Show)

emptyUserTask :: UserTaskSpec
emptyUserTask = UserTaskSpec Nothing Nothing Nothing Nothing Nothing [] []

-- | @zeebe:script@ — an inline FEEL expression and the variable its result
-- lands in.
data ScriptSpec = ScriptSpec
  { scExpression :: FeelExpr
  , scResult     :: Text
  , scInputs     :: [Mapping]
  , scOutputs    :: [Mapping]
  }
  deriving (Eq, Show)

-- | @zeebe:calledDecision@ — a DMN decision invoked by a business-rule task.
data DecisionSpec = DecisionSpec
  { dsDecisionId :: Text
  , dsResult     :: Text
  , dsInputs     :: [Mapping]
  , dsOutputs    :: [Mapping]
  }
  deriving (Eq, Show)

-- | @zeebe:calledElement@ — the process a call activity starts.
data CalledElement = CalledElement
  { ceProcessId          :: Text
  , cePropagateAllChildVariables :: Bool
  , ceInputs             :: [Mapping]
  , ceOutputs            :: [Mapping]
  }
  deriving (Eq, Show)

-- | @bpmn:multiInstanceLoopCharacteristics@ with its @zeebe:loopCharacteristics@.
-- Held on the activity rather than in 'ExecutionMeta' because the outer element
-- is plain BPMN; only the input collection is Zeebe-specific.
data LoopSpec = LoopSpec
  { lsSequential      :: Bool
  , lsInputCollection :: FeelExpr
  , lsInputElement    :: Text
  , lsOutputCollection :: Maybe Text
  , lsOutputElement   :: Maybe FeelExpr
  }
  deriving (Eq, Show)

-- | The input and output mappings of any execution metadata, in emission order.
ioOf :: ExecutionMeta -> ([Mapping], [Mapping])
ioOf m = case m of
  ExNone -> ([], [])
  ExService z -> (ztInputs z, ztOutputs z)
  ExUser uu -> (utInputs uu, utOutputs uu)
  ExScript s -> (scInputs s, scOutputs s)
  ExDecision d -> (dsInputs d, dsOutputs d)
  ExCall c -> (ceInputs c, ceOutputs c)

headersOf :: ExecutionMeta -> [Header]
headersOf (ExService z) = ztHeaders z
headersOf _ = []
