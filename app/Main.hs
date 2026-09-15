-- | The @sequent@ command line: build, check, format, and inspect layout.
module Main (main) where

import Control.Monad (unless, when)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Options.Applicative
import System.Exit (exitFailure)
import System.FilePath (replaceExtension)
import System.IO (hPutStr, stderr)

import Sequent.Compiler
import Sequent.Diagnostic
import Sequent.Layout (LayoutResult (..))
import Sequent.Layout.Rules (Rule (..), ruleRegistry)
import Sequent.Layout.Score (Score (..))
import Sequent.Layout.Types (Violation (..), orderViolations)

data Command
  = Build FilePath (Maybe FilePath) Bool Bool
  | Check FilePath
  | Fmt FilePath Bool
  | Report FilePath
  | Import FilePath (Maybe FilePath)
  | Rules

main :: IO ()
main = run =<< execParser cli

cli :: ParserInfo Command
cli =
  info
    (commands <**> helper)
    ( fullDesc
        <> header "sequent - a declarative process language compiled to Camunda 8 BPMN"
        <> progDesc
          "A .sq file is the canonical source representation; the .bpmn is a derived  \
          \artifact obtained by deterministic compilation, with canonical identifiers, \
          \canonical XML, and a geometric realization induced by the layout rules."
    )

commands :: Parser Command
commands =
  hsubparser
    ( command "build" (info buildCmd (progDesc "compile a .sq file to .bpmn"))
        <> command "check" (info checkCmd (progDesc "report diagnostics without writing output"))
        <> command "fmt" (info fmtCmd (progDesc "print the file in canonical form"))
        <> command "report" (info reportCmd (progDesc "print the layout quality report"))
        <> command "import" (info importCmd (progDesc "read a .bpmn file and write the .sq that produces it"))
        <> command "rules" (info (pure Rules) (progDesc "list the implemented specification rules"))
    )
  where
    buildCmd =
      Build
        <$> sourceArg
        <*> optional
          ( strOption
              ( long "output"
                  <> short 'o'
                  <> metavar "FILE"
                  <> help "where to write the BPMN (default: the source with a .bpmn extension)"
              )
          )
        <*> switch (long "no-di" <> help "omit the diagram, emitting semantics only")
        <*> switch (long "lenient" <> help "downgrade hard layout violations to advisories")
    checkCmd = Check <$> sourceArg
    fmtCmd = Fmt <$> sourceArg <*> switch (long "write" <> short 'w' <> help "rewrite the file in place")
    reportCmd = Report <$> sourceArg
    importCmd =
      Import
        <$> strArgument (metavar "FILE" <> help "a .bpmn file")
        <*> optional
          ( strOption
              ( long "output"
                  <> short 'o'
                  <> metavar "FILE"
                  <> help "where to write the source (default: stdout)"
              )
          )
    sourceArg = strArgument (metavar "FILE" <> help "a .sq source file")

run :: Command -> IO ()
run cmd = case cmd of
  Rules -> mapM_ (TIO.putStrLn . describeRule) ruleRegistry
  Build src out noDi lenient -> do
    text <- TIO.readFile src
    let opts = defaultOptions {coEmitDi = not noDi, coStrictLayout = not lenient}
        res = compileText opts src text
    report src text (crDiagnostics res)
    case crXml res of
      Nothing -> exitFailure
      Just xml -> do
        let dest = fromMaybe (replaceExtension src ".bpmn") out
        TIO.writeFile dest xml
        putStrLn (src <> " -> " <> dest)
  Check src -> do
    text <- TIO.readFile src
    let ds = checkText src text
    report src text ds
    if hasErrors ds then exitFailure else putStrLn (src <> ": ok")
  Fmt src write -> do
    text <- TIO.readFile src
    case formatText src text of
      Left ds -> report src text ds >> exitFailure
      Right out -> if write then TIO.writeFile src out else TIO.putStr out
  Import src out -> do
    text <- TIO.readFile src
    let res = importText src text
    report src text (irDiagnostics res)
    case irSource res of
      Nothing -> exitFailure
      Just sq -> do
        case out of
          Nothing -> TIO.putStr sq
          Just dest -> do
            TIO.writeFile dest sq
            putStrLn (src <> " -> " <> dest)
        when (hasErrors (irDiagnostics res)) exitFailure
  Report src -> do
    text <- TIO.readFile src
    let res = compileText (defaultOptions {coStrictLayout = False}) src text
    report src text (crDiagnostics res)
    case crLayout res of
      Nothing -> exitFailure
      Just l -> do
        TIO.putStrLn ("score " <> tshow (round (scTotal (lrScore l)) :: Int))
        mapM_ (TIO.putStrLn . term) (filter ((> 0) . snd) (scTerms (lrScore l)))
        let vs = orderViolations (lrViolations l)
        unless (null vs) (TIO.putStrLn "")
        mapM_ (TIO.putStrLn . violationLine) vs
        when (hasErrors (crDiagnostics res)) exitFailure
  where
    term (n, v) = "  " <> n <> " " <> tshow (round v :: Int)
    violationLine v =
      "  "
        <> T.justifyLeft 12 ' ' (unRuleId (vRule v))
        <> T.pack (show (vTier v))
        <> "  "
        <> vMessage v

describeRule :: Rule -> Text
describeRule r =
  T.intercalate
    "  "
    [ T.justifyLeft 10 ' ' (unRuleId (ruleId r))
    , T.justifyLeft 6 ' ' (T.pack (show (rulePriority r)))
    , T.pack (show (ruleTier r))
    , T.justifyLeft 56 ' ' (ruleSummary r)
    , ruleImpl r
    ]

report :: FilePath -> Text -> [Diagnostic] -> IO ()
report src text ds =
  unless (null ds) (hPutStr stderr (T.unpack (renderDiagnostics src text ds)))

tshow :: Show a => a -> Text
tshow = T.pack . show
