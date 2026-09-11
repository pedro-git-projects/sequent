-- | Labels as geometry — LABEL-001…012, LAYOUT-029, LAYOUT-030.
--
-- LABEL-011 is the rule this module exists to obey: __a label is a rectangle
-- in @RG@__, and it takes part in bounding boxes, collision detection, routing
-- obstacles, whitespace metrics and diagram bounds. A formatter that treats
-- labels as XML decoration produces overlapping output on every second
-- diagram, because the text is what actually fills the space.
--
-- Sizing lives here too. An activity's size is a function of its label
-- (LAYOUT-029's growth ladder) and of how many boundary events have to fit
-- along its bottom edge (LAYOUT-016), so it belongs with text measurement
-- rather than with the geometry phases that consume it.
module Sequent.Layout.Labels
  ( -- * Sizing
    nodeSize
  , activityGrowthLadder
  , hostWidthForBoundaries
  , nodeHasMarker
    -- * Label content
  , internalLabel
  , externalLabelBox
  , flowLabelBox
  , externalLabelExtent
    -- * Placement (phase 9)
  , LabelAnchor (..)
  , placeExternalLabel
  , placeExternalLabelSized
  , placeFlowLabel
  , labelledSegment
  , anchorLadder
  , anchorAway
  ) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Sequent.Bpmn.Semantic
import Sequent.Camunda.Model (LoopSpec)
import Sequent.Layout.Constants
import Sequent.Layout.Types
import Sequent.Text.Metrics

-- Sizing ---------------------------------------------------------------------

-- | LAYOUT-003 canonical sizes, with the two sanctioned deviations applied:
-- label growth (LAYOUT-029) and boundary-event fit (LAYOUT-016). Expanded
-- subprocesses are sized by their own recursive layout (LAYOUT-019) and are
-- passed in through @subSize@ rather than guessed here.
nodeSize :: FontMetrics -> (NodeId -> Maybe (Int, Int)) -> Int -> FlowNode -> (Int, Int)
nodeSize fm subSize boundaryCount n = case fnKind n of
  NkEvent _ -> (evSize, evSize)
  NkGateway _ -> (gwSize, gwSize)
  NkActivity a -> case acKind a of
    AkSubprocess _ -> fromMaybe (subMinW, subMinH) (subSize (fnId n))
    _ ->
      let (w0, h0) = activityGrowthLadder fm (nodeHasMarker n) (fromMaybe "" (fnName n))
          w1 = max w0 (hostWidthForBoundaries boundaryCount)
       in (w1, h0)

-- | LAYOUT-029, applied in strict order, stopping at the first step that fits.
-- Widening comes before heightening because it leaves centre alignment and
-- band heights untouched — the cheaper deformation.
activityGrowthLadder :: FontMetrics -> Bool -> Text -> (Int, Int)
activityGrowthLadder fm marker label = go taskW taskH
  where
    reserved = if marker then markerBand else 0
    go w h
      | fits w h = (w, h)
      | w < taskWMax = go (w + 2 * u) h
      | h < taskHMax = go w (h + 2 * u)
      | otherwise = (taskWMax, taskHMax)
    fits w h =
      let box = wrapText fm (w - 2 * labelPad) taskMaxLines label
       in tbWidth box <= w - 2 * labelPad && tbHeight box <= h - 2 * labelPad - reserved

-- | LAYOUT-016: @k@ boundary events need @k·EV + (k+1)·BE_GAP@ of edge, and
-- the host grows in @2U@ steps to provide it, up to @TASK_W_MAX@.
hostWidthForBoundaries :: Int -> Int
hostWidthForBoundaries k
  | k <= 0 = taskW
  -- "if requiredW > w(host)" — growth is conditional. A single boundary event
  -- needs 56 px, so widening unconditionally would /shrink/ a canonical
  -- activity, which is the opposite of what the rule says.
  | requiredHostW k <= taskW = taskW
  | otherwise = min taskWMax (roundUpTo (2 * u) (requiredHostW k))
  where
    roundUpTo m x = ((x + m - 1) `div` m) * m

-- | LAYOUT-030: does this activity draw a marker band at its bottom centre?
nodeHasMarker :: FlowNode -> Bool
nodeHasMarker n = case fnKind n of
  NkActivity a -> hasLoop (acLoop a) || isCollapsedSub (acKind a)
  _ -> False
  where
    hasLoop :: Maybe LoopSpec -> Bool
    hasLoop = maybe False (const True)
    isCollapsedSub AkCallActivity = True
    isCollapsedSub _ = False

-- Label content --------------------------------------------------------------

-- | LABEL-001: the wrapped text inside an activity.
internalLabel :: FontMetrics -> Rect -> Bool -> Text -> TextBox
internalLabel fm r marker label =
  wrapText fm (rW r - 2 * labelPad) (linesThatFit) label
  where
    reserved = if marker then markerBand else 0
    linesThatFit = max 1 (min taskMaxLines ((rH r - 2 * labelPad - reserved) `div` fmLineH fm))

-- | LABEL-002 \/ LABEL-003: the external label of an event or gateway, wrapped
-- to @LABEL_MAX_W@.
--
-- As many lines as the text needs, not the two the rule asks for. Two lines is
-- a wish about presentation that this format cannot enforce: BPMN DI carries a
-- bounds rectangle and the renderer draws the element's @name@ inside it, so
-- capping the /measurement/ at two lines and emitting the full name does not
-- shorten the label — it shortens only our idea of it, and the third line is
-- drawn over whatever the band below reserved. That is the shape of the bug it
-- caused: a gateway caption measured 28 px tall, rendered 40, and the overflow
-- landed on the gateway.
--
-- Ellipsising the measurement is the same mistake with a worse name. LABEL-006
-- forbids solving a collision by hiding the label, and a box that claims two
-- lines for text the renderer will set in three hides it from the formatter
-- alone.
externalLabelBox :: FontMetrics -> Text -> TextBox
externalLabelBox fm = boxOf fm . wrapToLines fm labelMaxW

-- | LABEL-005: a sequence-flow label. Same wrapping rules as an external
-- label; the difference is only where it is anchored.
flowLabelBox :: FontMetrics -> Text -> TextBox
flowLabelBox fm = boxOf fm . wrapToLines fm labelMaxW

-- | How much vertical room a node's external label claims beside it, for
-- BRANCH-002's bounding box. Events label below, gateways above; both amounts
-- are reserved in the band stack rather than discovered after placement.
externalLabelExtent :: FontMetrics -> FlowNode -> Extent
externalLabelExtent fm n = case fnName n of
  Nothing -> mempty
  Just "" -> mempty
  Just t -> case fnKind n of
    NkEvent _ -> Extent 0 (labelGap + tbHeight (externalLabelBox fm t))
    NkGateway _ -> Extent (labelGap + tbHeight (externalLabelBox fm t)) 0
    NkActivity _ -> mempty

-- Placement ------------------------------------------------------------------

-- | The anchors of LABEL-002 \/ LABEL-003 \/ LABEL-006, tried in a fixed order
-- so the first legal one is a deterministic choice rather than a search.
data LabelAnchor
  = AnchorBelow
  | AnchorAbove
  | AnchorRight
  | AnchorLeft
  | AnchorBelowLeft
  | AnchorAboveLeft
  | AnchorBelowRight
  | AnchorAboveRight
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The anchor ladder for a node's external label. Events prefer below,
-- gateways above; a boundary event goes below-left so the label does not sit
-- on the exception stub that leaves downward at its centre (LABEL-004).
--
-- Every ladder carries the mirror of its first choice. Two boundary events on
-- one host are @BE_GAP@ apart along an edge that is rarely as wide as one of
-- their labels, so a ladder that only ever reaches left runs out of anchors on
-- the second event and lands its label on top of the first — the overlap this
-- ladder exists to avoid. Reaching left, then right, then up, then up-right
-- puts the pair on opposite sides of the fan, which is also how a person draws
-- it (LABEL-004's \"mirror for top-attached\" generalised to left and right).
anchorLadder :: FlowNode -> [LabelAnchor]
anchorLadder n = case fnKind n of
  NkEvent (EventSpec (EvBoundary _) _) ->
    [AnchorBelowLeft, AnchorBelowRight, AnchorAboveLeft, AnchorAboveRight, AnchorLeft, AnchorRight]
  NkEvent _ -> [AnchorBelow, AnchorAbove, AnchorRight, AnchorLeft, AnchorBelowLeft, AnchorBelowRight]
  NkGateway _ -> [AnchorAbove, AnchorBelow, AnchorAboveLeft, AnchorBelowLeft, AnchorAboveRight, AnchorBelowRight]
  NkActivity _ -> [AnchorBelow]

-- | Which way a label leaves its node. LABEL-006's last resort is more room,
-- and the room is taken in the direction the anchor already chose.
anchorAway :: LabelAnchor -> (Int, Int)
anchorAway a = case a of
  AnchorBelow -> (0, 1)
  AnchorBelowLeft -> (0, 1)
  AnchorBelowRight -> (0, 1)
  AnchorAbove -> (0, -1)
  AnchorAboveLeft -> (0, -1)
  AnchorAboveRight -> (0, -1)
  AnchorRight -> (1, 0)
  AnchorLeft -> (-1, 0)

placeExternalLabel :: Rect -> TextBox -> LabelAnchor -> Rect
placeExternalLabel shape box = placeExternalLabelSized shape (tbWidth box, tbHeight box)

-- | The same placement from a size alone, for a label that already exists and
-- has to be moved (LABEL-006's repair, EDGE-018's repair).
placeExternalLabelSized :: Rect -> (Int, Int) -> LabelAnchor -> Rect
placeExternalLabelSized shape (w0, h0) anchor = case anchor of
  AnchorBelow -> Rect (cx - w `div` 2) (rectBottom shape + labelGap) w h
  AnchorAbove -> Rect (cx - w `div` 2) (rY shape - labelGap - h) w h
  AnchorRight -> Rect (rectRight shape + labelGap) (cy - h `div` 2) w h
  AnchorLeft -> Rect (rX shape - labelGap - w) (cy - h `div` 2) w h
  AnchorBelowLeft -> Rect (cx - u - w) (rectBottom shape + labelGap) w h
  AnchorAboveLeft -> Rect (cx - u - w) (rY shape - labelGap - h) w h
  AnchorBelowRight -> Rect (cx + u) (rectBottom shape + labelGap) w h
  AnchorAboveRight -> Rect (cx + u) (rY shape - labelGap - h) w h
  where
    w = max 1 w0
    h = max 1 h0
    cx = rectCenterX shape
    cy = rectCenterY shape

-- | LABEL-005: anchored to the first horizontal segment after the source,
-- offset above it, left-aligned at the segment start @+ 1U@.
--
-- @stackX@ is the shared left edge of a split's outgoing labels. For a comb the
-- peel segment starts at the gateway's centre @x@, so /all/ of one gateway's
-- outgoing labels take that same left edge and form a vertically aligned stack
-- — including the axis branch, whose own segment starts further right at the
-- @E@ port. Aligning the stack is the single most effective device for making
-- Yes\/No labels look deliberate rather than scattered, and the detector for
-- it (labels of one gateway with differing @x@) is what @labelStackPenalty@
-- scores.
placeFlowLabel :: Maybe Int -> Route -> TextBox -> Rect
placeFlowLabel stackX route box = case firstHorizontal (routeSegments (rtPoints route)) of
  Just (Segment a b) ->
    let x0 = maybe (min (ptX a) (ptX b) + u) (+ u) stackX
     in Rect x0 (ptY a - flowLabelOffset - h) w h
  Nothing -> case routeSegments (rtPoints route) of
    (Segment a _ : _) -> Rect (ptX a + flowLabelOffset) (ptY a + u) w h
    [] -> Rect 0 0 w h
  where
    w = max 1 (tbWidth box)
    h = max 1 (tbHeight box)

-- | EDGE-018: the one segment of its own route a flow label may overlap — the
-- one it annotates, which it is drawn offset from. Every /other/ segment of the
-- same edge is an obstacle like anyone else's: a label that overhangs the end
-- of the segment it names and lands on that edge's next turn is a line drawn
-- through text, and "it belongs to this edge" does not make it readable.
labelledSegment :: Route -> Maybe Segment
labelledSegment route = case firstHorizontal segs of
  Just s -> Just s
  Nothing -> case segs of
    (s : _) -> Just s
    [] -> Nothing
  where
    segs = routeSegments (rtPoints route)

firstHorizontal :: [Segment] -> Maybe Segment
firstHorizontal segs = case [s | s <- segs, ptY (segA s) == ptY (segB s), segLength s > 0] of
  (s : _) -> Just s
  [] -> Nothing
