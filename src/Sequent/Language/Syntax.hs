-- | The surface AST: exactly what the author wrote, before any name is
-- resolved and before any id is invented.
--
-- Every construct carries the span it came from, so a diagnostic can point at
-- the offending characters rather than at a line number guessed after the fact.
-- The AST is deliberately not the semantic graph: it has branches nested inside
-- gateways (which BPMN does not), it has no sequence flows for the implicit
-- chaining between consecutive steps, and it has no merge gateways at all —
-- those are derived in "Sequent.Language.Resolve".
module Sequent.Language.Syntax
  ( -- * Positions
    Located (..)
  , Name
  , atSpan
    -- * Comments
  , Comment (..)
  , commentLines
    -- * File
  , SFile (..)
  , SDecl (..)
  , declSpan
    -- * Process and collaboration
  , SProcess (..)
  , SCollab (..)
  , SCItem (..)
  , SPool (..)
  , SMsgFlow (..)
    -- * Items
  , SItem (..)
  , itemSpan
  , SStep (..)
  , stepSpan
  , SNode (..)
  , SGateway (..)
  , SBranch (..)
  , SBranchItem (..)
  , branchesOf
  , SGuard (..)
  , SSub (..)
  , SHandler (..)
  , SGroup (..)
  , SGroupItem (..)
  , membersOf
  , SFlow (..)
  , SBoundary (..)
  , SNote (..)
  , SData (..)
  , DataDir (..)
  , SLane (..)
  , SPin (..)
    -- * Vocabulary
  , NodeKw (..)
  , GwKw (..)
  , STrigger (..)
  , SProp (..)
  , SPropBody (..)
  , nodeKeyword
  , gatewayKeyword
  , triggerKeyword
  , propKeyword
  , allNodeKeywords
  , allGatewayKeywords
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Diagnostic (Span (..), spanning)

data Located a = Located
  { locSpan :: Span
  , unLoc   :: a
  }
  deriving (Eq, Show)

instance Functor Located where
  fmap f (Located s a) = Located s (f a)

atSpan :: Located a -> Located b -> Span
atSpan a b = spanning (locSpan a) (locSpan b)

-- | A symbolic name as written. This is identity; the optional string beside it
-- is presentation text.
type Name = Located Text

-- | A comment, kept in the tree.
--
-- Comments are not meaning — nothing downstream of the parser reads one — but
-- they are the part of a source file a formatter has no right to throw away.
-- Holding them as ordinary elements of the list they were written in is what
-- lets the formatter put each one back where it was, in order, without any
-- position arithmetic.
data Comment = Comment
  { cmText     :: Text
  -- ^ The comment exactly as written, marker included.
  , cmTrailing :: Bool
  -- ^ 'True' when it followed code on the same line, so the formatter puts it
  -- back on that line instead of above the next one.
  , cmSpan     :: Span
  }
  deriving (Eq, Show)

-- | A comment's text as lines. A block comment may span several.
commentLines :: Comment -> [Text]
commentLines = T.lines . cmText

newtype SFile = SFile {sfDecls :: [SDecl]}
  deriving (Eq, Show)

data SDecl
  = DProcess SProcess
  | DCollaboration SCollab
  | -- | @message order_placed "order-placed" correlation "=orderId"@
    DMessage Name Text (Maybe Text) Span
  | -- | @signal fraud "fraud-detected"@
    DSignal Name Text Span
  | -- | @error payment_failed "PAYMENT_FAILED" "Payment failed"@
    DError Name Text (Maybe Text) Span
  | -- | @escalation overdue "OVERDUE" "Overdue"@
    DEscalation Name Text (Maybe Text) Span
  | DComment Comment
  deriving (Eq, Show)

declSpan :: SDecl -> Span
declSpan d = case d of
  DProcess p -> spSpan p
  DCollaboration c -> scSpan c
  DMessage _ _ _ s -> s
  DSignal _ _ s -> s
  DError _ _ _ s -> s
  DEscalation _ _ _ s -> s
  DComment c -> cmSpan c

data SProcess = SProcess
  { spName  :: Name
  , spLabel :: Maybe Text
  , spBody  :: [SItem]
  , spSpan  :: Span
  }
  deriving (Eq, Show)

-- | A collaboration: several pools and the message flows between them.
data SCollab = SCollab
  { scName  :: Name
  , scLabel :: Maybe Text
  , scItems :: [SCItem]
  , scSpan  :: Span
  }
  deriving (Eq, Show)

data SCItem
  = CPool SPool
  | CMessageFlow SMsgFlow
  | CComment Comment
  deriving (Eq, Show)

-- | A pool. A pool with no body is a black box (LANE-014).
data SPool = SPool
  { poName  :: Name
  , poLabel :: Maybe Text
  , poBody  :: Maybe [SItem]
  , poSpan  :: Span
  }
  deriving (Eq, Show)

-- | @order_placed ~> receive_order "order"@. The @~>@ arrow is reserved for
-- message flows so that a reader never has to work out which kind of
-- connection a line describes.
data SMsgFlow = SMsgFlow
  { mfFrom     :: Name
  , mfTo       :: Name
  , mfLabelS   :: Maybe Text
  , mfSpanS    :: Span
  }
  deriving (Eq, Show)

-- Items ---------------------------------------------------------------------

-- | One line (or block) in a process body. 'IStep' items chain implicitly:
-- consecutive steps are joined by a sequence flow, which is what removes the
-- edge-list boilerplate. Everything else is a side declaration attached to
-- steps by name.
data SItem
  = IDoc Text Span
  | IStep SStep
  | IFlow SFlow
  | IBoundary SBoundary
  | IHandler SHandler
  | IGroup SGroup
  | INote SNote
  | IData SData
  | ILane SLane
  | IPin SPin
  | IComment Comment
  deriving (Eq, Show)

itemSpan :: SItem -> Span
itemSpan i = case i of
  IDoc _ s -> s
  IStep st -> stepSpan st
  IFlow f -> sfSpan f
  IBoundary b -> bdSpan b
  IHandler h -> shSpan h
  IGroup g -> sgrSpan g
  INote n -> snoSpan n
  IData d -> sdSpan d
  ILane l -> slSpan l
  IPin p -> spinSpan p
  IComment c -> cmSpan c

data SStep
  = StNode SNode
  | StGateway SGateway
  | StSubprocess SSub
  | -- | @goto validate@ — continue this path at an existing step and stop.
    -- The only way to write a loop or a cross-link, and it is one word.
    StGoto Name Span
  | -- | @stop@ — this path ends here, and not at an end event.
    --
    -- It is not a step and it becomes no BPMN element. It exists because
    -- consecutive steps chain implicitly: without a word for "nothing follows
    -- this", a scope could hold only one path that stops short of an end
    -- event, since every other one would be joined to whatever came next.
    StStop Span
  deriving (Eq, Show)

stepSpan :: SStep -> Span
stepSpan st = case st of
  StNode n -> snSpan n
  StGateway g -> sgSpan g
  StSubprocess s -> ssSpan s
  StGoto _ s -> s
  StStop s -> s

data SNode = SNode
  { snKind  :: Located NodeKw
  , snName  :: Name
  , snLabel :: Maybe Text
  , snProps :: [SProp]
  , snSpan  :: Span
  }
  deriving (Eq, Show)

-- | A gateway and its branches. The merge is not written: it is derived from
-- how many branches reach the end of the block.
data SGateway = SGateway
  { sgKind     :: Located GwKw
  , sgName     :: Name
  , sgLabel    :: Maybe Text
  , sgJoin     :: Maybe Name
  -- ^ An explicit name for the derived merge gateway, for when something else
  -- has to refer to it (a @goto@, say).
  , sgBranches :: [SBranchItem]
  , sgSpan     :: Span
  }
  deriving (Eq, Show)

-- | A gateway block holds branches and, between them, comments.
data SBranchItem
  = BBranch SBranch
  | BComment Comment
  deriving (Eq, Show)

-- | The branches of a gateway, comments dropped. Everything downstream of the
-- parser except the formatter wants this.
branchesOf :: SGateway -> [SBranch]
branchesOf g = [b | BBranch b <- sgBranches g]

data SBranch = SBranch
  { brLabel    :: Maybe Text
  , brGuard    :: Maybe (Located SGuard)
  , brPriority :: Maybe Int
  -- ^ BRANCH-007 key component 1: an explicit ordering the author wants.
  , brBody     :: Maybe [SItem]
  -- ^ 'Nothing' is an empty branch that runs straight to the merge.
  , brSpan     :: Span
  }
  deriving (Eq, Show)

data SGuard
  = GWhen Text
  | GOtherwise
  deriving (Eq, Show)

data SSub = SSub
  { ssName  :: Name
  , ssLabel :: Maybe Text
  , ssBody  :: [SItem]
  , ssSpan  :: Span
  }
  deriving (Eq, Show)

-- | The escape hatch: an explicit sequence flow between named steps, for
-- graphs the structured constructs cannot express.
-- | An event subprocess: @handler recover "Recover" { start caught { error e } … }@.
--
-- It holds a body like a subprocess and is reached like a boundary event — by
-- its trigger, never by a sequence flow — so it is an item rather than a step:
-- putting it between two steps must not connect it to either.
--
-- The trigger is not written on the header. It belongs to the start event
-- inside, which already has syntax for every trigger BPMN allows, and writing
-- it twice would let the two disagree.
data SHandler = SHandler
  { shName  :: Name
  , shLabel :: Maybe Text
  , shBody  :: [SItem]
  , shSpan  :: Span
  }
  deriving (Eq, Show)

-- | A BPMN group: @group money "Payment steps" { charge refund }@.
--
-- Membership is listed because the source has no geometry to read it from. In
-- a @.bpmn@ a group is a rectangle and its members are whatever it encloses,
-- which is exactly the coupling of meaning to coordinates this language exists
-- to undo; here the members are the declaration and ART-005 derives the
-- rectangle from them.
data SGroup = SGroup
  { sgrName    :: Name
  , sgrLabel   :: Maybe Text
  , sgrMembers :: [SGroupItem]
  , sgrSpan    :: Span
  }
  deriving (Eq, Show)

-- | A group block holds member names and, between them, comments.
data SGroupItem
  = GMember Name
  | GComment Comment
  deriving (Eq, Show)

-- | The members of a group, comments dropped.
membersOf :: SGroup -> [Name]
membersOf g = [n | GMember n <- sgrMembers g]

data SFlow = SFlow
  { sfNodes :: [Name]
  , sfLabelF :: Maybe Text
  , sfGuard :: Maybe (Located SGuard)
  , sfSpan  :: Span
  }
  deriving (Eq, Show)

-- | @on charge catch error "PAYMENT_FAILED" as failed "Payment failed" { … }@
data SBoundary = SBoundary
  { bdHost    :: Name
  , bdTrigger :: Located STrigger
  , bdNonInt  :: Bool
  , bdAs      :: Name
  , bdLabel   :: Maybe Text
  , bdBody    :: [SItem]
  , bdSpan    :: Span
  }
  deriving (Eq, Show)

data SNote = SNote
  { snoName :: Name
  , snoText :: Text
  , snoOn   :: Name
  , snoSpan :: Span
  }
  deriving (Eq, Show)

data SData = SData
  { sdName  :: Name
  , sdLabel :: Maybe Text
  , sdDir   :: DataDir
  , sdOn    :: Name
  , sdSpan  :: Span
  }
  deriving (Eq, Show)

-- | @data receipt "Receipt" from charge@ is produced by the step;
-- @… to charge@ is consumed by it.
data DataDir = DataFrom | DataTo
  deriving (Eq, Show)

data SLane = SLane
  { slName  :: Name
  , slLabel :: Maybe Text
  , slBody  :: [SItem]
  , slSpan  :: Span
  }
  deriving (Eq, Show)

-- | The one place a coordinate may appear in source: an explicit layout pin
-- (LAYOUT-025). Ordinary process syntax never mentions pixels.
data SPin = SPin
  { spinNode :: Name
  , spinX    :: Int
  , spinY    :: Int
  , spinSpan :: Span
  }
  deriving (Eq, Show)

-- Vocabulary ----------------------------------------------------------------

data NodeKw
  = KwStart
  | KwEnd
  | KwTask
  | KwService
  | KwUser
  | KwManual
  | KwScript
  | KwBusiness
  | KwSend
  | KwReceive
  | KwCall
  | KwWait
  | KwThrow
  deriving (Eq, Ord, Show, Enum, Bounded)

nodeKeyword :: NodeKw -> Text
nodeKeyword k = case k of
  KwStart -> "start"
  KwEnd -> "end"
  KwTask -> "task"
  KwService -> "service"
  KwUser -> "user"
  KwManual -> "manual"
  KwScript -> "script"
  KwBusiness -> "business"
  KwSend -> "send"
  KwReceive -> "receive"
  KwCall -> "call"
  KwWait -> "wait"
  KwThrow -> "throw"

allNodeKeywords :: [NodeKw]
allNodeKeywords = [minBound .. maxBound]

data GwKw
  = KwXor
  | KwAnd
  | KwOr
  | KwEventGw
  | KwComplex
  deriving (Eq, Ord, Show, Enum, Bounded)

gatewayKeyword :: GwKw -> Text
gatewayKeyword k = case k of
  KwXor -> "xor"
  KwAnd -> "and"
  KwOr -> "or"
  KwEventGw -> "event"
  KwComplex -> "complex"

allGatewayKeywords :: [GwKw]
allGatewayKeywords = [minBound .. maxBound]

-- | A boundary or event trigger. Every payload except 'TgTimer' is the
-- /symbolic name/ of a top-level declaration, not a wire name: identity is
-- declared once and referred to, so renaming the wire name of a message does
-- not touch the events that wait for it.
data STrigger
  = TgMessage Text
  | TgTimer Text
  | TgSignal Text
  | TgError Text
  | TgEscalation Text
  deriving (Eq, Show)

triggerKeyword :: STrigger -> Text
triggerKeyword t = case t of
  TgMessage _ -> "message"
  TgTimer _ -> "timer"
  TgSignal _ -> "signal"
  TgError _ -> "error"
  TgEscalation _ -> "escalation"

data SProp = SProp
  { prSpan :: Span
  , prBody :: SPropBody
  }
  deriving (Eq, Show)

data SPropBody
  = PType Text
  | PRetries Int
  | PInput Text Text
  | POutput Text Text
  | PHeader Text Text
  | PForm Text
  | PAssignee Text
  | PGroups Text
  | PUsers Text
  | PDue Text
  | PExpression Text
  | PResult Text
  | PDecision Text
  | PCalls Text
  | PPropagate
  | -- | @noninterrupting@ on the start event of a @handler@: catching the
    -- trigger leaves the enclosing scope running.
    PNonInterrupting
  | -- | @each item in "=order.items"@, with 'True' for the @sequential@ form.
    PEach Text Text Bool
  | -- | @collect results from "=score"@
    PCollect Text Text
  | PMessage Text
  | PTimer Text
  | PSignal Text
  | PError Text
  | PEscalation Text
  | PLink Text
  | PTerminate
  | PCompensation
  | PDoc Text
  | PComment Comment
  deriving (Eq, Show)

-- | The keyword a property is written with, used by both the "is this property
-- legal here" check and the formatter.
propKeyword :: SPropBody -> Text
propKeyword b = case b of
  PType {} -> "type"
  PRetries {} -> "retries"
  PInput {} -> "input"
  POutput {} -> "output"
  PHeader {} -> "header"
  PForm {} -> "form"
  PAssignee {} -> "assignee"
  PGroups {} -> "groups"
  PUsers {} -> "users"
  PDue {} -> "due"
  PExpression {} -> "expression"
  PResult {} -> "result"
  PDecision {} -> "decision"
  PCalls {} -> "calls"
  PPropagate -> "propagate"
  PNonInterrupting -> "noninterrupting"
  PEach {} -> "each"
  PCollect {} -> "collect"
  PMessage {} -> "message"
  PTimer {} -> "timer"
  PSignal {} -> "signal"
  PError {} -> "error"
  PEscalation {} -> "escalation"
  PLink {} -> "link"
  PTerminate -> "terminate"
  PCompensation -> "compensation"
  PDoc {} -> "doc"
  PComment {} -> "#"
