{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}
{-# LANGUAGE CPP, FlexibleInstances, UnboxedTuples, MagicHash #-}

module DebuggerImpl where

import GHC hiding (resume, back, forward)
import qualified GHC (resume, back, forward)
import qualified InteractiveEval
import GHC.Paths ( libdir )
import DynFlags
import GhcMonad (liftIO)

import ParserMonad (parse)
import CommandParser (debugCommand, DebugCommand(..))
import CmdArgsParser (cmdArgument, Argument(..))
import DebuggerMonad

import Network.Socket
import Network.BSD

import System.IO
import System.Environment (getArgs)
import Control.Monad (mplus, liftM)
import Data.List (partition, sortBy)
import BreakArray
import Data.Array
import Data.Function (on)
import SrcLoc (realSrcSpanEnd)

import Data.Maybe
import DebuggerUtils

import Debugger ()

import PprTyThing

import GHC.Exts()

---- || Debugger runner || --------------------------------------------------------------------------

tryRun :: DebuggerMonad (Result, Bool) -> DebuggerMonad (Result, Bool)
tryRun func = func `catch`
    (\ex -> return ([
            ("info", ConsStr "exception"),
            ("message", ConsStr $ show ex)
        ], False))


-- |Runs Ghc program with default settings
defaultRunGhc :: DebuggerMonad a -> IO ()
defaultRunGhc program = defaultErrorHandler defaultFatalMessager defaultFlushOut $ runGhc (Just libdir) $
    startDebugger (do
        handleArguments
        st <- getDebugState
        modulePath <- do
            case (mainFile st) of
                Just path -> return path
                Nothing   -> error "Main module not specified"
        setupContext modulePath "Main"
        initDebugOutput
        initInterpBuffering
        turnOffBuffering -- turns off buffering of stdout and stderr of program
        program
        return ()
    ) initState

-- |Setup needed flags before running debug program
setupContext :: String -> String -> DebuggerMonad ()
setupContext pathToModule nameOfModule = do
    dflags <- getSessionDynFlags
    setSessionDynFlags $ dflags { hscTarget = HscInterpreted
                                , ghcLink   = LinkInMemory
                                , ghcMode   = CompManager
                                }
    setTargets =<< sequence [guessTarget pathToModule Nothing]
    GHC.load LoadAllTargets
    setContext [IIModule $ mkModuleName nameOfModule]
    return ()

handleArguments :: DebuggerMonad ()
handleArguments = do
    args <- liftIO getArgs
    mapM_ handle' args where
        handle' x = do
            let arg = fst $ head $ parse cmdArgument x
            case arg of
                Main m    -> modifyDebugState $ \st -> st{mainFile = Just m}
                Import path -> do
                    dflags <- getSessionDynFlags
                    setSessionDynFlags dflags{importPaths = path : importPaths dflags}
                    return ()
                SetPort p -> modifyDebugState $ \st -> st{port = Just p}
                ExposePkg pkg -> do
                    dflags <- getSessionDynFlags
                    setSessionDynFlags dflags{packageFlags = ExposePackage (PackageArg pkg) (ModRenaming False []) : packageFlags dflags}
                    return ()
                CmdArgsParser.Unknown s -> printJSON [
                        ("info", ConsStr "warning"),
                        ("message", ConsStr $ "unknown argument: " ++ s)
                    ]

initDebugOutput :: DebuggerMonad ()
initDebugOutput = do
    st <- getDebugState
    let m_port = port st
    case m_port of
        Nothing -> printJSON [
                ("info", ConsStr "warning"),
                ("message", ConsStr "Port for debug stream was not set (using stdout); use command line argument -p<port> to set it")
            ]
        Just port' -> do
            let host = "localhost"
            sock <- liftIO $ socket AF_INET Stream 0
            addrs <- liftIO $ liftM hostAddresses $ getHostByName host
            do {
                liftIO $ connect sock $ SockAddrInet (toEnum port') (head addrs);
                handle <- liftIO $ socketToHandle sock ReadWriteMode;
                modifyDebugState $ \st' -> st'{debugOutput = handle};
                printJSON [
                        ("info", ConsStr "connected to port"),
                        ("port", ConsInt port')
                    ];
            } `catch` (\ex -> printJSON [
                        ("info", ConsStr "exception"),
                        ("message", ConsStr $ show ex ++ "; using stdout for debug output")
                    ])

-- |In loop waits for commands and executes them
startCommandLine :: DebuggerMonad ()
startCommandLine = whileNot $ do
    command <- getCommand stdin `catch` (const $ return Exit)
    result <- tryRun (runCommand command)
    printJSON $ fst result
    return $ snd result

whileNot :: DebuggerMonad Bool -> DebuggerMonad ()
whileNot p = do
    x <- p
    if not x then whileNot p else return ()

-- |Translates line from input stream into DebugCommand
getCommand :: Handle -> DebuggerMonad DebugCommand
getCommand handle_ = do
    line <- liftIO $ hGetLine handle_
    return $ fst $ head $ parse debugCommand line

type Result = [(String, T)]

-- |Runs DebugCommand and returns True iff debug is finished
-- Inside commands there should not be any output to debug stream
runCommand :: DebugCommand -> DebuggerMonad (Result, Bool)
runCommand (SetBreakpoint modName line)   = notEnd $ setBreakpointLikeGHCiDo modName line
runCommand (SetBreakByIndex modName ind)  = notEnd $ doBreakindex modName ind
runCommand (RemoveBreakpoint modName ind) = notEnd $ deleteBreakpoint modName ind
runCommand (Trace command)                = doTrace command
runCommand Resume                         = doResume
runCommand StepInto                       = doStepInto
runCommand StepOver                       = doStepLocal
runCommand History                        = notEnd $ showHistory defaultHistSize
runCommand Back                           = notEnd $ back
runCommand Forward                        = notEnd $ forward
runCommand Exit                           = return ([], True)
runCommand (BreakList modName)            = notEnd $ showBreaks modName
runCommand (LineBreakList modName line)   = notEnd $ showBreaksForLine modName line
runCommand Help                           = printString fullHelpText >> return ([], False)
runCommand (SPrint name)                  = notEnd $ doSPrint name
runCommand (Force expr)                   = notEnd $ doForce expr
runCommand (ExprType expr)                = notEnd $ getExprType expr
runCommand (Evaluate force expr)          = notEnd $ evaluate force expr
runCommand (Set flag)                     = notEnd $ set flag
runCommand (Unset flag)                   = notEnd $ unset flag
runCommand BreakinfoCmd                   = notEnd $ doBreakinfo
runCommand _                              = return ([
                                                ("info", ConsStr "exception"),
                                                ("message", ConsStr "unknown command")
                                            ], False)

notEnd :: DebuggerMonad Result -> DebuggerMonad (Result, Bool)
notEnd obj = obj >>= (\x -> return (x, False))

-- | setBreakpoint version with selector just taking first of avaliable breakpoints
setBreakpointFirstOfAvailable :: String -> Int -> DebuggerMonad Result
setBreakpointFirstOfAvailable modName line = setBreakpoint modName line (Just . head)

-- | setBreakpoint version with selector choosing
-- |   - the leftmost complete subexpression on the specified line, or
-- |   - the leftmost subexpression starting on the specified line, or
-- |   - the rightmost subexpression enclosing the specified line
-- | This strategy is the same to one GHCi currently uses
setBreakpointLikeGHCiDo :: String -> Int -> DebuggerMonad Result
setBreakpointLikeGHCiDo modName line = setBreakpoint modName line selectOneOf
    where selectOneOf :: [(BreakIndex, SrcSpan)] -> Maybe (BreakIndex, SrcSpan)
          selectOneOf breaks_ = listToMaybe (sortBy (leftmost_largest `on` snd)  onelineBreaks) `mplus`
                                listToMaybe (sortBy (leftmost_smallest `on` snd) multilineBreaks) `mplus`
                                listToMaybe (sortBy (rightmost `on` snd) breaks_)
            where (onelineBreaks, multilineBreaks) = partition endEqLine breaksWithStartEqLine
                  endEqLine (_, RealSrcSpan r) = GHC.srcSpanEndLine r == line
                  endEqLine _ = False
                  breaksWithStartEqLine = [ br | br@(_, srcSpan) <- breaks_,
                                            case srcSpan of (RealSrcSpan r) -> GHC.srcSpanStartLine r == line; _ -> False ]

-- | finds all avaliable breakpoint for given line, then using selector takes one of them and activates it
-- | if no breaks are avaliable proper message is shown
setBreakpoint :: String -> Int -> ([(BreakIndex, SrcSpan)] -> Maybe (BreakIndex, SrcSpan)) -> DebuggerMonad Result
setBreakpoint modName line selector = do
    breaksForLine <- findBreaksForLine modName line
    case breaksForLine of 
        []           -> return [
                                ("info", ConsStr "breakpoint was not set"),
                                ("add_info", ConsStr "not allowed here")
                            ]
        bbs@(b : bs) -> do
            let mbBreakToSet = if (null bs) then Just b else selector bbs
            case mbBreakToSet of
                Just (breakIndex, srcSpan) -> do
                    res <- changeBreakFlagInModBreaks modName breakIndex True
--                    let msg = if res then "# Breakpoint (index = "++ show breakIndex ++") was set here:\n" ++ show srcSpan
--                              else "# Breakpoint was not set: setBreakOn returned False"
                    if res
                        then return [
                                ("info", ConsStr "breakpoint was set"),
                                ("index", ConsInt $ breakIndex),
                                ("src_span", srcSpanAsJSON srcSpan)
                            ]
                        else return [
                                ("info", ConsStr "breakpoint was not set"),
                                ("add_info", ConsStr "selector returned Nothing")
                            ]
                Nothing -> return [
                                ("info", ConsStr "breakpoint was not set"),
                                ("add_info", ConsStr "selector returned Nothing")
                            ]

-- | sets breakpoint by index
doBreakindex :: String -> Int -> DebuggerMonad Result
doBreakindex modName breakIndex = do
    modBreaks <- getModBreaks modName
    let locs = modBreaks_locs modBreaks
    let (start, end) = bounds locs
    case start <= breakIndex && breakIndex <= end of
        True -> do
            res <- changeBreakFlagInModBreaks modName breakIndex True
            if res
                then return [
                        ("info", ConsStr "breakpoint was set"),
                        ("index", ConsInt $ breakIndex),
                        ("src_span", srcSpanAsJSON $ locs ! breakIndex)
                            ]
                else return [
                        ("info", ConsStr "breakpoint was not set"),
                        ("add_info", ConsStr "setBreakFlag returned False")
                            ]
        False -> do
            return [ ("info", ConsStr "breakpoint was not set"), ("add_info", ConsStr "wrong index") ]

-- | returns list of (BreakIndex, SrcSpan) for moduleName, where each element satisfies: srcSpanStartLine == line
-- | todo: this function is very suboptimal, it is temporary decition
findBreaksForLine :: String -> Int -> DebuggerMonad [(BreakIndex, SrcSpan)]
findBreaksForLine modName line = filterBreaksLocations modName predLineEq
    where predLineEq = \(_, srcSpan) -> case srcSpan of UnhelpfulSpan _ -> False
                                                        RealSrcSpan r   -> line == (srcSpanStartLine r)

-- | returns list of (BreakIndex, SrcSpan) for moduleName, where each element satisfies: srcSpanStartLine <= line <= srcSpanEndLine
-- | todo: this function is very suboptimal, it is temporary decition
findBreaksContainingLine :: String -> Int -> DebuggerMonad [(BreakIndex, SrcSpan)]
findBreaksContainingLine modName line = filterBreaksLocations modName predLineEq
    where predLineEq = \(_, srcSpan) -> case srcSpan of UnhelpfulSpan _ -> False
                                                        RealSrcSpan r   -> (srcSpanStartLine r) <= line && line <= (srcSpanEndLine r)

-- | returns list of (BreakIndex, SrcSpan) for moduleName, where each element satisfies predicate
filterBreaksLocations :: String -> ((BreakIndex, SrcSpan) -> Bool) -> DebuggerMonad [(BreakIndex, SrcSpan)]
filterBreaksLocations modName predicate = do
    modBreaks <- getModBreaks modName
    let breaksLocations = assocs $ modBreaks_locs modBreaks
    return $ filter predicate breaksLocations

-- | get ModBreaks for given modulename
getModBreaks :: String -> DebuggerMonad ModBreaks
getModBreaks modName = do
    module_ <- GHC.lookupModule (mkModuleName modName) Nothing
    Just modInfo <- getModuleInfo module_
    return $ modInfoModBreaks modInfo

-- | modBreaks_flags of ModBreaks contains info about set and unset breakpoints for specified module
-- | This function just set or unset given flag
changeBreakFlagInModBreaks :: String -> Int -> Bool -> DebuggerMonad Bool
changeBreakFlagInModBreaks modName flagIndex flagValue = do
    modBreaks <- getModBreaks modName
    dflags <- GHC.getSessionDynFlags
    let breaksFlags = modBreaks_flags modBreaks
    liftIO $ setBreakFlag dflags breaksFlags flagIndex flagValue

setBreakFlag :: DynFlags -> BreakArray -> Int -> Bool -> IO Bool
setBreakFlag dynFlags bArr ind flag | flag      = setBreakOn dynFlags bArr ind
                                    | otherwise = setBreakOff dynFlags bArr ind

-- | ':delete <module name> <break index>' command
deleteBreakpoint ::  String -> Int -> DebuggerMonad Result
deleteBreakpoint modName breakIndex = do
    res <- changeBreakFlagInModBreaks modName breakIndex False
    if res
        then return [
                ("info", ConsStr "breakpoint was removed"),
                ("index", ConsInt breakIndex)
            ]
        else return [
                ("info", ConsStr "breakpoint was not removed"),
                ("add_info", ConsStr "incorrect index")
            ]

-- | ':trace' command
doTrace :: String -> DebuggerMonad (Result, Bool)
doTrace []   = doContinue (const True) GHC.RunAndLogSteps
doTrace expr = do
    runResult <- GHC.runStmt expr GHC.RunAndLogSteps `catch`
        (\ex -> (liftIO $ hPutStrLn stderr $ show ex) >> (return $ GHC.RunOk []))
    afterRunStmt (const True) runResult

doContinue :: (SrcSpan -> Bool) -> SingleStep -> DebuggerMonad (Result, Bool)
doContinue canLogSpan step = do
    runResult <- GHC.resume canLogSpan step
    afterRunStmt canLogSpan runResult

afterRunStmt :: (SrcSpan -> Bool) -> GHC.RunResult -> DebuggerMonad (Result, Bool)
afterRunStmt canLogSpan (GHC.RunException e) = do
    liftIO $ hPutStrLn stderr (show e)
    afterRunStmt canLogSpan (GHC.RunOk [])
afterRunStmt canLogSpan runResult = do
    -- flushInterpBuffers -- it's not needed to flush because buffering is disabled
    resumes <- GHC.getResumeContext
    case runResult of
        GHC.RunOk names -> do
            names_str <- mapM showOutputable names
            let res = [
                        ("info", ConsStr "finished"),
                        ("names", ConsArr $ map ConsStr names_str)
                    ]
            return (res, False)
        GHC.RunBreak _ names mbBreakInfo
            | isNothing  mbBreakInfo || canLogSpan (GHC.resumeSpan $ head resumes) -> do
                let srcSpan = GHC.resumeSpan $ head resumes
                    apStack = InteractiveEval.resumeApStack $ head resumes
                --liftIO $ c_print_ap_stack (Ptr (unsafeCoerce# apStack))
                functionName <- getFunctionName mbBreakInfo
                vars <- getNamesInfo names
                let res = [
                            ("info", ConsStr "paused"),
                            ("src_span", srcSpanAsJSON srcSpan),
                            ("function", ConsStr functionName),
                            ("vars", vars)
                        ]
                return (res, False)
            | otherwise -> do
                nextRunResult <- GHC.resume canLogSpan GHC.SingleStep
                afterRunStmt canLogSpan nextRunResult
        _ -> return ([
                ("info", ConsStr "warning"),
                ("message", ConsStr "Unknown RunResult")
            ], False)
        where
            getFunctionName :: Maybe BreakInfo -> DebuggerMonad String
            getFunctionName Nothing = return ""
            getFunctionName (Just breakInfo) = do
                Just modInfo <- getModuleInfo $ breakInfo_module breakInfo
                let modBreaks = modInfoModBreaks modInfo
                let allDecls = modBreaks_decls $ modBreaks
                return $ last (allDecls ! (breakInfo_number breakInfo))

-- | ':continue' command
doResume :: DebuggerMonad (Result, Bool)
doResume = doContinue (const True) GHC.RunToCompletion

-- |':step [<expr>]' command - general step command
doStepGeneral :: String -> DebuggerMonad (Result, Bool)
doStepGeneral []   = doContinue (const True) GHC.SingleStep
doStepGeneral _ = return ([
         ("info", ConsStr "exception"),
         ("message", ConsStr "not implemented yet")
     ], False)

-- |':step' command
doStepInto :: DebuggerMonad (Result, Bool)
doStepInto = doStepGeneral []

-- | ':steplocal' command
doStepLocal :: DebuggerMonad (Result, Bool)
doStepLocal = do
    mbSrcSpan <- getCurrentBreakSpan
    case mbSrcSpan of
        Nothing  -> doStepInto
        Just srcSpan -> do
            Just module_ <- getCurrentBreakModule
            mbCurrentToplevelDecl <- enclosingSpan module_ srcSpan
            case mbCurrentToplevelDecl of
                Nothing -> return ([
                        ("info", ConsStr "warning"),
                        ("message", ConsStr "steplocal was not performed: enclosingSpan returned Nothing")
                    ], False)
                Just currentToplevelDecl -> doContinue (`isSubspanOf` currentToplevelDecl) GHC.SingleStep

-- | Returns the largest SrcSpan containing the given one or Nothing
enclosingSpan :: Module -> SrcSpan -> DebuggerMonad (Maybe SrcSpan)
enclosingSpan _ (UnhelpfulSpan _) = return Nothing
enclosingSpan module_ (RealSrcSpan rSrcSpan) = do
    let line = srcSpanStartLine rSrcSpan
    breaks_ <- findBreaksContainingLine (moduleNameString $ moduleName module_) line
    case breaks_ of
        [] -> return Nothing
        bs -> return . Just . head . sortBy leftmost_largest $ enclosingSpans bs
        where
            enclosingSpans bs = [ s | (_, s) <- bs, case s of UnhelpfulSpan _ -> False
                                                              RealSrcSpan r   -> realSrcSpanEnd r >= realSrcSpanEnd rSrcSpan ]


getCurrentBreakSpan :: DebuggerMonad (Maybe SrcSpan)
getCurrentBreakSpan = do
  resumes <- GHC.getResumeContext
  case resumes of
    [] -> return Nothing
    (r:_) -> do
        let ix = GHC.resumeHistoryIx r
        if ix == 0
           then return (Just (GHC.resumeSpan r))
           else do
                let hist = GHC.resumeHistory r !! (ix-1)
                pan <- GHC.getHistorySpan hist
                return (Just pan)


getNamesInfo :: [Name] -> DebuggerMonad T
getNamesInfo names = do
    let namesSorted = sortBy compareNames names
    alltythings <- catMaybes `liftM` mapM GHC.lookupName namesSorted
    let tythings = [AnId i | AnId i <- alltythings]
    names' <- mapM getThingName tythings
    types <- mapM getThingType tythings
    values <- mapM getThingValue tythings

    return $ ConsArr $ map (\(n, t, v) -> ConsObj [
            ("name", ConsStr n),
            ("type", ConsStr t),
            ("value", ConsStr v)
        ]) (zip3 names' types values)
        where
            getThingName :: TyThing -> DebuggerMonad (String)
            getThingName = showOutputable . getName

            getThingType :: TyThing -> DebuggerMonad (String)
            getThingType (AnId id') = do
                showSDoc $ pprTypeForUser (GHC.idType id')
            getThingType _ = fail "Shouldn't be here"

            getThingValue :: TyThing -> DebuggerMonad (String)
            getThingValue (AnId id') = do
                term <- GHC.obtainTermFromId 100 False id'
                showOutputable term
            getThingValue _ = fail "Shouldn't be here"


getCurrentBreakModule :: DebuggerMonad (Maybe Module)
getCurrentBreakModule = do
    mbBreakInfo <- getCurrentBreakInfo
    return $ GHC.breakInfo_module `liftM` mbBreakInfo


getCurrentBreakInfo :: DebuggerMonad (Maybe BreakInfo)
getCurrentBreakInfo = do
    resumes <- GHC.getResumeContext
    case resumes of
        [] -> return Nothing
        (r:_) -> do
            let ix = GHC.resumeHistoryIx r
            if ix == 0
               then return $ GHC.resumeBreakInfo r
               else do
                    let hist = GHC.resumeHistory r !! (ix-1)
                    return $ Just $ GHC.historyBreakInfo hist

-- | ':breakinfo' debugCommand
doBreakinfo :: DebuggerMonad Result
doBreakinfo = do
    mbBreakInfo <- getCurrentBreakInfo
    case mbBreakInfo of
        Nothing        -> printString "# No break info available"
        Just breakInfo -> printOutputable breakInfo
    return []

-- | ':history' command
showHistory :: Int -> DebuggerMonad Result
showHistory num = do
    resumes <- GHC.getResumeContext
    case resumes of
        [] -> return [("info", ConsStr "not stopped at breakpoint")]
        (r:_) -> do
            let hist = resumeHistory r
                (took, rest) = splitAt num hist
            spans' <- mapM (GHC.getHistorySpan) took
            let idx = map (0-) [(1::Int) ..]
                -- todo: get full path of the file
                lines' = map (\(i, s, h) -> ConsObj [
                        ("index", ConsInt i),
                        ("function", (ConsStr . head . GHC.historyEnclosingDecls) h),
                        ("src_span", srcSpanAsJSON s)
                    ]) (zip3 idx spans' hist)
            return [
                    ("info", ConsStr "got history"),
                    ("history", ConsArr lines'),
                    ("end_reached", ConsBool (null rest))
                ]

-- | ':breaklist <mod>' command
showBreaks :: String -> DebuggerMonad Result
showBreaks modName = do
    modBreaks <- getModBreaks modName
    let locs = assocs $ modBreaks_locs $ modBreaks
    return [
            ("info", ConsStr "break list"),
            ("breaks", ConsArr $ map (\(i, e) -> ConsObj [
                    ("index", ConsInt i),
                    ("src_span", srcSpanAsJSON e)
                ]) locs)
        ]

-- | ':breaklist <mod> <line>' command
showBreaksForLine :: String -> Int -> DebuggerMonad Result
showBreaksForLine modName line = do
    breaksInfo <- findBreaksForLine modName line
    return [
            ("info", ConsStr $ "break list for line"),
            ("line", ConsStr $ show line),
            ("breaks",
             ConsArr $ map (\(i, e) -> ConsObj [("index", ConsInt i), ("src_span", srcSpanAsJSON e)]) breaksInfo)
           ]

-- | ':sprint' and ':force' commands
doSPrint, doForce :: String -> DebuggerMonad Result
doSPrint = evaluate False
doForce  = evaluate True

getExprType :: String -> DebuggerMonad Result
getExprType expr = do
    ty <- GHC.exprType expr
    doc <- showSDoc $ pprTypeForUser ty
    return [
            ("info", ConsStr "expression type"),
            ("type", ConsStr doc)
        ]

-- | ":eval"
evaluate :: Bool -> String -> DebuggerMonad Result
evaluate force str = do
    -- it seems that __evalResult is not stored after evaluating, so it is safe to do such binding
    RunOk [name] <- GHC.runStmt ("let __evalResult = " ++ str) GHC.RunToCompletion
    Just (AnId id') <- GHC.lookupName name
    type' <- showSDoc $ pprTypeForUser (GHC.idType id')
    term <- GHC.obtainTermFromId 100 force id'
    value <- showOutputable term
    return [
            ("info", ConsStr "evaluated"),
            ("type", ConsStr type'),
            ("value", ConsStr value)
        ]

-- | ":back"
back :: DebuggerMonad Result
back = do
    (names, _, pan) <- GHC.back
    names_str <- mapM showOutputable names
    evs <- mapM (evaluate False) names_str
    return [
            ("info", ConsStr "stepped back"),
            ("src_span", srcSpanAsJSON pan),
            ("vars", ConsArr $ map (\(name, [_, (_, ConsStr ty), (_, ConsStr val)]) -> ConsObj [
                    ("name", ConsStr name),
                    ("type", ConsStr ty),
                    ("value", ConsStr val)
                ]) (zip names_str evs))
        ]

-- | ":forward"
forward :: DebuggerMonad Result
forward = do
    (names, ix, pan) <- GHC.forward
    names_str <- mapM showOutputable names
    evs <- mapM (evaluate False) names_str
    return [
            ("info", ConsStr "stepped forward"),
            ("src_span", srcSpanAsJSON pan),
            ("vars", ConsArr $ map (\(name, [_, (_, ConsStr ty), (_, ConsStr val)]) -> ConsObj [
                    ("name", ConsStr name),
                    ("type", ConsStr ty),
                    ("value", ConsStr val)
                ]) (zip names_str evs)),
            ("hist_top", ConsBool (ix == 0))
        ]

set :: String -> DebuggerMonad Result
set flag = do
    case flag of
        "-fbreak-on-error" -> do
            dflags <- GHC.getSessionDynFlags
            let dflags' = DynFlags.gopt_set dflags DynFlags.Opt_BreakOnError
                dflags'' = DynFlags.gopt_unset dflags' DynFlags.Opt_BreakOnException
            GHC.setSessionDynFlags dflags''
            return [("info", ConsStr "break set")]
        "-fbreak-on-exception" -> do
            dflags <- GHC.getSessionDynFlags
            let dflags' = DynFlags.gopt_set dflags DynFlags.Opt_BreakOnException
                dflags'' = DynFlags.gopt_unset dflags' DynFlags.Opt_BreakOnError
            GHC.setSessionDynFlags dflags''
            return [("info", ConsStr "break set")]
        _ -> return [("info", ConsStr "exception"), ("message", ConsStr "Unknown \"set\" flag")]

unset :: String -> DebuggerMonad Result
unset flag = do
    case flag of
        "-fbreak-on-error" -> unsetBreak
        "-fbreak-on-exception" -> unsetBreak
        _ -> return [("info", ConsStr "exception"), ("message", ConsStr "Unknown \"unset\" flag")]
        where
            unsetBreak = do
                dflags <- GHC.getSessionDynFlags
                let dflags' = DynFlags.gopt_unset dflags DynFlags.Opt_BreakOnException
                    dflags'' = DynFlags.gopt_unset dflags' DynFlags.Opt_BreakOnError
                GHC.setSessionDynFlags dflags''
                return [("info", ConsStr "break unset")]


fullHelpText :: String
fullHelpText =
    " Commands available from the prompt:\n" ++
    " -- Commands for debugging:\n" ++
    "\n" ++
    "   :break <mod> <l>            set a breakpoint for module <mod> at the line <l>\n" ++
    "   :breakindex <mod> <i>       set a breakpoint with index <i> for module <mod>\n" ++
    "   :breaklist <mod>            show all available breakpoints (index and span) for module <mod>\n" ++
    "   :breaklist <mod> <l>        show all breakpoints containing line <l> for module <mod> and \n" ++
    "   :continue                   resume after a breakpoint\n" ++
    "   :delete <mod> <ind>         delete the breakpoint with index <ind> from module <mod>\n" ++
    "   :force <expr>               print <expr>, forcing unevaluated parts\n" ++
    "   :history                    after :trace, show the execution history\n" ++
    "   :sprint <name>              prints a value without forcing its computation\n" ++
    "   :step                       single-step after stopping at a breakpoint\n" ++
    "   :steplocal                  single-step within the current top-level binding\n" ++
    "   :trace <expr>               evaluate <expr> with tracing on (see :history)\n" ++
    "   :type <expr>                show the type of <expr>\n" ++
    "   :eval <int> <expr>          evaluates <expr> ((<int> > 0) => forced evaluation)\n" ++
    "   :set <flag>                 sets given DynFlag\n" ++
    "   :unset <flag>               unsets given DynFlag\n" ++
    "      available flags: -fbreak-on-error, -fbreak-on-exception\n" ++
    "   :breakinfo                  pretty printing for current BreakInfo\n" ++
    "   :q                          exit debugger\n"

---- || Hardcoded parameters (temporary for testing) || -----------------

-- |Default history size
defaultHistSize :: Int
defaultHistSize = 20


---- || Utils || -------------------------------------------------------

-- | Shows info from ModBreaks for given moduleName. It is useful for debuging of our debuger = )
printAllBreaksInfo :: String -> DebuggerMonad ()
printAllBreaksInfo modName = do
    modBreaks <- getModBreaks modName
    -- modBreaks_flags - 0 if unset 1 if set
    printString "# modBreaks_flags:"
    dynFlags <- getSessionDynFlags
    liftIO $ showBreakArray dynFlags $ modBreaks_flags $ modBreaks
    -- modBreaks_locs - breakpoint index and SrcSpan
    printString "# modBreaks_locs:"
    mapM (\(i, e) -> printString (show i ++ " : " ++ show e)) $ assocs $ modBreaks_locs $ modBreaks
    -- modBreaks_decls - An array giving the names of the declarations enclosing each breakpoint
    printString "# modBreaks_decls:"
    mapM (\(i, ds) -> printString (show i ++ " : " ++ show ds)) $ assocs $ modBreaks_decls $ modBreaks
    return ()

-- | parse and execute commands in list (to auto tests)
-- | exapmle: main = defaultRunGhc $ execCommands [":trace main", ":q"] - load default module, make trace and exit
execCommands :: [String] -> DebuggerMonad ()
execCommands []       = return ()
execCommands (c : cs) = do
    result <- tryRun (runCommand $ fst $ head $ parse debugCommand c)
    printJSON $ fst result
    execCommands cs