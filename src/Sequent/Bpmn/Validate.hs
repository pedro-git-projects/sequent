-- | Semantic validation of the BPMN graph, run before layout.
--
-- The division of labour is deliberate and is the reason this module exists
-- separately from the layout engine: __layout is never responsible for fixing
-- invalid BPMN__. If a graph reaches "Sequent.Layout" it is already a
-- well-formed process, so every repair the layout engine performs is a
-- geometric one. A formatter that silently repairs semantics produces diagrams
-- that do not describe the process the author wrote.
--
-- Everything here is generic BPMN. Camunda-specific requirements live in
-- "Sequent.Camunda.Validate" so that the two can be reported — and disabled —
-- independently.
module Sequent.Bpmn.Validate
  ( validateGraph
  ) where

import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Bpmn.Graph
import Sequent.Bpmn.Semantic
import Sequent.Diagnostic

-- | All semantic diagnostics for a graph, in deterministic order.
validateGraph :: Provenance -> SemanticGraph -> [Diagnostic]
validateGraph prov g =
  sortDiagnostics $
    concatMap (processDiags prov) (sgProcesses g)
      ++ collaborationDiags prov g

-- Process --------------------------------------------------------------------

processDiags :: Provenance -> BpmnProcess -> [Diagnostic]
processDiags prov p =
  rootScopeDiags prov (procName p) (procScope p)
    ++ concatMap (scopeDiags prov) (allScopes (procScope p))
    ++ concatMap (subprocessDiags prov) (subprocesses (procScope p))
    ++ concatMap (startDiags prov) (scopesTagged (procScope p))

-- | Every subprocess reachable from a scope, with the kind it was declared as
-- and the node that owns it. 'allScopes' loses both, and both decide which
-- rules apply.
subprocesses :: Scope -> [(SubprocessKind, NodeId, Scope)]
subprocesses sc =
  [ (k, fnId n, inner)
  | s <- allScopes sc
  , n <- scNodes s
  , NkActivity (Activity (AkSubprocess k inner) _) <- [fnKind n]
  ]

-- | Every scope, paired with whether it is the body of an event subprocess.
--
-- That one bit decides which start events are legal: an error start, a
-- compensation start and a non-interrupting start are meaningful only where
-- there is an enclosing scope for them to interrupt.
scopesTagged :: Scope -> [(Bool, Scope)]
scopesTagged = go False
  where
    go ev sc =
      (ev, sc)
        : concat
          [ go (k == SpEventSub) inner
          | n <- scNodes sc
          , NkActivity (Activity (AkSubprocess k inner) _) <- [fnKind n]
          ]

-- | The outermost scope of a process must be startable.
rootScopeDiags :: Provenance -> Maybe Text -> Scope -> [Diagnostic]
rootScopeDiags _ nm sc
  | any isStartEvent (scNodes sc) = []
  | otherwise =
      [ withHint
          "add one: start placed \"Order placed\""
          ( diagnostic
              Error
              SemanticError
              ("process " <> quoted (fromMaybe "" nm) <> " has no start event")
          )
      ]

-- | An expanded subprocess is a scope in its own right: BPMN requires it to be
-- enterable and leavable, and a subprocess whose token can never leave hangs
-- the parent instance.
subprocessDiags :: Provenance -> (SubprocessKind, NodeId, Scope) -> [Diagnostic]
subprocessDiags prov (kind, owner, sc) =
  [ d Error (what <> " needs exactly one start event") startHint
  | null starts
  ]
    ++ [ d Error (what <> " has more than one start event") multiHint
       | length starts > 1
       ]
    ++ [ d Error (what <> " needs at least one end event") "add: end finished"
       | null ends
       ]
  where
    starts = filter isStartEvent (scNodes sc)
    ends = filter isEndEvent (scNodes sc)
    at = spanOfNode prov owner
    d sev msg hint = maybe id (\s x -> x {diagSpan = Just s}) at (withHint hint (diagnostic sev SemanticError msg))

    what = case kind of
      SpEmbedded -> "a subprocess"
      SpEventSub -> "an event subprocess"
    startHint = case kind of
      SpEmbedded -> "add: start began"
      SpEventSub -> "add the event that starts it: start caught { error payment_failed }"
    multiHint = case kind of
      SpEmbedded -> "BPMN allows only one none-start event inside an embedded subprocess"
      SpEventSub -> "an event subprocess is started by one event; write a second handler for a second trigger"

