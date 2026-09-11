-- | Shared test helpers.
--
-- Includes a small XML reader. Asserting BPMN structure by string matching is
-- how a serialiser test ends up pinned to whitespace instead of to meaning, so
-- the XML tests parse the generated document back and query the tree. The
-- reader is deliberately minimal — it only has to read documents this compiler
-- wrote — and its narrowness is the point: it cannot accidentally "fix" output
-- that a real BPMN consumer would reject.
module Sequent.Test.Support
  ( -- * Compiling
    compileOk
  , compileXml
  , layoutOf
  , graphOf
  , diagsOf
  , errorsOf'
  , messagesOf
  , wrapProcess
    -- * Geometry access
  , shapeOf
  , maybeShapeOf
  , routeOf
  , allShapes
  , allRoutes
    -- * XML
  , Xml (..)
  , parseXml
  , childrenNamed
  , descendantsNamed
  , attr
  , textOf
  , findById
  ) where

import Data.Char (isSpace)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Bpmn.Semantic
import Sequent.Compiler
import Sequent.Diagnostic
import Sequent.Language.Parser (parseFile)
import Sequent.Language.Resolve (resolveFile, rrGraph)
import Sequent.Layout

-- Compiling --------------------------------------------------------------------

-- | Wrap a bare process body in the smallest process that will hold it, unless
-- the source already declares one.
wrapProcess :: Text -> Text
wrapProcess body
  | any (`T.isPrefixOf` T.stripStart body) starters = body
  | otherwise = "process p {\n" <> body <> "\n}"
  where
    starters = ["process", "collaboration", "message", "signal", "error", "escalation", "#"]

compileOk :: Text -> CompileResult
compileOk src = compileText defaultOptions "test.sq" (wrapProcess src)

compileXml :: Text -> Text
compileXml src = case crXml (compileOk src) of
  Just x -> x
  Nothing -> error (T.unpack (T.intercalate "; " (map diagMessage (crDiagnostics (compileOk src)))))

diagsOf :: Text -> [Diagnostic]
diagsOf src = checkText "test.sq" (wrapProcess src)

errorsOf' :: Text -> [Diagnostic]
errorsOf' = filter ((== Error) . diagSeverity) . diagsOf

messagesOf :: [Diagnostic] -> [String]
messagesOf = map (T.unpack . diagMessage)

graphOf :: Text -> SemanticGraph
graphOf src = case parseFile "test.sq" (wrapProcess src) of
  Left ds -> error (show (map diagMessage ds))
  Right ast -> case rrGraph (resolveFile ast) of
    Nothing -> error (show (messagesOf (diagsOf src)))
    Just g -> g

layoutOf :: Text -> LayoutResult
layoutOf src = case crLayout res of
  Just l -> l
  Nothing -> error (show (messagesOf (crDiagnostics res)))
  where
    res = compileText (defaultOptions {coStrictLayout = False}) "test.sq" (wrapProcess src)

-- Geometry ---------------------------------------------------------------------

allShapes :: LayoutResult -> Map NodeId Rect
allShapes = geoShapes . lrGeometry

allRoutes :: LayoutResult -> Map FlowId Route
allRoutes = geoRoutes . lrGeometry

shapeOf :: LayoutResult -> Text -> Rect
shapeOf l i =
  fromMaybe (error ("no shape for " <> T.unpack i)) (Map.lookup (NodeId i) (allShapes l))

maybeShapeOf :: LayoutResult -> Text -> Maybe Rect
maybeShapeOf l i = Map.lookup (NodeId i) (allShapes l)

routeOf :: LayoutResult -> Text -> Route
routeOf l i =
  fromMaybe (error ("no route for " <> T.unpack i)) (Map.lookup (FlowId i) (allRoutes l))

-- XML --------------------------------------------------------------------------

data Xml = Xml
  { xmlName     :: Text
  , xmlAttrs    :: [(Text, Text)]
  , xmlChildren :: [Xml]
  , xmlText     :: Text
  }
  deriving (Eq, Show)

-- | Parse a document this compiler produced. Failures are 'error' calls: a
-- test that cannot read its own output has already failed.
parseXml :: Text -> Xml
parseXml src = case element (skipProlog (T.strip src)) of
  Just (e, _) -> e
  Nothing -> error "parseXml: no root element"
  where
    skipProlog t
      | "<?" `T.isPrefixOf` t = skipProlog (T.stripStart (T.drop 2 (snd (T.breakOn "?>" t))))
      | "<!--" `T.isPrefixOf` t = skipProlog (T.stripStart (T.drop 3 (snd (T.breakOn "-->" t))))
      | otherwise = t

element :: Text -> Maybe (Xml, Text)
element t0 = do
  t1 <- T.stripPrefix "<" (T.stripStart t0)
  let (name, t2) = T.span nameChar t1
      (attrs, t3) = attributes (T.stripStart t2)
  case T.stripPrefix "/>" t3 of
    Just rest -> Just (Xml name attrs [] "", rest)
    Nothing -> do
      t4 <- T.stripPrefix ">" t3
      let (kids, txt, t5) = content name t4
      Just (Xml name attrs kids txt, t5)

nameChar :: Char -> Bool
nameChar c = not (isSpace c) && c `notElem` ("<>/=\"" :: String)

attributes :: Text -> ([(Text, Text)], Text)
attributes t
  | T.null t || "/>" `T.isPrefixOf` t || ">" `T.isPrefixOf` t = ([], t)
  | otherwise =
      let (k, r1) = T.span nameChar t
       in if T.null k
            then ([], t)
            else case T.stripPrefix "=\"" (T.stripStart r1) of
              Nothing -> ([], t)
              Just r2 ->
                let (v, r3) = T.breakOn "\"" r2
                    (rest, r4) = attributes (T.stripStart (T.drop 1 r3))
                 in ((k, unescape v) : rest, r4)

content :: Text -> Text -> ([Xml], Text, Text)
content name = go [] ""
  where
    go kids txt t
      | T.null t = (reverse kids, txt, t)
      | Just rest <- T.stripPrefix ("</" <> name <> ">") (T.stripStart t) = (reverse kids, T.strip txt, rest)
      | "<" `T.isPrefixOf` T.stripStart t =
          case element (T.stripStart t) of
            Just (e, rest) -> go (e : kids) txt rest
            Nothing -> (reverse kids, txt, t)
      | otherwise =
          let (chunk, rest) = T.breakOn "<" t
           in go kids (txt <> unescape chunk) rest

unescape :: Text -> Text
unescape =
  T.replace "&lt;" "<"
    . T.replace "&gt;" ">"
    . T.replace "&quot;" "\""
    . T.replace "&#10;" "\n"
    . T.replace "&#9;" "\t"
    . T.replace "&#13;" "\r"
    . T.replace "&amp;" "&"

childrenNamed :: Text -> Xml -> [Xml]
childrenNamed n e = [c | c <- xmlChildren e, xmlName c == n]

descendantsNamed :: Text -> Xml -> [Xml]
descendantsNamed n e =
  [c | c <- xmlChildren e, xmlName c == n] ++ concatMap (descendantsNamed n) (xmlChildren e)

attr :: Text -> Xml -> Maybe Text
attr k e = lookup k (xmlAttrs e)

textOf :: Xml -> Text
textOf = xmlText

findById :: Text -> Xml -> Maybe Xml
findById i root = case [e | e <- allElements root, attr "id" e == Just i] of
  (e : _) -> Just e
  [] -> Nothing
  where
    allElements e = e : concatMap allElements (xmlChildren e)
