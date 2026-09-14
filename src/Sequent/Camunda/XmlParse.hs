-- | A small namespace-aware XML reader.
--
-- "Sequent.Camunda.Xml" is write-only on purpose: it bakes namespace prefixes
-- into element names because it only ever has to produce the one document
-- shape this compiler emits. Reading is the opposite problem. A @.bpmn@ from
-- Camunda Modeler, from Signavio, or from another generator agrees on the
-- namespace /URIs/ and on almost nothing else: prefixes differ, a default
-- namespace may be declared instead of a prefix, attribute order is arbitrary,
-- and text arrives wrapped in whatever indentation the writer felt like.
--
-- So this reader resolves prefixes to URIs and hands back a tree keyed on
-- @(uri, localName)@. Everything downstream matches on that, and a document
-- that spells @bpmn:process@, @bpmn2:process@ or @process@ under a default
-- namespace all read the same.
--
-- It is a reader for BPMN, not a general XML processor: there is no DTD
-- handling, no external entities, and no attempt at validation. Those are
-- deliberate omissions — an importer that resolves external entities is a
-- security problem, and one that validates is a second implementation of a
-- schema nobody asked it to check.
module Sequent.Camunda.XmlParse
  ( -- * The tree
    QName (..)
  , XNode (..)
  , parseXmlDocument
    -- * Queries
  , kidsNamed
  , kidNamed
  , kidsIn
  , kidIn
  , attrNamed
  , attrIn
  , textIn
    -- * The namespaces a BPMN file uses
  , nsBpmn
  , nsZeebe
  , nsModeler
  , nsXsi
  ) where

import Data.Char (chr, isDigit, isHexDigit)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Void (Void)
import Numeric (readHex)
import Text.Megaparsec
import Text.Megaparsec.Char

-- | An expanded name: the namespace URI the prefix resolved to, and the local
-- part. An unprefixed /attribute/ has no namespace (that is the XML rule, not
-- a simplification); an unprefixed /element/ takes the default namespace.
data QName = QName
  { qnUri   :: !Text
  , qnLocal :: !Text
  }
  deriving (Eq, Ord, Show)

data XNode = XNode
  { xnName     :: !QName
  , xnAttrs    :: [(QName, Text)]
  , xnChildren :: [XNode]
  , xnText     :: Text
  -- ^ The element's own character data, with surrounding whitespace kept.
  -- Callers that want a label strip it; callers that want a script do not.
  }
  deriving (Eq, Show)

nsBpmn, nsZeebe, nsModeler, nsXsi :: Text
nsBpmn = "http://www.omg.org/spec/BPMN/20100524/MODEL"
nsZeebe = "http://camunda.org/schema/zeebe/1.0"
nsModeler = "http://camunda.org/schema/modeler/1.0"
nsXsi = "http://www.w3.org/2001/XMLSchema-instance"

-- Queries ---------------------------------------------------------------------

-- | Children with this local name, whatever namespace they are in.
--
-- Local-name matching is the right default for BPMN: the vocabularies in play
-- do not collide, and a file whose author bound the BPMN namespace to an
-- unexpected prefix is still a file we should read. Where two vocabularies /do/
-- use the same local name — @script@ is both @bpmn:script@ inside a script task
-- and @zeebe:script@ beside it — use 'kidsIn' and say which one you mean.
kidsNamed :: Text -> XNode -> [XNode]
kidsNamed n e = [c | c <- xnChildren e, qnLocal (xnName c) == n]

kidNamed :: Text -> XNode -> Maybe XNode
kidNamed n = listToMaybe . kidsNamed n

-- | Children with this namespace and local name.
kidsIn :: Text -> Text -> XNode -> [XNode]
kidsIn uri n e = [c | c <- xnChildren e, xnName c == QName uri n]

kidIn :: Text -> Text -> XNode -> Maybe XNode
kidIn uri n = listToMaybe . kidsIn uri n

-- | An attribute by local name. Unprefixed attributes are the normal case in
-- BPMN — @id@, @name@, @sourceRef@ — and they carry no namespace.
attrNamed :: Text -> XNode -> Maybe Text
attrNamed n e = listToMaybe [v | (q, v) <- xnAttrs e, qnLocal q == n]

attrIn :: Text -> Text -> XNode -> Maybe Text
attrIn uri n e = listToMaybe [v | (q, v) <- xnAttrs e, q == QName uri n]

-- | The stripped text of a named child, if it has any.
textIn :: Text -> XNode -> Maybe Text
textIn n e = case T.strip . xnText <$> kidNamed n e of
  Just t | not (T.null t) -> Just t
  _ -> Nothing

-- Parsing ---------------------------------------------------------------------

type P = Parsec Void Text

-- | Read a document. Returns the root element with every name expanded.
parseXmlDocument :: FilePath -> Text -> Either Text XNode
parseXmlDocument path src = case runParser document path src of
  Right e -> Right e
  Left b -> Left (T.pack (errorBundlePretty b))

