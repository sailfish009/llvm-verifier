{- |
Module           : $Header$
Description      : Debugger implementation for LSS
License          : BSD3
Stability        : provisional
Point-of-contact : acfoltzer, jhendrix

Debugger for the LLVM Symbolic Simulator. This module provides
implementations of the 'SEH' event handlers. Commands and their
semantics are loosely based on gdb.

-}

{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGe PatternGuards #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE CPP #-}
module Verifier.LLVM.Debugger
  ( initializeDebugger
  , addBreakpoint
  , breakOnEntry
  , resetInterrupt
  , checkForBreakpoint
  ) where

import Control.Applicative ((<**>))
import Control.Monad
import qualified Control.Monad.Catch as E
import Control.Exception ( throwIO, throwTo )
#if !MIN_VERSION_base(4,13,0)
import Control.Monad.Fail
#endif
import Control.Monad.Identity
import qualified Control.Monad.State as MTL
import Control.Monad.State( MonadIO(..), lift )
import Control.Monad.State.Class
import Control.Lens
import Data.Char
import Data.IORef
import qualified Data.List as L
import qualified Data.Map as M
import Data.Maybe
import qualified Data.Set as S
import Data.String
import qualified System.Console.Haskeline as HL
import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.IO.Error
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>), (</>))
import qualified Text.PrettyPrint.ANSI.Leijen as PP

-- GHC.IO.Exception is imported so that we can catch
-- the UnsupportedOperation error that may be thrown
-- by getAppUserDataDirectory.
import GHC.IO.Exception

import Verifier.LLVM.Backend
import Verifier.LLVM.Codebase
import Verifier.LLVM.Debugger.Grammar
import Verifier.LLVM.Simulator.Internals
import Verifier.LLVM.Simulator.SimUtils
import Verifier.LLVM.Utils.PrettyPrint

#if !defined(mingw32_HOST_OS) && !defined(__MINGW32__)
import Control.Concurrent (myThreadId)
import System.Posix.Signals
#endif

