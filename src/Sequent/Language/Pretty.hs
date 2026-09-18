-- | The canonical formatter.
--
-- Guarantees, both of which are tested:
--
--   * @format (format s) == format s@ — formatting is a fixed point;
--   * @parse (format ast) == ast@ modulo source spans, which is what makes it
--     safe to run over a file nobody asked you to restructure.
--
-- Comments are content, so they come through. Each one is printed where it was
-- written: a comment that followed code on its line goes back on that line, and
-- one that stood on its own stays above the construct it introduces — and stays
-- attached to it, so the blank-line rule can never insert a gap between a
-- comment and the thing it documents.
--
-- The formatter never reorders anything. In this language source order /is/ the
-- process order, so reordering would change meaning, and even where it would
-- not, rewriting lines a commit did not touch is the behaviour that makes
-- people turn formatters off.
--
-- Blank lines are inserted by one local rule — a blank line separates two
-- adjacent items when either of them renders as a block — so adding a step
-- perturbs at most the blank lines next to it, and two people adding unrelated
-- steps touch different lines.
module Sequent.Language.Pretty
  ( format
  , formatDecl
  , renderString
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Language.Syntax

format :: SFile -> Text
format (SFile decls) = T.unlines (blankSeparated (groups True (map declPiece decls)))

-- | One element of a body on its way to the page: a comment, or a construct
-- already rendered to lines.
data Piece
  = PComment' Comment
  | PLines [Text]

-- | A rendered element, with the standalone comments that introduce it kept
-- apart from its own lines.
--
-- The split is what stops a comment from changing the blank-line rule around
-- the construct it belongs to: the rule looks at 'grBody' only, so commenting a
-- one-liner leaves it a one-liner.
data Group = Group
  { grLead :: [Text]
  , grBody :: [Text]
  }

renderGroup :: Group -> [Text]
renderGroup g = grLead g ++ grBody g

isEmptyGroup :: Group -> Bool
isEmptyGroup g = null (grLead g) && null (grBody g)

-- | Turn pieces into groups, in two passes.
--
-- The passes are separate because a trailing comment has to reach /backwards/,
-- to the line already written, and a leading one forwards, to the construct not
-- written yet. Trying to do both in one traversal means holding the previous
-- group open while looking at the next piece, which is where an off-by-one that
-- puts every trailing comment on the following construct comes from.
groups :: Bool -> [Piece] -> [Group]
groups standalone = build standalone [] . mergeTrailing

-- | Pass one: a comment written on the same line as the piece before it is
-- folded into that piece's last line and stops being a piece of its own.
mergeTrailing :: [Piece] -> [Piece]
mergeTrailing = go
  where
    go (p : PComment' c : rest)
      | cmTrailing c = go (appendText (trailingText c) p : rest)
    go (p : rest) = p : go rest
    go [] = []

    appendText t (PLines ls) = PLines (onLast (<> "  " <> t) ls)
    appendText t (PComment' c) = PComment' c {cmText = cmText c <> "  " <> t}

    onLast _ [] = []
    onLast f ls = init ls ++ [f (last ls)]

-- | Pass two: a run of comment lines becomes the lead of the group that follows
-- it, so the blank-line rule can never separate a comment from the construct it
-- introduces. At the top level, where declarations always stand apart anyway,
-- the run becomes a group of its own instead — otherwise a file heading would
-- be glued to the first declaration.
--
-- A run with nothing after it is a group of its own either way.
build :: Bool -> [Text] -> [Piece] -> [Group]
build _ lead [] = [Group lead [] | not (null lead)]
build standalone lead (PLines ls : rest) = Group lead ls : build standalone [] rest
build standalone lead (PComment' c : rest) = run (lead ++ commentLines c) rest
  where
    run acc (PComment' c' : more) | not (cmTrailing c') = run (acc ++ commentLines c') more
    run acc more
      | standalone = Group acc [] : build standalone [] more
      | otherwise = build standalone acc more

trailingText :: Comment -> Text
trailingText = T.unwords . commentLines

-- | Join groups with exactly one blank line between them. Used for top-level
-- declarations, which always stand apart.
blankSeparated :: [Group] -> [Text]
blankSeparated gs = case map renderGroup (filter (not . isEmptyGroup) gs) of
  [] -> []
  (x : xs) -> x ++ concatMap ("" :) xs

-- | Join the items of a body, separating two adjacent items by a blank line
-- exactly when either of them renders as a block. The rule is local: inserting
-- an item can only change the blank lines beside it, so unrelated edits do not
-- collide (and neither do two people editing different parts of one process).
joinItems :: [Group] -> [Text]
joinItems gs0 = case filter (not . isEmptyGroup) gs0 of
  [] -> []
  (g : gs) -> renderGroup g ++ go g gs
  where
    go _ [] = []
    go prev (h : rest)
      | isBlock prev || isBlock h = "" : renderGroup h ++ go h rest
      | otherwise = renderGroup h ++ go h rest
    isBlock g = length (grBody g) > 1

declPiece :: SDecl -> Piece
declPiece (DComment c) = PComment' c
declPiece d = PLines (formatDecl d)

formatDecl :: SDecl -> [Text]
formatDecl d = case d of
  DComment c -> commentLines c
  DMessage n nm corr _ ->
    ["message " <> unLoc n <> " " <> str nm <> maybe "" (\c -> " correlation " <> str c) corr]
  DSignal n nm _ -> ["signal " <> unLoc n <> " " <> str nm]
  DError n code lbl _ -> ["error " <> unLoc n <> " " <> str code <> labelOf lbl]
  DEscalation n code lbl _ -> ["escalation " <> unLoc n <> " " <> str code <> labelOf lbl]
  DProcess p ->
    block ("process " <> unLoc (spName p) <> labelOf (spLabel p)) (items (spBody p))
  DCollaboration c ->
    block ("collaboration " <> unLoc (scName c) <> labelOf (scLabel c)) (collabItems (scItems c))

collabItems :: [SCItem] -> [Group]
collabItems = groups False . map one
  where
    one (CComment c) = PComment' c
    one (CPool p) = PLines $ case poBody p of
      Nothing -> [header p]
      Just b -> block (header p) (items b)
    one (CMessageFlow m) =
      PLines [unLoc (mfFrom m) <> " ~> " <> unLoc (mfTo m) <> labelOf (mfLabelS m)]
    header p = "pool " <> unLoc (poName p) <> labelOf (poLabel p)

-- | Render the items of a body, each as its own group of lines. Grouping is
-- what the blank-line rule operates on.
items :: [SItem] -> [Group]
items = groups False . map piece
  where
    piece (IComment c) = PComment' c
    piece i = PLines (item i)

item :: SItem -> [Text]
item i = case i of
  IComment c -> commentLines c
  IDoc t _ -> ["doc " <> str t]
  IStep s -> step s
  IFlow f ->
    [ "flow "
        <> T.intercalate " -> " (map unLoc (sfNodes f))
        <> labelOf (sfLabelF f)
        <> maybe "" (\g -> " " <> guard (unLoc g)) (sfGuard f)
    ]
  IBoundary b ->
    block
      ( "on "
          <> unLoc (bdHost b)
          <> " catch "
          <> trigger (unLoc (bdTrigger b))
          <> (if bdNonInt b then " noninterrupting" else "")
          <> " as "
          <> unLoc (bdAs b)
          <> labelOf (bdLabel b)
      )
      (items (bdBody b))
  IHandler h ->
    block ("handler " <> unLoc (shName h) <> labelOf (shLabel h)) (items (shBody h))
  IGroup g ->
    block ("group " <> unLoc (sgrName g) <> labelOf (sgrLabel g)) (members (sgrMembers g))
  INote n -> ["note " <> unLoc (snoName n) <> " " <> str (snoText n) <> " on " <> unLoc (snoOn n)]
  IData d ->
    [ "data "
        <> unLoc (sdName d)
        <> labelOf (sdLabel d)
        <> (case sdDir d of DataFrom -> " from "; DataTo -> " to ")
        <> unLoc (sdOn d)
    ]
  ILane l -> block ("lane " <> unLoc (slName l) <> labelOf (slLabel l)) (items (slBody l))
  IPin p ->
    [ "pin "
        <> unLoc (spinNode p)
        <> " at "
        <> T.pack (show (spinX p))
        <> " "
        <> T.pack (show (spinY p))
    ]

step :: SStep -> [Text]
step s = case s of
  StGoto n _ -> ["goto " <> unLoc n]
  StStop _ -> ["stop"]
  StNode n
    | null (snProps n) -> [nodeHeader n]
    | otherwise -> block (nodeHeader n) (props (snProps n))
  StSubprocess sub ->
    block ("subprocess " <> unLoc (ssName sub) <> labelOf (ssLabel sub)) (items (ssBody sub))
  StGateway g -> block (gatewayHeader g) (branches (sgBranches g))

-- | A group's members, one per line: a long membership list is the thing a
-- diff is most likely to touch, and one name per line keeps that diff to the
-- line that changed.
members :: [SGroupItem] -> [Group]
members = groups False . map piece
  where
    piece (GComment c) = PComment' c
    piece (GMember n) = PLines [unLoc n]

props :: [SProp] -> [Group]
props = groups False . map piece
  where
    piece (SProp _ (PComment c)) = PComment' c
    piece p = PLines [prop p]

branches :: [SBranchItem] -> [Group]
branches = groups False . map piece
  where
    piece (BComment c) = PComment' c
    piece (BBranch b) = PLines (branch b)

nodeHeader :: SNode -> Text
nodeHeader n =
  nodeKeyword (unLoc (snKind n)) <> " " <> unLoc (snName n) <> labelOf (snLabel n)

gatewayHeader :: SGateway -> Text
gatewayHeader g =
  gatewayKeyword (unLoc (sgKind g))
    <> " "
    <> unLoc (sgName g)
    <> labelOf (sgLabel g)
    <> maybe "" (\j -> " join " <> unLoc j) (sgJoin g)

branch :: SBranch -> [Text]
branch b = case brBody b of
  Nothing -> [header]
  Just body -> block header (items body)
  where
    header =
      "branch"
        <> labelOf (brLabel b)
        <> maybe "" (\p -> " priority " <> T.pack (show p)) (brPriority b)
        <> maybe "" (\g -> " " <> guard (unLoc g)) (brGuard b)

guard :: SGuard -> Text
guard g = case g of
  GWhen e -> "when " <> str e
  GOtherwise -> "otherwise"

trigger :: STrigger -> Text
trigger t = case t of
  TgMessage v -> "message " <> key v
  TgTimer v -> "timer " <> str v
  TgSignal v -> "signal " <> key v
  TgError v -> "error " <> key v
  TgEscalation v -> "escalation " <> key v

prop :: SProp -> Text
prop (SProp _ b) = case b of
  PType v -> "type " <> str v
  PRetries n -> "retries " <> T.pack (show n)
  PInput k v -> "input " <> key k <> " = " <> str v
  POutput k v -> "output " <> key k <> " = " <> str v
  PHeader k v -> "header " <> key k <> " = " <> str v
  PForm v -> "form " <> str v
  PAssignee v -> "assignee " <> str v
  PGroups v -> "groups " <> str v
  PUsers v -> "users " <> str v
  PDue v -> "due " <> str v
  PExpression v -> "expression " <> str v
  PResult v -> "result " <> key v
  PDecision v -> "decision " <> str v
  PCalls v -> "calls " <> str v
  PPropagate -> "propagate"
  PNonInterrupting -> "noninterrupting"
  PEach v coll sq -> "each " <> key v <> " in " <> str coll <> (if sq then " sequential" else "")
  PCollect v src -> "collect " <> key v <> " from " <> str src
  PMessage v -> "message " <> key v
  PTimer v -> "timer " <> str v
  PSignal v -> "signal " <> key v
  PError v -> "error " <> key v
  PEscalation v -> "escalation " <> key v
  PLink v -> "link " <> str v
  PTerminate -> "terminate"
  PCompensation -> "compensation"
  PDoc v -> "doc " <> str v
  PComment c -> T.unwords (commentLines c)

-- | Render a header and an indented body between braces.
block :: Text -> [Group] -> [Text]
block header body = (header <> " {") : map (indent 1) (joinItems body) ++ ["}"]

indent :: Int -> Text -> Text
indent n t
  | T.null t = t
  | otherwise = T.replicate n "  " <> t

labelOf :: Maybe Text -> Text
labelOf = maybe "" (\l -> " " <> str l)

-- | Keys stay bare when they look like identifiers and get quoted when they do
-- not, which is exactly the set the parser accepts bare.
key :: Text -> Text
key t
  | not (T.null t), T.all bare t, not (isDigitStart t) = t
  | otherwise = str t
  where
    bare c = c `elem` (['a' .. 'z'] ++ ['A' .. 'Z'] ++ ['0' .. '9'] ++ "_")
    isDigitStart x = T.head x `elem` ['0' .. '9']

str :: Text -> Text
str t = "\"" <> T.concatMap esc t <> "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\t' = "\\t"
    esc '\r' = "\\r"
    esc c = T.singleton c

renderString :: Text -> Text
renderString = str
