-- | The @sequent@ command line: build, check, format, and inspect layout.
module Main (main) where

import Control.Monad (unless, when)
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Encoding.Error as TE
import qualified Data.Text.IO as TIO
import Options.Applicative
import System.Exit (exitFailure)
import System.FilePath (replaceExtension)
import System.IO
  ( Handle
  , hIsTerminalDevice
  , hPutStr
  , hSetEncoding
  , stderr
  , stdout
  , utf8
  )

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
main = do
  mapM_ utf8Output [stdout, stderr]
  run =<< execParser cli

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
    text <- readSource src
    let opts = defaultOptions {coEmitDi = not noDi, coStrictLayout = not lenient}
        res = compileText opts src text
    report src text (crDiagnostics res)
    case crXml res of
      Nothing -> exitFailure
      Just xml -> do
        let dest = fromMaybe (replaceExtension src ".bpmn") out
        writeGenerated dest xml
        putStrLn (src <> " -> " <> dest)
  Check src -> do
    text <- readSource src
    let ds = checkText src text
    report src text ds
    if hasErrors ds then exitFailure else putStrLn (src <> ": ok")
  Fmt src write -> do
    text <- readSource src
    case formatText src text of
      Left ds -> report src text ds >> exitFailure
      Right out -> if write then writeGenerated src out else TIO.putStr out
  Import src out -> do
    text <- readSource src
    let res = importText src text
    report src text (irDiagnostics res)
    case irSource res of
      Nothing -> exitFailure
      Just sq -> do
        case out of
          Nothing -> TIO.putStr sq
          Just dest -> do
            writeGenerated dest sq
            putStrLn (src <> " -> " <> dest)
        when (hasErrors (irDiagnostics res)) exitFailure
  Report src -> do
    text <- readSource src
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

-- Files ------------------------------------------------------------------------
--
-- Every file this program reads and writes is UTF-8, whatever the machine's
-- locale says. Trusting the locale is how a build on a Windows console produces
-- a @.bpmn@ whose declaration says @encoding="UTF-8"@ and whose bytes are
-- code page 1252 — or fails outright on the first accented label. The encoding
-- is a property of the format, so it is named here rather than inherited.

-- | Read a source file as text.
--
-- The byte order mark a Windows editor or a PowerShell redirection leaves in
-- front of the first character is not part of the program, so it is dropped
-- here; a UTF-16 file — what @>@ writes in Windows PowerShell 5 — is decoded
-- rather than reported as a file full of unexpected characters. Anything else
-- is UTF-8, decoded leniently so that one bad byte is one replacement
-- character in a diagnostic rather than an exception with no file name in it.
readSource :: FilePath -> IO Text
readSource path = decode <$> BS.readFile path
  where
    decode bs
      | Just rest <- BS.stripPrefix bomUtf8 bs = lenient rest
      | Just rest <- BS.stripPrefix bomUtf16le bs = TE.decodeUtf16LEWith TE.lenientDecode rest
      | Just rest <- BS.stripPrefix bomUtf16be bs = TE.decodeUtf16BEWith TE.lenientDecode rest
      | otherwise = lenient bs
    lenient = TE.decodeUtf8With TE.lenientDecode
    bomUtf8 = BS.pack [0xEF, 0xBB, 0xBF]
    bomUtf16le = BS.pack [0xFF, 0xFE]
    bomUtf16be = BS.pack [0xFE, 0xFF]

-- | Write a generated file as UTF-8, with no byte order mark.
writeGenerated :: FilePath -> Text -> IO ()
writeGenerated path = BS.writeFile path . TE.encodeUtf8

-- | Make a redirected stream UTF-8.
--
-- Only when it is redirected: a console keeps whatever encoding the runtime
-- chose for it, which on Windows is the one that can actually render to the
-- screen. A file or a pipe gets UTF-8, so that @sequent import x.bpmn > x.sq@
-- writes the same bytes as @--output@ would.
utf8Output :: Handle -> IO ()
utf8Output h = do
  tty <- hIsTerminalDevice h
  unless tty (hSetEncoding h utf8)

report :: FilePath -> Text -> [Diagnostic] -> IO ()
report src text ds =
  unless (null ds) (hPutStr stderr (T.unpack (renderDiagnostics src text ds)))

tshow :: Show a => a -> Text
tshow = T.pack . show
