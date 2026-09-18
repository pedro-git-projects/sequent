-- | The one deterministic BPMN identifier policy.
--
-- __Policy.__ Every BPMN id is @\<Prefix\>_\<sanitised symbolic name\>@, where
-- the symbolic name is what the author wrote in the source. Consequences,
-- which are the properties the policy exists to guarantee:
--
--   * no UUIDs and no randomness — an id is a pure function of the source name;
--   * labels are not identity — renaming @"Validate order"@ to @"Check order"@
--     leaves @Activity_validate@ alone;
--   * unrelated edits do not rename unrelated elements — ids come from names,
--     never from a counter over the document;
--   * references stay stable — a flow id is built from its two endpoint names,
--     so re-ordering declarations cannot renumber it.
--
-- Collisions are resolved with a numeric suffix, and allocation runs in a fixed
-- class order ('allocationClasses') so that adding an edge can never renumber a
-- node. Ids are valid XML @NCName@s by construction.
--
-- All id construction goes through this module. String concatenation in the
-- serialiser is what makes id policy unknowable, so the serialiser only ever
-- consumes ids and the two derived-name helpers ('diId', 'defId').
module Sequent.Bpmn.Id
  ( -- * The pool
    IdPool
  , emptyPool
  , IdClass (..)
  , allocationClasses
  , classPrefix
  , alloc
  , allocFlowName
  , reserve
    -- * Derived names
  , diId
  , defId
  , dataObjectIdFor
  , categoryIdFor
  , categoryValueIdFor
    -- * Sanitisation
  , sanitize
  , isValidNCName
  ) where

import Data.Char (isAlpha, isAlphaNum, isDigit)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

-- | The kinds of element that get an id, and the prefix each one carries. The
-- prefixes match what Camunda Modeler itself generates, so a hand-edited
-- diagram and a compiled one look like the same family of file.
data IdClass
  = IcDefinitions
  | IcCollaboration
  | IcParticipant
  | IcProcess
  | IcLaneSet
  | IcLane
  | IcStartEvent
  | IcEndEvent
  | IcIntermediateEvent
  | IcBoundaryEvent
  | IcActivity
  | IcGateway
  | IcSequenceFlow
  | IcMessageFlow
  | IcAssociation
  | IcDataObject
  | IcDataObjectRef
  | IcTextAnnotation
  | IcGroup
  | IcMessage
  | IcSignal
  | IcError
  | IcEscalation
  deriving (Eq, Ord, Show, Enum, Bounded)

classPrefix :: IdClass -> Text
classPrefix c = case c of
  IcDefinitions -> "Definitions_"
  IcCollaboration -> "Collaboration_"
  IcParticipant -> "Participant_"
  IcProcess -> "Process_"
  IcLaneSet -> "LaneSet_"
  IcLane -> "Lane_"
  IcStartEvent -> "StartEvent_"
  IcEndEvent -> "Event_"
  IcIntermediateEvent -> "Event_"
  IcBoundaryEvent -> "Event_"
  IcActivity -> "Activity_"
  IcGateway -> "Gateway_"
  IcSequenceFlow -> "Flow_"
  IcMessageFlow -> "MessageFlow_"
  IcAssociation -> "Association_"
  IcDataObject -> "DataObject_"
  IcDataObjectRef -> "DataObjectReference_"
  IcTextAnnotation -> "TextAnnotation_"
  IcGroup -> "Group_"
  IcMessage -> "Message_"
  IcSignal -> "Signal_"
  IcError -> "Error_"
  IcEscalation -> "Escalation_"

-- | The order in which classes are allocated. Flow nodes are allocated before
-- flows, and flows before artifacts, so that adding an edge cannot shift the
-- suffix of a node that happened to collide — the classic churn source in
-- generated BPMN.
allocationClasses :: [IdClass]
allocationClasses = [minBound .. maxBound]

-- | The set of ids already handed out.
newtype IdPool = IdPool (Set Text)
  deriving (Eq, Show)