-- | Which start events belong where.
--
-- Every rule here is the same rule seen from two sides: @isInterrupting@, an
-- error trigger and a compensation trigger all describe a start event's
-- relationship to a scope /around/ it, and only an event subprocess has one.
startDiags :: Provenance -> (Bool, Scope) -> [Diagnostic]
startDiags prov (inHandler, sc) = concatMap one (scNodes sc)
  where
    at i = spanOfNode prov i
    d sev i msg hint = maybe id (\s x -> x {diagSpan = Just s}) (at i) (withHint hint (diagnostic sev SemanticError msg))
    named n = quoted (fromMaybe (unNodeId (fnId n)) (fnName n))

    one n = case fnKind n of
      NkEvent (EventSpec (EvStart i) def) ->
        [ d
            Error
            (fnId n)
            (named n <> " catches " <> triggerWord t <> ", which only the start of an event subprocess can do")
            "put it in a handler block, or hang a boundary event on the step that fails"
        | not inHandler
        , Just t <- [def]
        , scopedTrigger t
        ]
          ++ [ d
                 Error
                 (fnId n)
                 (named n <> " is non-interrupting, and there is no enclosing scope for it to leave running")
                 "'noninterrupting' belongs on the start event of a handler block"
             | not inHandler
             , not (isInterrupting i)
             ]
          ++ [ d
                 Error
                 (fnId n)
                 (named n <> " starts an event subprocess but waits for nothing")
                 "an event subprocess runs when its trigger fires: start caught { error payment_failed }"
             | inHandler
             , def == Nothing
             ]
      _ -> []

    -- The triggers that only mean something with a scope around them.
    scopedTrigger t = case t of
      EdError _ -> True
      EdCompensation -> True
      _ -> False

    triggerWord t = case t of
      EdError _ -> "an error"
      EdCompensation -> "a compensation"
      _ -> "that"