-- | Treat as IORef as a state transformer.
withIORef :: MonadIO m => IORef s -> MTL.StateT s m a -> m a
withIORef r m = do
  s <- liftIO $ readIORef r 
  (v,s') <- MTL.runStateT m s
  liftIO $ writeIORef r $! s'
  return v

-- | Break on entry to the function.
breakOnEntry :: (Functor m, Monad m)
             => SymDefine (SBETerm sbe) -> Simulator sbe m ()
breakOnEntry def = addBreakpoint (sdName def) (sdEntry def, 0)

safeGetAppUserDataDirectory :: String -> IO (Maybe FilePath)
safeGetAppUserDataDirectory nm = 
    E.catch (Just <$> getAppUserDataDirectory nm)
          catchErrors
  where -- Catch the UnsupportedOperation and DoesNotExist
        -- exceptions that may be thrown.
        catchErrors :: IOError -> IO (Maybe a)
        catchErrors e =
          case ioeGetErrorType e of
            NoSuchThing -> return Nothing
            UnsupportedOperation -> return Nothing
            _ -> throwIO e

-- | Return location of LSS history file
getLSSHistoryPath :: IO (Maybe FilePath)
getLSSHistoryPath = fmap (</> "history") <$> safeGetAppUserDataDirectory "lss"

------------------------------------------------------------------------
-- User interaction

#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
-- @resetInterrupt does nothing on Windows.
resetInterrupt :: IO ()
resetInterrupt = return ()
#else
-- @resetInterrupt@ installs a one-time signal handler so
-- that the next time an interrupt (e.g. Ctrl-C) is given, a
-- @UserInterrupt@ AsyncException will be thrown in the current
-- thread.
-- By default GHC will do this once during program execution, but
-- subsequent uses of Ctrl-C result in immediate termination.
-- This function allows Ctrl-C to be used to interrupt multiple
-- times over program execution.
resetInterrupt :: IO ()
resetInterrupt = do
  tid <- myThreadId
  let handler = throwTo tid UserInterrupt
  let mask = Nothing -- Any other signal handler can block while
  _ <- installHandler sigINT (CatchOnce handler) mask
  return ()
#endif

checkForBreakpoint :: DebuggerContext sbe m
                   => DebuggerRef sbe m -> Simulator sbe m ()
checkForBreakpoint r = do
  mcf <- preuse $ currentPathOfState . pathCallFrames
  case mcf of
    Just cf -> do
      mbps <- use $ breakpoints . at (sdName (cfFunc cf))
      let atBP = fromMaybe False $ S.member (cf^.cfLocation) <$> mbps
      when atBP (enterDebuggerAtBreakpoint r)
    Nothing -> return ()

setPrevCommand :: MonadIO m
               => DebuggerRef sbe m'
               -> Debugger sbe m' ()
               -> m ()
setPrevCommand dr cmd = withIORef dr $ onNoInput .= cmd

runNextCommand :: DebuggerContext sbe m
               => DebuggerCont sbe m
runNextCommand dr = do
  mline <- HL.getInputLine "(lss) "
  ds <- liftIO $ readIORef dr   
  case dropWhile isSpace <$> mline of
    Nothing -> return ()
    Just "" -> do
      runDebugger (ds^.onNoInput) (\() -> runNextCommand) dr
    Just cmdStr -> do
      let pr = runIdentity $ parseString (dsGrammar ds) cmdStr
      case resolveParse pr of
        Left d -> do
          HL.outputStrLn (show d)
          setPrevCommand dr $ return ()
          runNextCommand dr
        Right cmd -> do
          setPrevCommand dr cmd
          runDebugger cmd (\() -> runNextCommand) dr

data DebuggerState sbe m 
   = DebuggerState { -- | Grammar to use for parsing commands
                     dsGrammar :: SimGrammar sbe m
                   , _selectedFrame :: Int
                   , _onNoInput :: Debugger sbe m ()
                   , _resumeThrowsError :: Bool
                   }

-- | Create initial debugger state.
initialState :: DebuggerContext sbe m
             => Codebase sbe
             -> DebuggerState sbe m
initialState cb = 
  DebuggerState { dsGrammar = allCmds cb
                , _selectedFrame = 0
                , _onNoInput = return ()
                , _resumeThrowsError = False
                }

-- | Index of frame selected in the debugger.
-- 0 is the top frame.
selectedFrame :: Simple Lens (DebuggerState sbe m) Int
selectedFrame = lens _selectedFrame (\s v -> s { _selectedFrame = v })

-- | Command to run if no input is provided.
onNoInput :: Simple Lens (DebuggerState sbe m) (Debugger sbe m ())
onNoInput = lens _onNoInput (\s v -> s { _onNoInput = v })

-- | Flag that holds if we know that resuming from this point will throw an error.
resumeThrowsError :: Simple Lens (DebuggerState sbe m) Bool
resumeThrowsError = lens _resumeThrowsError (\s v -> s { _resumeThrowsError = v })

-- | Reference to persistent debugger state.
type DebuggerRef sbe m = IORef (DebuggerState sbe m)

type DebuggerCont sbe m
   = DebuggerRef sbe m
   -> HL.InputT (Simulator sbe m) ()

newtype Debugger sbe m a
      = Debugger { runDebugger :: (a -> DebuggerCont sbe m)
                               -> DebuggerCont sbe m
                 }

instance Functor (Debugger sbe m) where
  fmap f d = Debugger (\c -> runDebugger d (c . f))

instance Applicative (Debugger sbe m) where
  pure v = Debugger ($v)  
  mf <*> mv = Debugger $ \c -> do
    runDebugger mf (\f -> runDebugger mv (c.f))

instance DebuggerContext sbe m => Monad (Debugger sbe m) where
  m >>= h = Debugger $ \c -> runDebugger m (\v -> runDebugger (h v) c)
  return v = Debugger ($v)

instance DebuggerContext sbe m => MonadFail (Debugger sbe m) where
  fail m = Debugger $ \_c dr -> do
    dbugM $ "Unexpected error: " ++ show m
    setPrevCommand dr $ return ()
    runNextCommand dr

instance DebuggerContext sbe m
      => MTL.MonadState (DebuggerState sbe m) (Debugger sbe m) where
  get   = Debugger $ \c r -> liftIO (readIORef r) >>= flip c r
  put v = Debugger $ \c r -> liftIO (writeIORef r v) >> c () r

instance DebuggerContext sbe m => MonadIO (Debugger sbe m) where
  liftIO m = Debugger (\c r -> liftIO m >>= flip c r)

getDebuggerRef :: Debugger sbe m (DebuggerRef sbe m)
getDebuggerRef = Debugger (\c r -> c r r)

runSim :: Monad m => Simulator sbe m a -> Debugger sbe m a
runSim m = Debugger (\c r -> lift m >>= flip c r)

-- | Resume exectuion of simulator.
resume :: Monad m => Debugger sbe m a
resume = Debugger (\_ _ -> return ())

type DebuggerContext sbe m = (Functor sbe, Functor m
#if !MIN_VERSION_haskeline(0,8,0)
                             , HL.MonadException m
#else
                             , E.MonadMask m
#endif
                             , MonadIO m
                             , MonadFail m)

-- | Setup simulator to run debugger when needed.
initializeDebugger :: DebuggerContext sbe m
                   => Simulator sbe m (DebuggerRef sbe m)
initializeDebugger = do
  cb <- gets codebase
  r <- liftIO $ newIORef (initialState cb)
  onPathPosChange .= checkForBreakpoint r
  onSimError      .= enterDebuggerOnError r
  onUserInterrupt .= enterDebuggerOnInterrupt r
  return r

-- | Enter debugger repl.
enterDebugger :: DebuggerContext sbe m
              => DebuggerRef sbe m
              -> Bool -- ^ Indicates if debugger was entered due to error in current path.
              -> Simulator sbe m ()
enterDebugger r eoe = do
  -- Print path location.
  mcs <- use ctrlStk
  case mcs of
    Just cs | pathIsActive (cs^.currentPath) -> do
      let p = cs^.currentPath                  
      dbugM $ show $ indent 2 (text "at" <+> ppPathNameAndLoc p)
    _ -> dbugM "No active execution path."
  -- Update debugger state.
  withIORef r $ do
    selectedFrame .= 0
    resumeThrowsError .= eoe
  -- Run command.
  grammar <- liftIO $ dsGrammar <$> readIORef r
  historyPath <- liftIO getLSSHistoryPath
  let settings = HL.setComplete (matcherCompletions grammar)
               $ HL.defaultSettings { HL.historyFile = historyPath }
  HL.runInputT settings (runNextCommand r)

enterDebuggerOnError :: DebuggerContext sbe m
                     => DebuggerRef sbe m
                     -> ErrorHandler sbe m
enterDebuggerOnError r cs rsn = do
  -- Reset state
  ctrlStk ?= cs
  -- Get current path before last step.
  dbugM $ show $
    text "Simulation error:" <+> ppFailRsn rsn
  -- Debugger state
  enterDebugger r True

enterDebuggerOnInterrupt :: DebuggerContext sbe m
                         => DebuggerRef sbe m
                         -> Simulator sbe m ()
enterDebuggerOnInterrupt r = do
  dbugM $ show $ 
    text "Simulation interrupted: Entering debugger"
  enterDebugger r False
  dbugM $ "Resuming simulation"
  liftIO $ resetInterrupt

enterDebuggerAtBreakpoint :: DebuggerContext sbe m
                          => DebuggerRef sbe m
                          -> Simulator sbe m ()
enterDebuggerAtBreakpoint dr = do
  dbugM "Encountered breakpoint"
  enterDebugger dr False

------------------------------------------------------------------------
-- Completions

matcherCompletions :: (Functor m, Monad m)
                   => Grammar Identity a
                   -> (String, String)
                   -> Simulator sbe m (String, [HL.Completion])
matcherCompletions m (l,_r) = pure (finalize a)
  where rl = reverse l        
        a = runIdentity $ parseString m rl
        finalize pr =
                 (reverse (take p rl), cl)
          where (p,cl) = pr^.parseCompletions

data YesNo = Yes | No
  deriving (Eq)

putAndFlush :: MonadIO m => String -> m ()
putAndFlush msg = liftIO $ putStr msg >> hFlush stdout

-- | Prompts the user for a string matching a choice.
promptChoice :: MonadIO m => String -> [(String,r)] -> m r
promptChoice prompt choices =
    liftIO $ putAndFlush prompt >> loop
  where loop = do
          l <- dropWhile isSpace . fmap toLower <$> getLine
          let resl = [ r | (c,r) <- choices, l `L.isPrefixOf` c ]
          case (l,resl) of
            ("",_) -> putAndFlush prompt >> loop
            (_,r:_)  -> return r
            (_,[]) -> do putAndFlush ("Invalid response; " ++ prompt)
                         loop

promptYesNoCancel :: MonadIO m => m (Maybe YesNo)
promptYesNoCancel = promptChoice prompt choices
  where prompt = "Please enter (Y)es, (N)o, or (C)ancel: "
        choices = [("yes", Just Yes), ("no", Just No), ("cancel", Nothing) ]

promptYesNo :: MonadIO m => m YesNo
promptYesNo = promptChoice prompt choices
  where prompt = "Please enter (Y)es or (N)o: "
        choices = [("yes", Yes), ("no", No)]

-- | Check to see if we should warn user before resuming.  Return True
-- if resume should continue
warnIfResumeThrowsError :: DebuggerContext sbe m
                        => Debugger sbe m Bool
warnIfResumeThrowsError = do
  rte <- use resumeThrowsError
  mcs <- runSim $ use ctrlStk
  case mcs of
    Just cs | rte -> do
      dbugM "Resuming execution on this path should rethrow the simulation error."
      if csHasSinglePath cs then do
        dbugM "Should lss kill the current path, and stop simulation?"
        ync <- promptYesNoCancel
        case ync of
          Just Yes -> do
            killPathByDebugger
            resume
          Just No -> return True
          Nothing -> return False
      else do
        dbugM "Should lss kill the current path, and resume on a new path?"
        ync <- promptYesNoCancel
        case ync of
          Just Yes -> do
            killPathByDebugger
            return True
          Just No -> return True
          Nothing -> return False
    Just cs -> return (pathIsActive (cs^.currentPath))
    Nothing -> return False

-- | @resumeActivePath m@ runs @m@ with the current path,
-- and resumes execution if there is a current path and @m@
-- returns true.
resumeActivePath :: DebuggerContext sbe m
                 => (Path sbe -> Simulator sbe m ())
                 -> Debugger sbe m ()
resumeActivePath action = do
  continueResume <- warnIfResumeThrowsError
  when continueResume $ 
    withActivePath () $ \p -> do
      runSim (action p)
      resume

type DebuggerGrammar a = Grammar Identity a

type SimGrammar sbe m = DebuggerContext sbe m
                     => DebuggerGrammar (Debugger sbe m ())

commandHelp :: Grammar m a -> Doc
commandHelp cmds = 
    text "List of commands:" <$$> 
    PP.empty <$$> 
    vcat (ppCmdHelp <$> (help^.helpCmds)) <$$>
    PP.empty <$$>
    text "NOT IMPLEMENTED: Type \"help\" followed by command name for full documentation." <$$>
    text "Command name abbreviations are allowed if unambiguous."
  where help = matcherHelp cmds

newtype NameMap = NameMap (M.Map String NameMapPair)
type NameMapPair = (Maybe SymBlockID, NameMap)

emptyNameMap :: NameMap
emptyNameMap = NameMap M.empty

splitName :: String -> [String]
splitName nm =
    case break (=='.') nm of
      (l,[]) -> [l]
      (l,_:r) -> l : splitName r

mergeName :: SymBlockID -> [String] -> NameMapPair -> NameMapPair
mergeName b [] (_,m) = (Just b,m)
mergeName b (h:r) (o,NameMap m) = (o, NameMap $ m & at h ?~ mergeName b r mr)
  where mr = fromMaybe (Nothing, NameMap M.empty) $ m^.at h

insertName :: NameMap -> SymBlockID -> NameMap
insertName m b = snd $ mergeName b (splitName (show (ppSymBlockID b)))
                                   (Nothing,m)

pairBlocks :: SymDefine t -> NameMapPair -> Grammar m (Symbol, Breakpoint)
pairBlocks d (mb,m@(NameMap m')) = switch $ others ++ end
  where others | M.null m' = []
               | otherwise = [(,) "." $ nameBlocks d m]
        end = case mb of
                Nothing -> []
                Just b -> [(,) "" $ pure (sdName d,(b,0))]

nameBlocks :: SymDefine t -> NameMap -> Grammar m (Symbol, Breakpoint)
nameBlocks d (NameMap m) = switch $ (entry <$> M.toList m)
  where entry (nm,p) = (fromString nm, pairBlocks d p)

-- | Parses a program location for a breakpoint.
locSeq :: forall sbe m . Codebase sbe -> Grammar m (Symbol, Breakpoint)
locSeq cb = argLabel (text "<loc>") *> hide (switch $ fmap matchDef (cbDefs cb))
  where matchDef :: SymDefine (SBETerm sbe)
                 -> (SwitchKey, Grammar m (Symbol, Breakpoint))
        matchDef d = ( fromString nm
                     , switch [ (,) ":" (nameBlocks d m)
                              , (,) "" $ end
                              ]
                     )
         where Symbol nm = sdName d
               end :: Grammar m (Symbol, Breakpoint)
               end = pure (sdName d, (sdEntry d, 0))
               m = foldl insertName emptyNameMap (M.keys (sdBody d))

optNatArg :: Integer
             -- ^ Default value if argument is missing.
          -> DebuggerGrammar (Integer -> Debugger sbe m ())
          -> DebuggerGrammar (Debugger sbe m ())
optNatArg def g = (fromMaybe def <$> opt nat) <**> g

-- | List of commands for debugger.
allCmds :: Codebase sbe -> SimGrammar sbe m
allCmds cb = res 
  where res -- Breakpoints
            =    keyword "continue" *> continueCmd
            <||> keyword "break"  *> breakCmd cb
            -- Execution
            <||> keyword "delete" *> deleteCmd cb
            <||> keyword "finish" *> finishCmd
            <||> hide (keyword "s" *> stepiCmd)
            <||> keyword "stepi" *> stepiCmd
            -- Information about current path.
            <||> keyword "info"   *> infoCmd
--            <||> keyword "list"   *> listCmd cb
            -- Stack control
            <||> hide (keyword "bt"     *> backtraceCmd)
            <||> keyword "backtrace"    *> backtraceCmd
            <||> keyword "frame"        *> frameCmd
            <||> keyword "up"           *> upFrameCmd
            <||> keyword "down"         *> downFrameCmd
            <||> keyword "select_frame" *> selectFrameCmd
            -- Function for switching between paths
            <||> keyword "path" *> pathCmd
            -- Control and information about debugger.
            <||> keyword "help" *> helpCmd res
            <||> keyword "quit"   *> quitCmd
            
helpCmd :: SimGrammar sbe m -> SimGrammar sbe m
helpCmd cmdList = cmdDef "Print list of commands." $ do
  liftIO $ print (commandHelp cmdList)

pathCmd :: SimGrammar sbe m
pathCmd
  =    hide pathListCmd
  <||> keyword "kill" *> pathKillCmd
  <||> keyword "list" *> pathListCmd
  <||> keyword "sat" *> pathSatCmd


pathListCmd :: SimGrammar sbe m
pathListCmd = cmdDef "List all current execution paths." $ runSim $ do
  mcs <- use ctrlStk
  case mcs of
    Nothing ->
      dbugM "No active paths."
    Just cs -> dbugM $ show $ printTable table
      where ppPathItem :: Integer -> Path sbe -> [String]
            ppPathItem i p = [ 3 `padLeft` (show i)
                             , show (ppPathNameAndLoc p)
                             ]              
            -- Header for table.
            header = [ " Num", "Location"]
            -- Entries for table.
            table = header : zipWith ppPathItem [1..] (cs^..currentPaths)


pathSatCmd :: SimGrammar sbe m
pathSatCmd =
  cmdDef "Check satisfiability of path assertions with SAT solver." $ do
    withActiveCS () $ do
      sat <- runSim $ do
        sbe <- gets symBE
        cond <- assumptionsForActivePath
        liftSBE $ termSAT sbe cond
      case sat of
        Unsat -> do
          dbugM "The current path is infeasible.  Should simulation of the path be terminated?"
          yn <- promptYesNo
          when (yn == Yes) $ do
            killPathByDebugger
        Sat _ ->
          dbugM "Conditions along path are satisfiable."
        SatUnknown ->
          dbugM "Could not determine if path is feasible."

-- | Kills the current path with the debugger.
-- Assumes that there is an active path.
killPathByDebugger :: DebuggerContext sbe m
                   => Debugger sbe m ()
killPathByDebugger = do
  runSim $ killCurrentPath (FailRsn "Terminated by debugger.")
  resumeThrowsError .= False

pathKillCmd :: SimGrammar sbe m
pathKillCmd = cmdDef "Kill the current execution path." $ do
  withActiveCS () $ do
    killPathByDebugger
    mp <- runSim $ preuse currentPathOfState
    case mp of
      Nothing -> dbugM "Killed last path."
      Just p -> dbugM $ show $
        text "Switched to path:" <+> ppPathNameAndLoc p

quitCmd :: SimGrammar sbe m
quitCmd = cmdDef "Exit LSS." $ do
  mcs <- runSim $ use ctrlStk
  case mcs of
    Just cs | pathIsActive (cs^.currentPath) ->
      liftIO $ exitWith ExitSuccess
    _ -> resume

breakCmd :: Codebase sbe -> SimGrammar sbe m
breakCmd cb = (locSeq cb <**>) $ cmdDef desc $ \(b,p) -> do
    runSim $ addBreakpoint b p
  where desc = "Set a breakpoint at a specified location."

deleteCmd :: Codebase sbe -> SimGrammar sbe m
deleteCmd cb = (opt (locSeq cb) <**>) $ cmdDef desc $ \mbp -> do
      runSim $ 
        case mbp of
          Just (b,p) -> removeBreakpoint b p
          Nothing -> dbugM "Remove all breakpoints"
            --TODO: implement this.

  where desc = "Clear a breakpoint at a function."

concatBreakpoints :: M.Map Symbol (S.Set Breakpoint)
                  -> [(Symbol, Breakpoint)]
concatBreakpoints m =
  [ (sym,bp) | (sym, bps) <- M.toList m, bp <- S.toList bps ]

infoCmd :: SimGrammar sbe m
infoCmd
  =    keyword "args"        *> infoArgsCmd
  <||> keyword "block"       *> infoBlockCmd
  <||> keyword "breakpoints" *> infoBreakpointsCmd
  <||> keyword "ctrlstk"     *> infoCtrlStkCmd
  <||> keyword "function"    *> infoFunctionCmd
  <||> keyword "locals"      *> infoLocalsCmd
  <||> keyword "memory"      *> infoMemoryCmd
  <||> keyword "stack"       *> backtraceCmd

infoArgsCmd :: SimGrammar sbe m
infoArgsCmd =
  cmdDef "Print argument variables in the current stack frame." $ do
    withActiveCallFrame () $ \cf -> do
      sbe <- gets symBE
      dbugM $ show $ ppLocals sbe $ cfArgValues cf

infoBlockCmd :: SimGrammar sbe m
infoBlockCmd =
  cmdDef "Print block information." $ do
    withActiveCallFrame () $ \cf -> do
      dbugM $ show $ ppSymBlock $ cfBlock cf

infoBreakpointsCmd :: SimGrammar sbe m
infoBreakpointsCmd =
  cmdDef "List breakpoints." $ runSim $ do
    bps <- concatBreakpoints <$> use breakpoints
    let ppRow :: Integer -> (Symbol,Breakpoint) -> [String]
        ppRow i (Symbol sym,bp) =
          [show i, sym ++ ":" ++ show (ppBreakpoint bp)]
    dbugM $ show $
      case bps of
        [] -> text "No breakpoints."
        _  -> printTable (header : zipWith ppRow [1..] bps)
          where header = ["Num", "Location"]

infoCtrlStkCmd :: SimGrammar sbe m
infoCtrlStkCmd =
  cmdDef "Print the entire control stack." $ do
    runSim dumpCtrlStk

infoFunctionCmd :: SimGrammar sbe m
infoFunctionCmd =
  cmdDef "Print function information." $ do
    withActiveCallFrame () $ \cf -> do
      dbugM $ show $ ppSymDefine (cfFunc cf)

infoLocalsCmd :: SimGrammar sbe m
infoLocalsCmd =
  cmdDef "Print local variables in the current stack frame." $ do
    withActiveCallFrame () $ \cf -> do
      sbe <- gets symBE
      dbugM $ show $ ppLocals sbe $ cfLocalValues cf

-- Instead writing @infoMemoryRangeCmd <*> optAddr <*> optAddr@
-- results in no "<addr>?" in the help output?!
infoMemoryCmd :: SimGrammar sbe m
infoMemoryCmd = ((,) <$> optAddr <*> optAddr) <**> infoMemoryRangeCmd
  where
  infoMemoryRangeCmd = cmdDef desc $ \(mlow, mhigh) -> do
    let mranges = case (mlow, mhigh) of
          (Just low, Just high) -> Just [(low, high)]
          (Just low, Nothing)   -> Just [(low, low+1)]
          (Nothing,  Nothing)   -> Nothing
          (Nothing,  Just _)    -> error "infoMemoryCmd: unreachable!"
    runSim $ dumpMem 0 "memory" mranges
  -- Putting the 'opt' outside here, and 'hide' on 'nat', results in a
  -- '?' on the "<addr>" label in the help output. Without the 'hide'
  -- the label "<addr>" doesn't appear at all in the help.
  optAddr = opt (argLabel (text "<addr>") *> hide nat)
  desc = unlines
    [ "Print memory information."
    , ""
    , "    - With no arguments, prints all memory."
    , "    - With one argument <addr>, prints memory at address <addr>."
    , "    - With two arguments <low>, <high>, prints memory in the address range"
    , "      [<low>,<high>)."
    , ""
    , "    The optional address arguments may be specified in binary (e.g. 0b110),"
    , "    decimal, or hex (e.g. 0xabcd)."
    ]

{-
listCmd :: Codebase sbe -> SimGrammar sbe m
listCmd cb = (locSeq cb <**>) $ cmdDef "List specified function in line." $ \loc -> do
  error "internal: listCmd undefined" loc
-}

-- | @padLeft n s@ adds extra spaces before @s@ so that the result has
-- at least @n@ characters.
padLeft :: Int -> String -> String
padLeft l s = replicate (l - length s) ' ' ++ s

-- | @padRight n s@ adds extra spaces after @s@ so that the result has
-- at least @n@ characters.
padRight :: String -> Int -> String
padRight s l = s ++ replicate (l - length s) ' '

printTable :: [[String]] -> Doc
printTable m = vcat padded
  where maxl (i:x) (j:y) = max i j : maxl x y
        maxl [] y = y
        maxl x [] = x
        -- Maximum lengths of each column.          
        ll = fmap length <$> m
        maxLengths = foldr maxl (repeat 0) ll
        padded = hsep . fmap text . zipWith padLeft maxLengths <$> m

ppBreakpoint :: Breakpoint -> Doc
ppBreakpoint (sbid,0) = ppSymBlockID sbid 
ppBreakpoint (sbid,i) = ppSymBlockID sbid PP.<> char ':' PP.<> int i

-- | Run a computation if there is an active 
withActiveCS :: DebuggerContext sbe m
             => a -- ^ Result to return if there is no execution path.
             -> Debugger sbe m a -- ^ Action to run if there is an active path.
             -> Debugger sbe m a
withActiveCS v action = do
  mcs <- runSim $ use ctrlStk
  case mcs of
    Just cs | pathIsActive (cs^.currentPath) -> action
    _ -> dbugM "No active execution path." >> return v

-- | @withActivePath v act@ runs @act@ with the active path
withActivePath :: DebuggerContext sbe m
               => a
               -> (Path sbe -> Debugger sbe m a)
               -> Debugger sbe m a
withActivePath v action = do
  mcs <- runSim $ use ctrlStk
  case mcs of
    Just cs | pathIsActive (cs^.currentPath) -> action (cs^.currentPath)
    _ -> dbugM "No active execution path." >> return v

-- | @withActiveCallFrame v act@ runs @act@ with the active call frame.
withActiveCallFrame :: DebuggerContext sbe m
                    => a
                    -> (CallFrame sbe -> Simulator sbe m a)
                    -> Debugger sbe m a
withActiveCallFrame v action = do
  i <- use selectedFrame
  runSim $ do
    mp <- preuse currentPathOfState
    case mp of
      -- Get call frame if pth is active.
      Just p | cf:_ <- drop i (p^..pathCallFrames) -> do
        action cf
      _ -> dbugM "No active execution path." >> return v

continueCmd :: SimGrammar sbe m
continueCmd = cmdDef "Continue execution." $ do
  dr <- getDebuggerRef
  resumeActivePath $ \_ -> do
    onPathPosChange .= checkForBreakpoint dr

onReturnFrom :: DebuggerContext sbe m
             => DebuggerRef sbe m -> Int -> Simulator sbe m ()
onReturnFrom dr ht = do
  Just p <- preuse currentPathOfState
  if pathStackHt p < ht then
    enterDebuggerAtBreakpoint dr
  else
    checkForBreakpoint dr

finishCmd :: SimGrammar sbe m
finishCmd = cmdDef desc $ do
    dr <- getDebuggerRef
    resumeActivePath $ \p -> do
      onPathPosChange .= onReturnFrom dr (pathStackHt p)
  where desc = "Execute until the current stack frame returns."

enterDebuggerAfterNSteps
  :: DebuggerContext sbe m
  => DebuggerRef sbe m -> Integer -> Simulator sbe m ()
enterDebuggerAfterNSteps dr n
  | n <= 1 = enterDebugger dr False
  | otherwise = onPathPosChange .= enterDebuggerAfterNSteps dr (n-1)

stepiCmd :: SimGrammar sbe m
stepiCmd = optNatArg 1 $
  cmdDef "Execute one symbolic statement." $ \c -> do
    when (c > 0) $ do
      dr <- getDebuggerRef
      resumeActivePath $ \_ -> do
        onPathPosChange .= enterDebuggerAfterNSteps dr c


------------------------------------------------------------------------
-- Stack frame commands.

-- | Pretty print the location of the frame.
ppFrameLoc :: SBE sbe -> Int -> CallFrame sbe -> Doc
ppFrameLoc sbe i cf =
   char '#' <> text (show i `padRight` 2)
   <+> ppSymbol (sdName (cfFunc cf)) <> parens (commaSepList argDocs)
   <+> text "at" <+> ppLocation (cf^.cfLocation)
  where argDocs = ppArg <$> cfArgValues cf 
        ppArg (nm,v) =
          ppIdent nm <> char '=' <+> prettyTermD sbe v

-- | Run action with call frame list if path is active.
withActiveStack :: DebuggerContext sbe m
                => ([CallFrame sbe] -> Debugger sbe m ())
                -> Debugger sbe m ()
withActiveStack action = do
  mp <- runSim $ preuse currentPathOfState
  case mp of
    Just p | cfl <- p^..pathCallFrames, not (null cfl) -> action cfl
    _ -> dbugM "No stack."

-- | @selectFrame i action@ checks that @i@ is a valid frame,
-- and is so, selects the frame and runs @action@ with the frame.
selectFrame :: DebuggerContext sbe m
            => Int -> (CallFrame sbe -> Debugger sbe m ()) -> Debugger sbe m ()
selectFrame i action =
  withActiveStack $ \cfl -> do
    if 0 <= i && i < length cfl then do
      selectedFrame .= i
      action (cfl !! i)
    else do
      dbugM $ "No frame #" ++ show i ++ "."

printFrameLoc :: MonadIO m => Int -> CallFrame sbe -> Debugger sbe m ()
printFrameLoc i cf = runSim $ do
  sbe <- gets symBE
  dbugM $ show $ ppFrameLoc sbe i cf

-- | Print backtrace of the stack.
backtraceCmd :: SimGrammar sbe m
backtraceCmd = cmdDef "Print backtrace of the stack." $ do
  withActivePath () $ \p -> do
    zipWithM_ printFrameLoc [0..] (p^..pathCallFrames)

-- | Select a specific frame.
selectFrameCmd :: SimGrammar sbe m
selectFrameCmd = (<**>) nat $
  cmdDef "Select a stack frame without printing anything." $ \(fromInteger -> i) -> do
    selectFrame i $ \_ -> return ()

-- | Select a frame and print it's location.
frameCmd :: SimGrammar sbe m
frameCmd = (<**>) nat $
  cmdDef "Select and print a stack frame." $ \(fromInteger -> i) -> do
    selectFrame i $ \cf -> do
      printFrameLoc i cf

-- | Move up one or more frames to a function that called the current frame.
upFrameCmd :: SimGrammar sbe m
upFrameCmd = optNatArg 1 $
  cmdDef "Select and print stack frame that called this one." $ \c -> do
    withActiveStack $ \cfl -> do
      i <- use selectedFrame
      if i > 0 then do
        let i' = max 0 (i - fromInteger c)
        selectedFrame .= i'
        printFrameLoc i' $ cfl !! i'
      else do
        dbugM "Initial frame already selected; you cannot go up."

-- | Move down one or more frames to a function called by the current frame.
downFrameCmd :: SimGrammar sbe m
downFrameCmd = optNatArg 1 $
  cmdDef "Select and print stack frame called by this one." $ \c -> do
    withActiveStack $ \cfl -> do
      i <- use selectedFrame
      let maxIdx = length cfl - 1
      if i < maxIdx then do
        let i' = min maxIdx (i + fromInteger c)
        selectedFrame .= i'
        printFrameLoc i' $ cfl !! i'
      else do
        dbugM "Bottom frame selected; you cannot go down."
