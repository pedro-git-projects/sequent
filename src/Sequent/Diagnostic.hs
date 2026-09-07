-- | Source positions and compiler diagnostics.
--
-- Spans live here rather than in the surface AST so that everything from the
-- lexer to the layout engine can report against the same coordinates without
-- depending on the syntax tree.
--
-- Every diagnostic carries a 'DiagCategory', so a caller can tell a user
-- mistake from a layout advisory from a compiler bug without string matching,
-- and an optional 'RuleId' so a layout violation names the SPEC rule it
-- breaks. Ordinary user mistakes are values, never exceptions.
module Sequent.Diagnostic
  ( -- * Positions
    Pos (..)
  , Span (..)
  , spanning
  , noSpan
    -- * Diagnostics
  , Severity (..)
  , DiagCategory (..)
  , RuleId (..)
  , Diagnostic (..)
  , diagnostic
  , errorAt
  , warnAt
  , advisoryAt
  , layoutViolation
  , layoutAdvisory
  , withHint
  , internalError
    -- * Collections
  , hasErrors
  , errorsOf
  , sortDiagnostics
  , categoryLabel
    -- * Rendering
  , renderDiagnostic
  , renderDiagnostics
  ) where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T

-- | A one-based line and column.
data Pos = Pos
  { posLine :: !Int
  , posCol  :: !Int
  }
  deriving (Eq, Ord, Show)

-- | A half-open source range; 'spanEnd' is just past the last character.
data Span = Span
  { spanStart :: !Pos
  , spanEnd   :: !Pos
  }
  deriving (Eq, Ord, Show)

-- | The span used for facts about a whole file rather than a construct in it.
noSpan :: Span
noSpan = Span (Pos 0 0) (Pos 0 0)

-- | The smallest span covering both.
spanning :: Span -> Span -> Span
spanning a b = Span (min (spanStart a) (spanStart b)) (max (spanEnd a) (spanEnd b))

-- | Errors stop compilation. Warnings and advisories never do; the difference
-- is that a warning describes something likely wrong with the input while an
-- advisory describes something the compiler chose to do about it.
data Severity = Error | Warning | Advisory
  deriving (Eq, Ord, Show)

-- | Which stage of the pipeline produced the diagnostic. Callers switch on
-- this rather than parsing message text.
data DiagCategory
  = ParseError
  | NameResolutionError
  | SemanticError
  | CamundaValidationError
  | LayoutViolation
  | LayoutAdvisoryC
  | InternalCompilerError
  deriving (Eq, Ord, Show)

categoryLabel :: DiagCategory -> Text
categoryLabel c = case c of
  ParseError -> "parse"
  NameResolutionError -> "name"
  SemanticError -> "semantic"
  CamundaValidationError -> "camunda"
  LayoutViolation -> "layout"
  LayoutAdvisoryC -> "layout"
  InternalCompilerError -> "internal"

-- | A normative rule identifier from SPEC.md — @HC-004@, @LAYOUT-007@,
-- @EDGE-013@, @BRANCH-014@, @AP-016@ and friends.
newtype RuleId = RuleId {unRuleId :: Text}
  deriving (Eq, Ord, Show)

data Diagnostic = Diagnostic
  { diagSeverity :: !Severity
  , diagCategory :: !DiagCategory
  , diagRule     :: Maybe RuleId
  , diagMessage  :: Text
  , diagSpan     :: Maybe Span
  , diagHint     :: Maybe Text
  }
  deriving (Eq, Show)

diagnostic :: Severity -> DiagCategory -> Text -> Diagnostic
diagnostic sev cat msg = Diagnostic sev cat Nothing msg Nothing Nothing

errorAt :: DiagCategory -> Span -> Text -> Diagnostic
errorAt cat sp msg = (diagnostic Error cat msg) {diagSpan = Just sp}

warnAt :: DiagCategory -> Span -> Text -> Diagnostic
warnAt cat sp msg = (diagnostic Warning cat msg) {diagSpan = Just sp}