-- | Everything that is checkable from one scope's flow graph.
scopeDiags :: Provenance -> Scope -> [Diagnostic]
scopeDiags prov sc =
  concat
    [ danglingFlowDiags
    , startIncomingDiags
    , endOutgoingDiags
    , unreachableDiags
    , sinkDiags
    , gatewayDiags
    , boundaryDiags
    , groupDiags
    ]
  where
    nodes = scNodes sc
    byId = scopeNodeMap sc
    fg = buildFlowGraph sc

    at i = spanOfNode prov i
    err i msg = withSpan (at i) (diagnostic Error SemanticError msg)
    warn i msg = withSpan (at i) (diagnostic Warning SemanticError msg)
    adv i msg = withSpan (at i) (diagnostic Advisory SemanticError msg)
    withSpan s d = maybe d (\x -> d {diagSpan = Just x}) s

    named n = quoted (fromMaybe (unNodeId (fnId n)) (fnName n))

    -- A sequence flow never leaves its process (HC-008). After resolution this
    -- can only happen through the explicit @flow@ escape hatch referring
    -- across a subprocess boundary.
    danglingFlowDiags =
      [ withSpan
          (spanOfFlow prov (sfId f))
          ( withHint
              "a sequence flow cannot cross a subprocess or pool boundary; use a message flow (~>) between pools"
              ( diagnostic
                  Error
                  SemanticError
                  ("flow " <> quoted (unFlowId (sfId f)) <> " connects steps in different scopes")
              )
          )
      | f <- scFlows sc
      , not (Map.member (sfSource f) byId) || not (Map.member (sfTarget f) byId)
      ]

    startIncomingDiags =
      [ withHint "a start event begins the process; nothing can flow into it" (err (fnId n) (named n <> " is a start event and cannot have an incoming flow"))
      | n <- nodes
      , isStartEvent n
      , not (null (incomingOf sc (fnId n)))
      ]

    endOutgoingDiags =
      [ withHint "an end event stops the path; use a gateway if the flow continues" (err (fnId n) (named n <> " is an end event and cannot have an outgoing flow"))
      | n <- nodes
      , isEndEvent n
      , not (null (outgoingOf sc (fnId n)))
      ]

    -- Reachability is computed on the contracted graph, so a boundary event
    -- counts as reachable through the activity it hangs on.
    reachable = reachableFrom fg (mapMaybe (vtxOf fg . fnId) (filter isStartEvent nodes))
    unreachableDiags =
      [ withHint
          "connect it, or delete it"
          (err (fnId n) (named n <> " is not reachable from any start event"))
      | n <- nodes
      , not (isStartEvent n)
      , not (isEventSubprocess n)
      , Just v <- [vtxOf fg (fnId n)]
      , let host = fromMaybe v (IM.lookup v (fgLift fg))
      , not (IS.member host reachable)
      ]

    -- An event subprocess is on no path by construction, so neither rule
    -- applies to it: it is started by its own event and it hands nothing back.
    -- A path that stops short of an end event is worth mentioning once. If the
    -- author wrote @stop@ they have already been told and have answered, so it
    -- drops to an advisory that says what the engine will do rather than
    -- repeating the suggestion they declined.
    sinkDiags =
      [ if stoppedExplicitly prov (fnId n)
          then
            withHint
              "the instance ends when every path has run out; nothing else happens here"
              (adv (fnId n) (named n <> " ends its path without an end event, as written"))
          else
            withHint
              "end the path explicitly, or write 'stop' if it really leads nowhere"
              (warn (fnId n) (named n <> " has no outgoing flow and is not an end event"))
      | n <- nodes
      , not (isEndEvent n)
      , not (nodeIsBoundary n)
      , not (isEventSubprocess n)
      , null (outgoingOf sc (fnId n))
      ]
      ++ [ withHint
             "an event subprocess runs when its trigger fires, not when something flows into it"
             (err (fnId n) (named n <> " is an event subprocess and cannot be connected by a sequence flow"))
         | n <- nodes
         , isEventSubprocess n
         , not (null (outgoingOf sc (fnId n))) || not (null (incomingOf sc (fnId n)))
         ]

    gatewayDiags = concatMap one nodes
      where
        one n = case fnKind n of
          NkGateway k -> gatewayChecks n k
          _ -> []

    gatewayChecks n k =
      let outs = outgoingOf sc (fnId n)
          ins = incomingOf sc (fnId n)
          defaults = [f | f <- outs, sfCondition f == Just FcDefault]
          unconditioned = [f | f <- outs, sfCondition f == Nothing]
       in concat
            [ [ withHint
                  "a gateway with one way in and one way out has no effect; delete it"
                  (adv (fnId n) (named n <> " is a gateway with one incoming and one outgoing flow"))
              | length ins == 1 && length outs == 1
              ]
            , [ withHint
                  "mark exactly one branch 'otherwise'"
                  (err (fnId n) (named n <> " has more than one default branch"))
              | length defaults > 1
              ]
            , [ withHint
                  "give every branch a 'when', or mark one 'otherwise'"
                  ( warn
                      (fnId n)
                      ( named n
                          <> " is a data-based gateway with "
                          <> tshow (length unconditioned)
                          <> " unconditional branches"
                      )
                  )
              | k `elem` [GwExclusive, GwInclusive]
              , length outs > 1
              , length unconditioned > 1
              ]
            , [ withHint
                  "every branch of a parallel gateway runs; conditions are ignored"
                  (err (fnId n) (named n <> " is a parallel gateway with a conditional branch"))
              | k == GwParallel
              , any ((/= Nothing) . sfCondition) outs
              ]
            , eventBasedChecks n k outs
            ]

    eventBasedChecks n k outs
      | k /= GwEventBased = []
      | otherwise =
          [ withHint
              "an event gateway must offer at least two alternatives"
              (err (fnId n) (named n <> " is an event gateway with fewer than two branches"))
          | length outs < 2
          ]
            ++ [ withHint
                   "every branch of an event gateway must begin with a catching event or a receive task"
                   ( err
                       (fnId n)
                       (named n <> " has a branch that does not begin with a catching event")
                   )
               | f <- outs
               , Just t <- [Map.lookup (sfTarget f) byId]
               , not (isCatching t)
               ]

    isCatching t = case fnKind t of
      NkEvent (EventSpec EvIntermediateCatch _) -> True
      NkActivity (Activity (AkTask (TtReceive _)) _) -> True
      _ -> False

    boundaryDiags =
      [ withHint
          "a boundary event must hang on an activity in the same scope"
          (err (fnId n) (named n <> " is attached to a step outside its scope"))
      | n <- nodes
      , Just att <- [boundaryHost n]
      , not (Map.member (baHost att) byId)
      ]

    -- A group is a rectangle drawn round its members (ART-005), and a
    -- rectangle cannot be drawn round steps in two different scopes: one of
    -- them is inside a subprocess, in its own coordinate frame. Names resolve
    -- across the whole process, so this is checkable only here.
    groupDiags =
      [ withSpan
          (spanOfNode prov m)
          ( withHint
              "a group holds steps from one scope; declare a second group inside the subprocess"
              ( diagnostic
                  Error
                  SemanticError
                  ( "group " <> quoted (fromMaybe (unArtifactId (artId a)) (artName a))
                      <> " has a member outside its scope: " <> quoted (unNodeId m)
                  )
              )
          )
      | a <- scArtifacts sc
      , artKind a == AkGroup
      , m <- artMembers a
      , not (Map.member m byId)
      ]

