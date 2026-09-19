-- | The grammar for @.sq@ source.
--
-- Whitespace-insensitive with @{}@ blocks: no indentation rules, which keeps
-- both the grammar and the error messages simple, and keeps a merge that
-- shifts indentation from changing meaning.
--
-- Two properties matter more than elegance here:
--
--   * __Spans on everything.__ Every name, keyword, property and block records
--     the characters it came from, so later phases can point a caret at the
--     construct rather than at a line.
--   * __Reserved words are rejected as identifiers.__ A step named @flow@ or
--     @branch@ would make the grammar ambiguous in a way that shows up as a
--     baffling error three lines later; rejecting it at the name gives an
--     error at the name.
module Sequent.Language.Parser
  ( parseFile
  , reservedWords
  ) where

import Control.Monad (void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (State, evalState, modify', state)
import Data.Char (isAlpha, isAlphaNum, isSpace)
import qualified Data.List.NonEmpty as NE
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Text.Megaparsec hiding (Pos, State)
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L

import Sequent.Diagnostic
import Sequent.Language.Syntax

-- | The parser carries the comments the lexer has seen since they were last
-- collected, newest first.
--
-- A comment can appear anywhere whitespace can, so it cannot be a grammar
-- production without the grammar acquiring a comment case at every one of those
-- positions. Recording them as the space consumer passes over them, and
-- draining the record at the few places a list of elements is built, keeps the
-- grammar the shape it was and still puts every comment back in order.
type P = ParsecT Void Text (State [Comment])

-- | Parse a whole file. On failure every megaparsec error becomes a
-- 'Diagnostic' pointing at its own offset.
parseFile :: FilePath -> Text -> Either [Diagnostic] SFile
parseFile path src =
  case evalState (runParserT file path src) [] of
    Right f -> Right f
    Left b -> Left (bundleDiagnostics b)
  where
    -- The leading space consumer starts on a fresh line, so a comment at the
    -- very top of the file is a heading rather than a trailing note.
    file = byteOrderMark *> scFrom True *> (SFile <$> withComments DComment decl) <* eof

-- | Skip a byte order mark at the very start of the file.
--
-- A BOM is an encoding artefact, not a character of the program: a file that
-- went through a Windows editor, a PowerShell redirection, or any tool that
-- writes "UTF-8 with signature" arrives with U+FEFF in front of the first
-- declaration. It is invisible in every editor that produced it, so a parse
-- error pointing at it reads as a parse error pointing at nothing. It is
-- consumed rather than stripped from the input so that every span after it
-- still counts the characters the file actually contains.
byteOrderMark :: P ()
byteOrderMark = void (optional (single '\65279'))

bundleDiagnostics :: ParseErrorBundle Text Void -> [Diagnostic]
bundleDiagnostics b = map toDiag (NE.toList attached)
  where
    (attached, _) = attachSourcePos errorOffset (bundleErrors b) (bundlePosState b)
    toDiag (e, p) =
      Diagnostic
        { diagSeverity = Error
        , diagCategory = ParseError
        , diagRule = Nothing
        , diagMessage = T.intercalate "; " (T.lines (T.strip (T.pack (parseErrorTextPretty e))))
        , diagSpan = Just (Span (sp p) (sp p) {posCol = posCol (sp p) + 1})
        , diagHint = Nothing
        }
    sp p = Pos (unPos (sourceLine p)) (unPos (sourceColumn p))

-- Lexing --------------------------------------------------------------------

-- | Skip whitespace and comments, recording each comment as it goes.
sc :: P ()
sc = scFrom False

-- | 'sc', told whether the position it starts at is already at the start of a
-- line. That is the whole of the leading\/trailing distinction: a comment is
-- trailing exactly when no newline separates it from the token before it.
scFrom :: Bool -> P ()
scFrom = loop
  where
    loop atLineStart = do
      w <- takeWhileP Nothing isSpace
      let atStart = atLineStart || T.any (== '\n') w
      r <- optional (spanned commentToken)
      case r of
        Nothing -> pure ()
        Just ((txt, endsLine), sp) -> do
          record (Comment txt (not atStart) sp)
          loop (atStart && T.null w || endsLine)

-- | One comment, with whether it runs to the end of its line.
commentToken :: P (Text, Bool)
commentToken =
  choice
    [ (,True) <$> lineCommentText "#"
    , (,True) <$> lineCommentText "//"
    , (,False) <$> blockCommentText
    ]
  where
    lineCommentText marker = do
      m <- string marker
      rest <- takeWhileP Nothing (/= '\n')
      pure (T.stripEnd (m <> rest))
    blockCommentText = do
      o <- string "/*"
      body <- manyTill anySingle (string "*/")
      pure (o <> T.pack body <> "*/")

record :: Comment -> P ()
record c = lift (modify' (c :))

-- | Take everything the lexer has recorded since the last drain, in source
-- order.
drainComments :: P [Comment]
drainComments = lift (state (\cs -> (reverse cs, [])))

-- | Parse @many p@, weaving the comments the lexer passed over back into the
-- list at the positions they were written.
--
-- Every lexeme skips trailing whitespace, so by the time one element has been
-- parsed the lexer has already crossed the comments that follow it. Draining
-- straight after each element therefore captures exactly the comments between
-- it and the next one, and a leading drain catches the comments before the
-- first element — including all of them when the list turns out to be empty.
withComments :: (Comment -> a) -> P a -> P [a]
withComments wrap p = do
  lead <- drainComments
  rest <- many ((:) <$> p <*> fmap (map wrap) drainComments)
  pure (map wrap lead ++ concat rest)

lexeme :: P a -> P a
lexeme = L.lexeme sc

symbol :: Text -> P Text
symbol = L.symbol sc

-- | A lexeme that remembers the span of its own characters, trailing
-- whitespace excluded.
located :: P a -> P (Located a)
located p = do
  s <- position
  a <- p
  e <- position
  sc
  pure (Located (Span s e) a)

-- | Run a parser and pair its result with the span it consumed.
spanned :: P a -> P (a, Span)
spanned p = do
  s <- position
  a <- p
  e <- position
  pure (a, Span s (clampTo s e))
  where
    -- A construct that ran onto later lines would underline the rest of the
    -- file; point at its first line instead.
    clampTo s e = if posLine e == posLine s then e else s {posCol = posCol s + 1}

position :: P Pos
position = do
  p <- getSourcePos
  pure (Pos (unPos (sourceLine p)) (unPos (sourceColumn p)))

-- | A keyword: matched only when not followed by more identifier characters.
kw :: Text -> P ()
kw w = void (lexeme (try (string w <* notFollowedBy (satisfy identChar))))

identChar :: Char -> Bool
identChar c = isAlphaNum c || c == '_'

-- | Every word the grammar gives meaning to. Reserving them all — including
-- property keywords that are only meaningful inside a node block — costs a
-- handful of unusable step names and buys unambiguous parsing and errors that
-- land on the offending word.
reservedWords :: Set Text
reservedWords =
  Set.fromList $
    [ "process", "collaboration", "pool", "message", "signal", "error"
    , "correlation", "doc", "lane", "on", "catch", "noninterrupting", "as"
    , "note", "data", "from", "to", "pin", "at", "flow", "goto", "join"
    , "branch", "priority", "when", "otherwise", "subprocess", "escalation"
    , "handler", "group", "stop", "nonexecutable"
    , "type", "retries", "input", "output", "header", "form", "assignee"
    , "groups", "users", "due", "expression", "result", "decision", "calls"
    , "propagate", "each", "in", "collect", "timer", "link", "terminate"
    , "compensation", "sequential"
    ]
      ++ map nodeKeyword allNodeKeywords
      ++ map gatewayKeyword allGatewayKeywords

rawIdent :: P Text
rawIdent = T.cons <$> satisfy startChar <*> takeWhileP Nothing identChar
  where
    startChar c = isAlpha c || c == '_'

-- | A user-chosen symbolic name.
ident :: P Name
ident =
  ( try $ do
      o <- getOffset
      n <- located rawIdent
      when (Set.member (unLoc n) reservedWords) $
        -- Report at the offending word, not at whatever the enclosing
        -- alternative was looking at when it gave up.
        region
          (setErrorOffset o)
          (fail ("'" <> T.unpack (unLoc n) <> "' is a reserved word and cannot name a step"))
      pure n
  )
    <?> "name"

stringLit :: P Text
stringLit = lexeme (char '"' *> (T.pack <$> manyTill charLit (char '"'))) <?> "string"
  where
    charLit = (char '\\' *> escape) <|> satisfy (\c -> c /= '"' && c /= '\\')
    escape =
      choice
        [ '"' <$ char '"'
        , '\\' <$ char '\\'
        , '\n' <$ char 'n'
        , '\t' <$ char 't'
        , '\r' <$ char 'r'
        ]

-- | Places where either form reads naturally: variable and header names often
-- want characters an identifier cannot hold.
identOrString :: P Text
identOrString = stringLit <|> lexeme rawIdent

integer :: P Int
integer = lexeme L.decimal

-- | A reference to a top-level declaration, written as a bare name.
declRef :: P Text
declRef = unLoc <$> ident

braces :: P a -> P a
braces = between (symbol "{") (symbol "}")

-- Declarations --------------------------------------------------------------

decl :: P SDecl
decl =
  choice
    [ DProcess <$> processDecl
    , DCollaboration <$> collabDecl
    , messageDecl
    , signalDecl
    , errorDecl
    , escalationDecl
    ]
    <?> "declaration"

processDecl :: P SProcess
processDecl = do
  ((n, lbl, exec, items), s) <- spanned $ do
    kw "process"
    n <- ident
    lbl <- optional stringLit
    exec <- executable
    items <- braces (withComments IComment item)
    pure (n, lbl, exec, items)
  pure (SProcess n lbl exec items s)

-- | The @nonexecutable@ modifier, which BPMN spells @isExecutable="false"@.
executable :: P Bool
executable = maybe True (const False) <$> optional (kw "nonexecutable")

collabDecl :: P SCollab
collabDecl = do
  ((n, lbl, items), s) <- spanned $ do
    kw "collaboration"
    n <- ident
    lbl <- optional stringLit
    items <- braces (withComments CComment collabItem)
    pure (n, lbl, items)
  pure (SCollab n lbl items s)

collabItem :: P SCItem
collabItem = choice [CPool <$> poolDecl, CMessageFlow <$> msgFlow] <?> "pool or message flow"

poolDecl :: P SPool
poolDecl = do
  ((n, lbl, pn, exec, body), s) <- spanned $ do
    kw "pool"
    n <- ident
    lbl <- optional stringLit
    -- @process "…"@ names the process the pool holds, for the files where the
    -- participant and the process do not share a name.
    pn <- optional (kw "process" *> stringLit)
    exec <- executable
    body <- optional (braces (withComments IComment item))
    pure (n, lbl, pn, exec, body)
  pure (SPool n lbl pn exec body s)

msgFlow :: P SMsgFlow
msgFlow = do
  ((a, b, lbl), s) <- spanned $ do
    a <- try (ident <* symbol "~>")
    b <- ident
    lbl <- optional stringLit
    pure (a, b, lbl)
  pure (SMsgFlow a b lbl s)

messageDecl :: P SDecl
messageDecl = do
  ((n, nm, corr), s) <- spanned $ do
    kw "message"
    n <- ident
    nm <- stringLit
    corr <- optional (kw "correlation" *> stringLit)
    pure (n, nm, corr)
  pure (DMessage n nm corr s)

signalDecl :: P SDecl
signalDecl = do
  ((n, nm), s) <- spanned (kw "signal" *> ((,) <$> ident <*> stringLit))
  pure (DSignal n nm s)

errorDecl :: P SDecl
errorDecl = do
  ((n, code, lbl), s) <- spanned $ do
    kw "error"
    n <- ident
    code <- stringLit
    lbl <- optional stringLit
    pure (n, code, lbl)
  pure (DError n code lbl s)

escalationDecl :: P SDecl
escalationDecl = do
  ((n, code, lbl), s) <- spanned $ do
    kw "escalation"
    n <- ident
    code <- stringLit
    lbl <- optional stringLit
    pure (n, code, lbl)
  pure (DEscalation n code lbl s)

-- Process items -------------------------------------------------------------

item :: P SItem
item =
  choice
    [ docItem
    , laneItem
    , boundaryItem
    , handlerItem
    , groupItem
    , noteItem
    , dataItem
    , pinItem
    , flowItem
    , gotoItem
    , stopItem
    , IStep . StGateway <$> gatewayDecl
    , IStep . StSubprocess <$> subprocessDecl
    , IStep . StNode <$> nodeDecl
    ]
    <?> "step or declaration"

docItem :: P SItem
docItem = uncurry IDoc <$> spanned (kw "doc" *> stringLit)

laneItem :: P SItem
laneItem = do
  ((n, lbl, body), s) <- spanned $ do
    kw "lane"
    n <- ident
    lbl <- optional stringLit
    body <- braces (withComments IComment item)
    pure (n, lbl, body)
  pure (ILane (SLane n lbl body s))

boundaryItem :: P SItem
boundaryItem = do
  ((h, tg, ni, nm, lbl, body), s) <- spanned $ do
    kw "on"
    h <- ident
    kw "catch"
    tg <- located triggerWord
    ni <- option False (True <$ kw "noninterrupting")
    kw "as"
    nm <- ident
    lbl <- optional stringLit
    body <- braces (withComments IComment item)
    pure (h, tg, ni, nm, lbl, body)
  pure (IBoundary (SBoundary h tg ni nm lbl body s))

-- | @handler recover "Recover" { … }@ — an event subprocess. The trigger is
-- the start event's, inside the block; nothing on the header line repeats it.
handlerItem :: P SItem
handlerItem = do
  ((n, lbl, body), s) <- spanned $ do
    kw "handler"
    n <- ident
    lbl <- optional stringLit
    body <- braces (withComments IComment item)
    pure (n, lbl, body)
  pure (IHandler (SHandler n lbl body s))

-- | @group money "Payment steps" { charge refund }@ — a list of member names,
-- not a list of items: a group does not contain its members, it draws a
-- rectangle round them (ART-005).
groupItem :: P SItem
groupItem = do
  ((n, lbl, ms), s) <- spanned $ do
    kw "group"
    n <- ident
    lbl <- optional stringLit
    ms <- braces (withComments GComment (GMember <$> ident))
    pure (n, lbl, ms)
  pure (IGroup (SGroup n lbl ms s))

noteItem :: P SItem
noteItem = do
  ((n, txt, host), s) <- spanned $ do
    kw "note"
    n <- ident
    txt <- stringLit
    kw "on"
    host <- ident
    pure (n, txt, host)
  pure (INote (SNote n txt host s))

dataItem :: P SItem
dataItem = do
  ((n, lbl, dir, host), s) <- spanned $ do
    kw "data"
    n <- ident
    lbl <- optional stringLit
    dir <- (DataFrom <$ kw "from") <|> (DataTo <$ kw "to")
    host <- ident
    pure (n, lbl, dir, host)
  pure (IData (SData n lbl dir host s))

pinItem :: P SItem
pinItem = do
  ((n, x, y), s) <- spanned $ do
    kw "pin"
    n <- ident
    kw "at"
    x <- integer
    y <- integer
    pure (n, x, y)
  pure (IPin (SPin n x y s))

flowItem :: P SItem
flowItem = do
  ((ns, lbl, g), s) <- spanned $ do
    kw "flow"
    first <- ident
    rest <- some (symbol "->" *> ident)
    lbl <- optional stringLit
    g <- optional (located guardWord)
    pure (first : rest, lbl, g)
  pure (IFlow (SFlow ns lbl g s))

gotoItem :: P SItem
gotoItem = do
  (n, s) <- spanned (kw "goto" *> ident)
  pure (IStep (StGoto n s))

stopItem :: P SItem
stopItem = do
  (_, s) <- spanned (kw "stop")
  pure (IStep (StStop s))

guardWord :: P SGuard
guardWord = (GWhen <$> (kw "when" *> stringLit)) <|> (GOtherwise <$ kw "otherwise")

nodeDecl :: P SNode
nodeDecl = do
  ((k, n, lbl, ps), s) <- spanned $ do
    k <- located kindWord
    n <- ident
    lbl <- optional stringLit
    ps <- option [] (braces (withComments propComment prop))
    pure (k, n, lbl, ps)
  pure (SNode k n lbl ps s)

kindWord :: P NodeKw
kindWord =
  choice
    [k <$ try (string (nodeKeyword k) <* notFollowedBy (satisfy identChar)) | k <- allNodeKeywords]
    <?> "step keyword"

gatewayDecl :: P SGateway
gatewayDecl = do
  ((k, n, lbl, j, bs), s) <- spanned $ do
    k <- located gwWord
    n <- ident
    lbl <- optional stringLit
    j <- optional (kw "join" *> ident)
    bs <- braces (withComments BComment (BBranch <$> branchDecl))
    pure (k, n, lbl, j, bs)
  pure (SGateway k n lbl j bs s)

gwWord :: P GwKw
gwWord =
  choice
    [k <$ try (string (gatewayKeyword k) <* notFollowedBy (satisfy identChar)) | k <- allGatewayKeywords]
    <?> "gateway keyword"

branchDecl :: P SBranch
branchDecl = do
  ((lbl, pr, g, body), s) <- spanned $ do
    kw "branch"
    lbl <- optional stringLit
    pr <- optional (kw "priority" *> integer)
    g <- optional (located guardWord)
    body <- optional (braces (withComments IComment item))
    pure (lbl, pr, g, body)
  pure (SBranch lbl g pr body s)

subprocessDecl :: P SSub
subprocessDecl = do
  ((n, lbl, body), s) <- spanned $ do
    kw "subprocess"
    n <- ident
    lbl <- optional stringLit
    body <- braces (withComments IComment item)
    pure (n, lbl, body)
  pure (SSub n lbl body s)

-- | Message, signal, error and escalation triggers name a top-level
-- declaration; only a timer carries a literal, because an ISO-8601 duration
-- has no identity to declare.
triggerWord :: P STrigger
triggerWord =
  choice
    [ TgMessage <$> (kw "message" *> declRef)
    , TgTimer <$> (kw "timer" *> stringLit)
    , TgSignal <$> (kw "signal" *> declRef)
    , TgError <$> (kw "error" *> declRef)
    , TgEscalation <$> (kw "escalation" *> declRef)
    ]
    <?> "trigger"

-- Properties ----------------------------------------------------------------

prop :: P SProp
prop = do
  (b, s) <- spanned propBody
  pure (SProp s b)

-- | A comment inside a property block is a property-shaped hole in the list,
-- so that the formatter can put it back between the properties it sat between.
propComment :: Comment -> SProp
propComment c = SProp (cmSpan c) (PComment c)

propBody :: P SPropBody
propBody =
  choice
    [ PType <$> (kw "type" *> stringLit)
    , PRetries <$> (kw "retries" *> integer)
    , PInput <$> (kw "input" *> identOrString) <*> (symbol "=" *> stringLit)
    , POutput <$> (kw "output" *> identOrString) <*> (symbol "=" *> stringLit)
    , PHeader <$> (kw "header" *> identOrString) <*> (symbol "=" *> stringLit)
    , PForm <$> (kw "form" *> stringLit)
    , PAssignee <$> (kw "assignee" *> stringLit)
    , PGroups <$> (kw "groups" *> stringLit)
    , PUsers <$> (kw "users" *> stringLit)
    , PDue <$> (kw "due" *> stringLit)
    , PExpression <$> (kw "expression" *> stringLit)
    , PResult <$> (kw "result" *> identOrString)
    , PDecision <$> (kw "decision" *> stringLit)
    , PCalls <$> (kw "calls" *> stringLit)
    , PPropagate <$ kw "propagate"
    , PNonInterrupting <$ kw "noninterrupting"
    , eachProp
    , PCollect <$> (kw "collect" *> identOrString) <*> (kw "from" *> stringLit)
    , PMessage <$> (kw "message" *> declRef)
    , PTimer <$> (kw "timer" *> stringLit)
    , PSignal <$> (kw "signal" *> declRef)
    , PError <$> (kw "error" *> declRef)
    , PEscalation <$> (kw "escalation" *> declRef)
    , PLink <$> (kw "link" *> stringLit)
    , PTerminate <$ kw "terminate"
    , PCompensation <$ kw "compensation"
    , PDoc <$> (kw "doc" *> stringLit)
    ]
    <?> "property"

eachProp :: P SPropBody
eachProp = do
  kw "each"
  v <- identOrString
  kw "in"
  coll <- stringLit
  seqd <- option False (True <$ kw "sequential")
  pure (PEach v coll seqd)
