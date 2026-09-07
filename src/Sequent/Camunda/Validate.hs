-- | Camunda 8 execution-metadata validation.
--
-- Separate from "Sequent.Bpmn.Validate" because these are not BPMN rules: a
-- process can be perfectly valid BPMN 2.0 and still be rejected by @zbctl
-- deploy@. Catching those at compile time is the difference between a
-- diagnostic with a caret and a deployment failure with an element id.
--
-- Every check here corresponds to something Zeebe actually enforces, or to a
-- misconfiguration whose runtime symptom is silent (a FEEL expression that was
-- meant to be an expression and is stored as a literal).
module Sequent.Camunda.Validate
  ( validateCamunda
  ) where

import Data.Char (isDigit)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Sequent.Bpmn.Semantic
import Sequent.Camunda.Model
import Sequent.Diagnostic

validateCamunda :: Provenance -> SemanticGraph -> [Diagnostic]
validateCamunda prov g =
  sortDiagnostics $
    concatMap processDiags (sgProcesses g)
      ++ concatMap (messageDiags msgUsers) (sgMessages g)
  where
    processDiags p = concatMap (scopeDiags prov msgById) (allScopes (procScope p))
    msgById = Map.fromList [(msgId m, m) | m <- sgMessages g]
    -- A correlation key is only required for messages something waits for.
    msgUsers = Map.fromListWith (++) (concatMap catching (sgProcesses g))
    catching p =
      [ (mid, [fnId n])
      | sc <- allScopes (procScope p)
      , n <- scNodes sc
      , Just mid <- [waitingOn n]
      ]

    messageDiags users m
      | msgCorrelation m /= Nothing = []
      | not (Map.member (msgId m) users) = []
      | otherwise =
          [ withHint
              ("declare the key: message " <> msgName m <> " \"" <> msgName m <> "\" correlation \"=orderId\"")
              ( diagnostic
                  Warning
                  CamundaValidationError
                  ("message '" <> msgName m <> "' is caught but has no correlation key")
              )
          ]

-- | The message a node waits for, if it waits for one. A throwing event does
-- not need a correlation key; a catching one does.
waitingOn :: FlowNode -> Maybe NodeId
waitingOn n = case fnKind n of
  NkEvent (EventSpec fl (Just (EdMessage m)))
    | fl `elem` [EvStart, EvIntermediateCatch] -> Just m
  NkEvent (EventSpec (EvBoundary _) (Just (EdMessage m))) -> Just m
  NkActivity (Activity (AkTask (TtReceive (Just m))) _) -> Just m
  _ -> Nothing