-- Collaboration --------------------------------------------------------------

collaborationDiags :: Provenance -> SemanticGraph -> [Diagnostic]
collaborationDiags prov g = case sgCollaboration g of
  Nothing -> []
  Just c ->
    let owners = participantOwners g c
        endpointPool r = case r of
          RefParticipant pid -> Just pid
          RefNode n -> Map.lookup n owners
          _ -> Nothing
     in [ withSpanOf (spanOfFlow prov (mfId m))
            ( withHint
                "a message flow connects two pools; use -> for a flow inside one pool"
                ( diagnostic
                    Error
                    SemanticError
                    ("message flow " <> quoted (unFlowId (mfId m)) <> " does not cross a pool boundary")
                )
            )
        | m <- colMessageFlows c
        , let a = endpointPool (mfSource m)
        , let b = endpointPool (mfTarget m)
        , a /= Nothing && a == b
        ]
          ++ [ withHint
                 "declare it as a pool inside the collaboration"
                 ( diagnostic
                     Error
                     SemanticError
                     ("message flow " <> quoted (unFlowId (mfId m)) <> " has an endpoint in no pool")
                 )
             | m <- colMessageFlows c
             , endpointPool (mfSource m) == Nothing || endpointPool (mfTarget m) == Nothing
             ]
  where
    withSpanOf s d = maybe d (\x -> d {diagSpan = Just x}) s

-- | Which participant owns each flow node, for the pool-crossing checks.
participantOwners :: SemanticGraph -> Collaboration -> Map NodeId ParticipantId
participantOwners g c =
  Map.fromList
    [ (fnId n, partId pt)
    | pt <- colParticipants c
    , Just pid <- [partProcess pt]
    , pr <- sgProcesses g
    , procId pr == pid
    , sc <- allScopes (procScope pr)
    , n <- scNodes sc
    ]

-- Helpers --------------------------------------------------------------------

quoted :: Text -> Text
quoted t = "'" <> t <> "'"

tshow :: Show a => a -> Text
tshow = T.pack . show