advisoryAt :: DiagCategory -> Span -> Text -> Diagnostic
advisoryAt cat sp msg = (diagnostic Advisory cat msg) {diagSpan = Just sp}

-- | A hard-constraint or tier-0/1 breach, named by its SPEC rule. These fail
-- the build (SPEC §K "absolute quality gates").
layoutViolation :: RuleId -> Text -> Diagnostic
layoutViolation r msg = (diagnostic Error LayoutViolation msg) {diagRule = Just r}

-- | A layout observation that does not invalidate the diagram.
layoutAdvisory :: RuleId -> Text -> Diagnostic
layoutAdvisory r msg = (diagnostic Advisory LayoutAdvisoryC msg) {diagRule = Just r}

withHint :: Text -> Diagnostic -> Diagnostic
withHint h d = d {diagHint = Just h}

-- | Reserved for "this cannot happen": an invariant the compiler itself broke.
internalError :: Text -> Diagnostic
internalError msg =
  withHint "this is a compiler bug; please report it" (diagnostic Error InternalCompilerError msg)

hasErrors :: [Diagnostic] -> Bool
hasErrors = any ((== Error) . diagSeverity)

errorsOf :: [Diagnostic] -> [Diagnostic]
errorsOf = filter ((== Error) . diagSeverity)

-- | Total, deterministic diagnostic order: severity, then source position,
-- then category, then rule, then message. Two runs over equivalent input emit
-- the same list in the same order (LAYOUT-027).
sortDiagnostics :: [Diagnostic] -> [Diagnostic]
sortDiagnostics = sortOn key
  where
    key d =
      ( diagSeverity d
      , maybe (Pos maxBound maxBound) spanStart (diagSpan d)
      , diagCategory d
      , fmap unRuleId (diagRule d)
      , diagMessage d
      )

renderDiagnostics :: FilePath -> Text -> [Diagnostic] -> Text
renderDiagnostics path src ds =
  T.concat (map (renderDiagnostic path src) (sortDiagnostics ds))

-- | One diagnostic with a caret underline:
--
-- > error[semantic]: undefined step 'reveiw'
-- >   --> onboarding.sq:12:16
-- >    |
-- > 12 |   flow submitted -> reveiw
-- >    |                     ^^^^^^
renderDiagnostic :: FilePath -> Text -> Diagnostic -> Text
renderDiagnostic path src d =
  T.concat (header : maybe [] snippet (usableSpan (diagSpan d)) ++ hint)
  where
    header =
      severityLabel (diagSeverity d)
        <> "["
        <> categoryLabel (diagCategory d)
        <> maybe "" (\r -> "/" <> unRuleId r) (diagRule d)
        <> "]: "
        <> diagMessage d
        <> "\n"
    hint = ["  = help: " <> h <> "\n" | Just h <- [diagHint d]]

    usableSpan (Just sp) | posLine (spanStart sp) > 0 = Just sp
    usableSpan _ = Nothing

    srcLines = T.lines src
    snippet sp =
      let l = posLine (spanStart sp)
          c = posCol (spanStart sp)
          gutter = T.pack (show l)
          pad = T.replicate (T.length gutter) " "
          lineText = if l >= 1 && l <= length srcLines then srcLines !! (l - 1) else ""
          width
            | posLine (spanEnd sp) /= l = max 1 (T.length lineText - c + 1)
            | otherwise = max 1 (posCol (spanEnd sp) - c)
       in [ "  --> " <> T.pack path <> ":" <> gutter <> ":" <> T.pack (show c) <> "\n"
          , pad <> " |\n"
          , gutter <> " | " <> lineText <> "\n"
          , pad <> " | " <> T.replicate (c - 1) " " <> T.replicate width "^" <> "\n"
          ]

severityLabel :: Severity -> Text
severityLabel s = case s of
  Error -> "error"
  Warning -> "warning"
  Advisory -> "advisory"