emptyPool :: IdPool
emptyPool = IdPool Set.empty

-- | Take an id out of circulation without deriving it from a name. Used for
-- the few fixed ids (@Definitions_1@, the diagram and plane) so that a source
-- name can never collide with them.
reserve :: Text -> IdPool -> IdPool
reserve t (IdPool s) = IdPool (Set.insert t s)

-- | Allocate the id for one declared name. The first claimant of a name gets
-- the unsuffixed id; later claimants get @_2@, @_3@ and so on, in allocation
-- order, which is deterministic because allocation order is.
alloc :: IdClass -> Text -> IdPool -> (Text, IdPool)
alloc c name (IdPool used) = go (1 :: Int)
  where
    base = classPrefix c <> sanitize name
    go n =
      let cand = if n == 1 then base else base <> "_" <> T.pack (show n)
       in if Set.member cand used
            then go (n + 1)
            else (cand, IdPool (Set.insert cand used))

-- | The name a sequence or message flow is allocated under: both endpoint
-- symbolic names, so the id reads the way the source does and stays put when
-- unrelated declarations move.
allocFlowName :: Text -> Text -> Text
allocFlowName from to = sanitize from <> "_" <> sanitize to

-- | The DI shape/edge id for an element. BPMN DI ids are not referenced from
-- anywhere else, so deriving them keeps one id per element in the source model.
diId :: Text -> Text
diId t = t <> "_di"

-- | The id of an event definition owned by an event.
defId :: Text -> Text
defId t = t <> "_def"

-- | The @bpmn:dataObject@ behind a @bpmn:dataObjectReference@. BPMN splits one
-- source declaration into two elements, so the second id is derived from the
-- first by swapping the class prefix rather than allocated separately — that
-- keeps one declaration to one allocated id.
dataObjectIdFor :: Text -> Text
dataObjectIdFor refId =
  classPrefix IcDataObject <> fromMaybe refId (T.stripPrefix (classPrefix IcDataObjectRef) refId)

-- | The @bpmn:category@ and @bpmn:categoryValue@ behind a @bpmn:group@.
--
-- BPMN spends three elements on one group: the group points at a category
-- value, the category value holds the text, and a category holds the value.
-- Only the group is declared in source, so the other two ids are derived from
-- it for the same reason 'dataObjectIdFor' derives its own — one declaration
-- gets one allocated id, and nothing in the file can collide with a name the
-- author never wrote.
categoryIdFor :: Text -> Text
categoryIdFor groupId = "Category_" <> groupBody groupId

categoryValueIdFor :: Text -> Text
categoryValueIdFor groupId = "CategoryValue_" <> groupBody groupId

groupBody :: Text -> Text
groupBody groupId = fromMaybe groupId (T.stripPrefix (classPrefix IcGroup) groupId)

-- | Coerce arbitrary text into an XML @NCName@ body. Characters outside the
-- @NCName@ set become @_@; a leading digit or @-@ or @.@ gets an underscore in
-- front. Callers always prepend a class prefix, but the leading-character rule
-- is enforced here too so the function is correct on its own.
sanitize :: Text -> Text
sanitize t
  | T.null cleaned = "_"
  | not (validStart (T.head cleaned)) = T.cons '_' cleaned
  | otherwise = cleaned
  where
    cleaned = T.map keep t
    keep ch
      | isAlphaNum ch || ch == '_' || ch == '-' || ch == '.' = ch
      | otherwise = '_'
    validStart ch = isAlpha ch || ch == '_'

-- | Whether a string is already a valid @NCName@. Used by tests to assert the
-- property the policy claims, over every id the compiler emits.
isValidNCName :: Text -> Bool
isValidNCName t = case T.uncons t of
  Nothing -> False
  Just (h, rest) -> startOk h && T.all bodyOk rest
  where
    startOk ch = (isAlpha ch || ch == '_') && not (isDigit ch)
    bodyOk ch = isAlphaNum ch || ch == '_' || ch == '-' || ch == '.'
