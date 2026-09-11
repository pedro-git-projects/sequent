-- | Deterministic text measurement — LABEL-012.
--
-- Layout must measure labels with real font metrics, not @charCount ×
-- avgWidth@: the growth ladder (LAYOUT-029), container sizing and every
-- collision test depend on the answer, and an approximation that is wrong by
-- 15 % produces overlapping output on every second diagram (LABEL-011).
--
-- The metrics are a compiled-in advance-width table, so measurement never
-- consults the host's font configuration. That is a determinism requirement,
-- not an optimisation: LAYOUT-027 makes the measurement function part of the
-- output contract, and a table that varies by machine would make golden files
-- meaningless. 'FontMetrics' is a record rather than a hard-coded function so
-- that tests can substitute fixed synthetic metrics ('monospaceMetrics') and
-- assert layout consequences without depending on the real table.
module Sequent.Text.Metrics
  ( FontMetrics (..)
  , helvetica12
  , monospaceMetrics
  , measure
  , TextBox (..)
  , wrapText
  , wrapToLines
  , boxOf
  ) where

import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as T

-- | An advance-width table plus the vertical metrics derived from it.
data FontMetrics = FontMetrics
  { fmName     :: !Text
  -- ^ Identifies the table in diagnostics and in the determinism contract.
  , fmSize     :: !Int
  -- ^ Nominal font size in px.
  , fmLineH    :: !Int
  -- ^ Line height in px.
  , fmAdvance  :: Char -> Int
  -- ^ Advance width in 1/1000 em.
  }

instance Show FontMetrics where
  show fm = "FontMetrics " <> show (fmName fm) <> "/" <> show (fmSize fm)

instance Eq FontMetrics where
  a == b = fmName a == fmName b && fmSize a == fmSize b && fmLineH a == fmLineH b

-- | The default: Helvetica advance widths at 12 px, matching what BPMN
-- modellers render labels with. Values are the standard Adobe AFM widths in
-- 1/1000 em, which is what every renderer in this family agrees on.
helvetica12 :: FontMetrics
helvetica12 =
  FontMetrics
    { fmName = "helvetica"
    , fmSize = 12
    , fmLineH = 14
    , fmAdvance = helveticaAdvance
    }

-- | Fixed 600/1000 em per character. Used by tests that want a label width to
-- be a simple function of its length.
monospaceMetrics :: FontMetrics
monospaceMetrics =
  FontMetrics
    { fmName = "test-monospace"
    , fmSize = 12
    , fmLineH = 14
    , fmAdvance = const 600
    }

-- | Width of a single run of text, in whole pixels, rounded half-up.
measure :: FontMetrics -> Text -> Int
measure fm t = (total * fmSize fm + 500) `div` 1000
  where
    total = T.foldl' (\acc c -> acc + fmAdvance fm c) 0 t

-- | A measured, wrapped block of text.
data TextBox = TextBox
  { tbLines  :: [Text]
  , tbWidth  :: !Int
  , tbHeight :: !Int
  }
  deriving (Eq, Show)

-- | Wrap to a maximum pixel width, then clamp to a maximum line count,
-- truncating the last kept line with an ellipsis (LAYOUT-029 step 4).
--
-- Break priority follows LABEL-001: whitespace first, then @\/@ and @-@, then a
-- hard break inside the word. Hyphenation is never introduced.
wrapText :: FontMetrics -> Int -> Int -> Text -> TextBox
wrapText fm maxW maxLines t = boxOf fm clamped
  where
    ls = wrapToLines fm maxW t
    clamped
      | length ls <= maxLines = ls
      | maxLines <= 0 = []
      | otherwise = take (maxLines - 1) ls ++ [ellipsize fm maxW (T.unwords (drop (maxLines - 1) ls))]

-- | Measure an already-broken block of lines.
boxOf :: FontMetrics -> [Text] -> TextBox
boxOf fm ls =
  TextBox
    { tbLines = ls
    , tbWidth = maximum (0 : map (measure fm) ls)
    , tbHeight = length ls * fmLineH fm
    }

-- | Greedy line breaking at the priority points of LABEL-001.
wrapToLines :: FontMetrics -> Int -> Text -> [Text]
wrapToLines fm maxW t
  | T.null stripped = []
  | otherwise = go (breakTokens stripped)
  where
    stripped = T.strip t

    go [] = []
    go (tk : rest)
      -- An atom wider than the whole line gets a hard break inside the word;
      -- everything else starts a line and pulls in as many followers as fit.
      | measure fm tk > maxW =
          let (h, r) = hardSplit fm maxW tk
           in h : go (if T.null r then rest else r : rest)
      | otherwise =
          let (line, rest') = extend tk rest
           in line : go rest'

    extend acc [] = (acc, [])
    extend acc (tk : rest)
      | measure fm cand <= maxW = extend cand rest
      | otherwise = (acc, tk : rest)
      where
        cand = acc <> joiner acc <> tk

    -- A token that follows a "/" or "-" break rejoins without a space.
    joiner acc
      | not (T.null acc) && T.last acc `elem` ("/-" :: String) = ""
      | otherwise = " "

-- | Split text into the atoms a line break may fall between: words, and the
-- pieces of a word around a @\/@ or @-@ (the separator stays with the left
-- piece so the break reads correctly).
breakTokens :: Text -> [Text]
breakTokens = concatMap splitPunct . T.words
  where
    splitPunct w = go w
      where
        go x = case T.findIndex (`elem` ("/-" :: String)) x of
          Nothing -> [x | not (T.null x)]
          Just i ->
            let (a, b) = T.splitAt (i + 1) x
             in if T.null b then [a] else a : go b

-- | Hard-break an atom that does not fit on a line of its own.
hardSplit :: FontMetrics -> Int -> Text -> (Text, Text)
hardSplit fm maxW t = go 1
  where
    go n
      | n >= T.length t = (t, "")
      | measure fm (T.take (n + 1) t) > maxW = T.splitAt (max 1 n) t
      | otherwise = go (n + 1)

-- | Trim to width and append a single-character ellipsis.
ellipsize :: FontMetrics -> Int -> Text -> Text
ellipsize fm maxW t
  | measure fm t <= maxW = t
  | otherwise = go (T.length t)
  where
    ell = "\x2026"
    go 0 = ell
    go n
      | measure fm (T.take n t <> ell) <= maxW = T.stripEnd (T.take n t) <> ell
      | otherwise = go (n - 1)

-- | Helvetica advance widths, 1/1000 em. Anything outside the table (accented
-- Latin, CJK, emoji) falls back to the width of @0@, which is Helvetica's
-- digit width and a safe over-estimate for Latin text.
helveticaAdvance :: Char -> Int
helveticaAdvance c
  | isSpace c = 278
  | otherwise = case lookup c table of
      Just w -> w
      Nothing -> 556
  where
    table =
      zip "!\"#$%&'()*+,-./" [278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278]
        ++ zip "0123456789" (replicate 10 556)
        ++ zip ":;<=>?@" [278, 278, 584, 584, 584, 556, 1015]
        ++ zip
          "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
          [ 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833
          , 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611
          ]
        ++ zip "[\\]^_`" [278, 278, 278, 469, 556, 333]
        ++ zip
          "abcdefghijklmnopqrstuvwxyz"
          [ 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833
          , 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500
          ]
        ++ zip "{|}~" [334, 260, 334, 584]
