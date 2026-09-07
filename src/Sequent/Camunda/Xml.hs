-- | A minimal write-only XML tree and serializer.
--
-- We never read XML, so namespaces are fixed prefix constants baked into the
-- element names rather than anything discovered or resolved. The serializer is
-- deterministic: attribute order is list order, indentation is two spaces, and
-- empty elements are self-closing.
module Sequent.Camunda.Xml
  ( Element (..)
  , Content (..)
  , Attr
  , elem_
  , leaf
  , textElem
  , render
  , renderDocument
  , escapeAttr
  , escapeText
  ) where

import Data.Text (Text)
import qualified Data.Text as T

-- | An attribute: qualified name and value. The value is escaped on render.
type Attr = (Text, Text)

data Element = Element
  { elName     :: Text
  , elAttrs    :: [Attr]
  , elChildren :: [Content]
  }
  deriving (Eq, Show)

data Content
  = CElem Element
  | CText Text
  deriving (Eq, Show)

-- | Element with element children.
elem_ :: Text -> [Attr] -> [Element] -> Element
elem_ n as cs = Element n as (map CElem cs)

-- | Childless element; renders self-closing.
leaf :: Text -> [Attr] -> Element
leaf n as = Element n as []

-- | Element whose only content is a text node; renders on one line.
textElem :: Text -> [Attr] -> Text -> Element
textElem n as t = Element n as [CText t]

-- | Render a document: XML declaration, the root element, trailing newline.
renderDocument :: Element -> Text
renderDocument root =
  T.concat
    [ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    , render root
    , "\n"
    ]

-- | Render an element tree with no XML declaration and no trailing newline.
render :: Element -> Text
render = T.concat . renderElement 0

renderElement :: Int -> Element -> [Text]
renderElement depth (Element name attrs children) =
  case children of
    [] ->
      [pad, open, " />"]
    _ | all isText children ->
      [pad, open, ">", escapeText (T.concat [t | CText t <- children]), "</", name, ">"]
    _ ->
      concat
        [ [pad, open, ">\n"]
        , concatMap (\c -> renderContent (depth + 1) c ++ ["\n"]) children
        , [pad, "</", name, ">"]
        ]
  where
    pad = indent depth
    open = T.concat (["<", name] ++ map renderAttr attrs)

renderContent :: Int -> Content -> [Text]
renderContent depth (CElem e) = renderElement depth e
renderContent depth (CText t) = [indent depth, escapeText t]

isText :: Content -> Bool
isText (CText _) = True
isText (CElem _) = False

indent :: Int -> Text
indent n = T.replicate n "  "

renderAttr :: Attr -> Text
renderAttr (k, v) = T.concat [" ", k, "=\"", escapeAttr v, "\""]

-- | Escape an attribute value. Whitespace other than a plain space becomes a
-- numeric character reference so that XML attribute-value normalisation cannot
-- silently rewrite it on the way back in.
escapeAttr :: Text -> Text
escapeAttr = T.concatMap esc
  where
    esc '&'  = "&amp;"
    esc '<'  = "&lt;"
    esc '>'  = "&gt;"
    esc '"'  = "&quot;"
    esc '\n' = "&#10;"
    esc '\r' = "&#13;"
    esc '\t' = "&#9;"
    esc c    = T.singleton c

-- | Escape character data.
escapeText :: Text -> Text
escapeText = T.concatMap esc
  where
    esc '&' = "&amp;"
    esc '<' = "&lt;"
    esc '>' = "&gt;"
    esc c   = T.singleton c