document :: P XNode
document = do
  misc
  e <- element Map.empty
  misc
  eof
  pure e

-- | Whatever may appear around the root: whitespace, comments, processing
-- instructions, the XML declaration, and a DOCTYPE we deliberately skip rather
-- than resolve.
misc :: P ()
misc = skipMany (void1 space1 <|> comment <|> processingInstruction <|> doctype)
  where
    void1 p = p >> pure ()

comment :: P ()
comment = try (string "<!--") >> skipManyTill anySingle (string "-->") >> pure ()

processingInstruction :: P ()
processingInstruction = try (string "<?") >> skipManyTill anySingle (string "?>") >> pure ()

-- | Skip a DOCTYPE, including an internal subset. Nothing in it is honoured:
-- an importer that expands entities from a DTD is an XXE waiting to happen.
doctype :: P ()
doctype = do
  _ <- try (string "<!DOCTYPE")
  let go depth
        | depth <= (0 :: Int) = pure ()
        | otherwise = do
            c <- anySingle
            case c of
              '>' -> go (depth - 1)
              '<' -> go (depth + 1)
              _ -> go depth
  go 1

element :: Map Text Text -> P XNode
element outer = do
  _ <- char '<'
  raw <- name
  as <- many (try attribute)
  space
  let scope = Map.union (declared as) outer
      expandedAttrs =
        [ (expand scope False k, v)
        | (k, v) <- as
        , not (isNsDecl k)
        ]
  selfClosing <- (True <$ try (string "/>")) <|> (False <$ char '>')
  if selfClosing
    then pure (XNode (expand scope True raw) expandedAttrs [] "")
    else do
      (cs, txt) <- content scope
      _ <- string "</"
      _ <- name
      space
      _ <- char '>'
      pure (XNode (expand scope True raw) expandedAttrs cs txt)
  where
    isNsDecl k = k == "xmlns" || "xmlns:" `T.isPrefixOf` k
    declared as =
      Map.fromList
        ( [("", v) | ("xmlns", v) <- as]
            ++ [(T.drop 6 k, v) | (k, v) <- as, "xmlns:" `T.isPrefixOf` k]
        )

-- | Expand a raw name against the in-scope bindings. An unprefixed element
-- takes the default namespace; an unprefixed attribute takes none. A prefix
-- that was never bound keeps its own spelling as the URI, so a malformed
-- document degrades to \"names that do not match\" rather than to a crash.
expand :: Map Text Text -> Bool -> Text -> QName
expand scope isElement raw = case T.breakOn ":" raw of
  (local, rest)
    | T.null rest -> QName (if isElement then Map.findWithDefault "" "" scope else "") local
  (prefix, rest) -> QName (Map.findWithDefault prefix prefix scope) (T.drop 1 rest)

name :: P Text
name = takeWhile1P (Just "name character") isNameChar
  where
    isNameChar c = c `notElem` (" \t\r\n/<>=\"'" :: String)

attribute :: P (Text, Text)
attribute = do
  space
  k <- name
  space
  _ <- char '='
  space
  q <- char '"' <|> char '\''
  v <- manyTill (entity <|> anySingle) (char q)
  pure (k, T.pack v)

content :: Map Text Text -> P ([XNode], Text)
content scope = go [] []
  where
    go es ts =
      choice
        [ do
            _ <- lookAhead (try (string "</"))
            pure (reverse es, T.concat (reverse ts))
        , do
            comment
            go es ts
        , do
            processingInstruction
            go es ts
        , do
            t <- cdata
            go es (t : ts)
        , do
            e <- try (element scope)
            go (e : es) ts
        , do
            t <- charData
            go es (t : ts)
        ]

cdata :: P Text
cdata = do
  _ <- try (string "<![CDATA[")
  T.pack <$> manyTill anySingle (string "]]>")

charData :: P Text
charData = T.pack <$> some (entity <|> satisfy (/= '<'))

-- | The five predefined entities and numeric character references. Anything
-- else is left as written: a reference to an entity a DTD would have defined is
-- not something this reader is willing to resolve.
entity :: P Char
entity = try $ do
  _ <- char '&'
  n <- takeWhile1P (Just "entity name") (/= ';')
  _ <- char ';'
  case n of
    "amp" -> pure '&'
    "lt" -> pure '<'
    "gt" -> pure '>'
    "quot" -> pure '"'
    "apos" -> pure '\''
    _ | Just c <- numeric n -> pure c
    _ -> failure Nothing mempty

numeric :: Text -> Maybe Char
numeric n = case T.unpack n of
  ('#' : 'x' : ds) | all isHexDigit ds, [(v, "")] <- readHex ds -> codePoint v
  ('#' : ds) | all isDigit ds, not (null ds) -> codePoint (read ds)
  _ -> Nothing
  where
    codePoint v = if v >= (0 :: Int) && v <= 0x10FFFF then Just (chr v) else Nothing