scopeDiags :: Provenance -> Map NodeId MessageDef -> Scope -> [Diagnostic]
scopeDiags prov _msgs sc = concatMap nodeDiags (scNodes sc)
  where
    at i = spanOfNode prov i
    withSpan i d = maybe d (\x -> d {diagSpan = Just x}) (at i)
    err i msg = withSpan i (diagnostic Error CamundaValidationError msg)
    adv i msg = withSpan i (diagnostic Advisory CamundaValidationError msg)
    named n = "'" <> fromMaybe (unNodeId (fnId n)) (fnName n) <> "'"

    nodeDiags n = execDiags n (fnExec n) ++ loopDiags n ++ timerDiags n

    execDiags n meta = case meta of
      ExNone -> []
      ExService z ->
        [ withHint
            "Zeebe matches job workers on this string: type \"order-validate\""
            (err (fnId n) (named n <> " has an empty job type"))
        | T.null (T.strip (ztType z))
        ]
          ++ [ withHint
                 "retries must be positive; Zeebe treats 0 as an immediate incident"
                 (err (fnId n) (named n <> " has a non-positive retry count"))
             | Just r <- [ztRetries z]
             , r <= 0
             ]
          ++ concatMap (mappingDiags n) (ztInputs z ++ ztOutputs z)
      ExUser uu ->
        [ withHint
            "add a form, an assignee, or candidate groups so the task can be claimed"
            (adv (fnId n) (named n <> " is a user task with no form and no assignment"))
        | utForm uu == Nothing
        , utAssignee uu == Nothing
        , utCandidateGroups uu == Nothing
        , utCandidateUsers uu == Nothing
        ]
          ++ concatMap (mappingDiags n) (utInputs uu ++ utOutputs uu)
      ExScript s ->
        [ withHint "a script task stores its result in a variable: result score" (err (fnId n) (named n <> " has an empty script result variable"))
        | T.null (T.strip (scResult s))
        ]
          ++ concatMap (mappingDiags n) (scInputs s ++ scOutputs s)
      ExDecision d ->
        [ withHint "name the DMN decision to call: decision \"credit-scoring\"" (err (fnId n) (named n <> " has an empty decision id"))
        | T.null (T.strip (dsDecisionId d))
        ]
          ++ concatMap (mappingDiags n) (dsInputs d ++ dsOutputs d)
      ExCall c ->
        [ withHint "name the process to call: calls \"shipping-process\"" (err (fnId n) (named n <> " has an empty called process id"))
        | T.null (T.strip (ceProcessId c))
        ]
          ++ concatMap (mappingDiags n) (ceInputs c ++ ceOutputs c)

    mappingDiags n m =
      [ withHint
          "a mapping target is a variable name, not an expression"
          (err (fnId n) (named n <> " maps into '" <> mapTarget m <> "', which is not a variable name"))
      | not (isVariableName (mapTarget m))
      ]

    loopDiags n = case fnKind n of
      NkActivity (Activity _ (Just ls)) ->
        [ withHint
            "the loop element is a variable name: each item in \"=order.items\""
            (err (fnId n) (named n <> " has a multi-instance element that is not a variable name"))
        | not (isVariableName (lsInputElement ls))
        ]
      _ -> []

    timerDiags n = case fnKind n of
      NkEvent (EventSpec _ (Just (EdTimer t))) -> timerCheck n t
      _ -> []

    timerCheck n t = case t of
      TimerDuration v ->
        [ withHint "an ISO-8601 duration looks like PT15M or P1D" (err (fnId n) (named n <> " has a malformed timer duration " <> quoted v))
        | not (looksIso8601Duration v)
        ]
      TimerCycle v ->
        [ withHint "an ISO-8601 repeating cycle looks like R3/PT10M" (err (fnId n) (named n <> " has a malformed timer cycle " <> quoted v))
        | not (looksIso8601Cycle v)
        ]
      TimerDate v ->
        [ withHint "a timer date is an ISO-8601 instant like 2026-01-01T00:00:00Z, a duration like PT1H, or a cycle like R/PT1H" (err (fnId n) (named n <> " has a malformed timer date " <> quoted v))
        | not (looksIso8601Date v)
        ]

quoted :: Text -> Text
quoted t = "'" <> t <> "'"

-- | Zeebe variable names are FEEL identifiers.
isVariableName :: Text -> Bool
isVariableName t = case T.uncons t of
  Nothing -> False
  Just (c, rest) -> startOk c && T.all bodyOk rest
  where
    startOk c = c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    bodyOk c = startOk c || isDigit c

-- | @P[n]Y[n]M[n]DT[n]H[n]M[n]S@ — checked structurally rather than fully
-- parsed; the goal is to catch @"15m"@, not to reimplement ISO-8601.
looksIso8601Duration :: Text -> Bool
looksIso8601Duration v =
  T.isPrefixOf "P" v
    && T.length v > 1
    && T.all (\c -> isDigit c || c `elem` ("PYMDTHSW.," :: String)) v
    && T.any isDigit v

looksIso8601Cycle :: Text -> Bool
looksIso8601Cycle v = case T.stripPrefix "R" v of
  Nothing -> False
  Just rest ->
    let (reps, tl) = T.span isDigit rest
     in T.isPrefixOf "/" tl && looksIso8601Duration (T.drop 1 tl) && (T.null reps || T.all isDigit reps)

looksIso8601Date :: Text -> Bool
looksIso8601Date v =
  looksIso8601Duration v
    || looksIso8601Cycle v
    || (T.length v >= 10 && T.all (\c -> isDigit c || c `elem` ("-:TZ+." :: String)) v && T.count "-" v >= 2)
