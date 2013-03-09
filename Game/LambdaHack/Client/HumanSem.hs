{-# LANGUAGE GADTs, OverloadedStrings #-}
-- | Semantics of human player commands.
module Game.LambdaHack.Client.HumanSem
  ( cmdHumanSem
  ) where

import Control.Monad
import Control.Monad.Writer.Strict (WriterT)
import Data.Maybe
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.ActorState
import Game.LambdaHack.Client.Action
import Game.LambdaHack.Client.CmdHuman
import Game.LambdaHack.Client.HumanGlobal
import Game.LambdaHack.Client.HumanLocal
import Game.LambdaHack.Client.State
import Game.LambdaHack.CmdSer
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Vector
import Game.LambdaHack.VectorXY

-- | The semantics of human player commands in terms of the @Action@ monad.
-- Decides if the action takes time and what action to perform.
-- Time cosuming commands are marked as such in help and cannot be
-- invoked in targeting mode on a remote level (level different than
-- the level of the selected hero).
cmdHumanSem :: (MonadActionAbort m, MonadClientUI m)
            => CmdHuman -> WriterT Slideshow m (Maybe CmdSer)
cmdHumanSem cmd = do
  arena <- getArenaUI
  when (noRemoteCmdHuman cmd) $ checkCursor arena
  cmdAction cmd

-- | The basic action for a command and whether it takes time.
cmdAction :: (MonadActionAbort m, MonadClientUI m)
          => CmdHuman -> WriterT Slideshow m (Maybe CmdSer)
cmdAction cmd = case cmd of
  Move v -> moveHuman v
  Run v -> runHuman v
  Wait -> fmap Just $ waitHuman
  Pickup -> fmap Just $ pickupHuman
  Drop -> fmap Just $ dropHuman
  Project{..} -> projectHuman verb object syms
  Apply{..} -> fmap Just $ applyHuman verb object syms
  TriggerDir{..} -> fmap Just $ triggerDirHuman feature verb
  TriggerTile{..} -> fmap Just $ triggerTileHuman feature

  GameRestart -> fmap Just $ gameRestartHuman
  GameExit -> fmap Just $ gameExitHuman
  GameSave -> fmap Just $ gameSaveHuman
  CfgDump -> fmap Just $ cfgDumpHuman

  SelectHero k -> selectHeroHuman k >> return Nothing
  MemberCycle -> memberCycleHuman >> return Nothing
  MemberBack -> memberBackHuman >> return Nothing
  Inventory -> inventoryHuman >> return Nothing
  TgtFloor -> tgtFloorHuman
  TgtEnemy -> tgtEnemyHuman
  TgtAscend k -> tgtAscendHuman k >> return Nothing
  EpsIncr b -> epsIncrHuman b >> return Nothing
  Cancel -> cancelHuman displayMainMenu >> return Nothing
  Accept -> acceptHuman helpHuman >> return Nothing
  Clear -> clearHuman >> return Nothing
  History -> historyHuman >> return Nothing
  Help -> helpHuman >> return Nothing
  DebugArea -> modifyClient toggleMarkVision >> return Nothing
  DebugSmell -> modifyClient toggleMarkSmell >> return Nothing

-- | If in targeting mode, check if the current level is the same
-- as player level and refuse performing the action otherwise.
checkCursor :: (MonadActionAbort m, MonadClientUI m) => LevelId -> m ()
checkCursor arena = do
  (lid, _) <- viewedLevel
  when (arena /= lid) $
    abortWith "[targeting] command disabled on a remote level, press ESC to switch back"

moveHuman :: MonadClientUI m => VectorXY -> WriterT Slideshow m (Maybe CmdSer)
moveHuman v = do
  tgtMode <- getsClient stgtMode
  (arena, Level{lxsize}) <- viewedLevel
  leader <- getLeaderUI
  sb <- getsState $ getActorBody leader
  if isJust tgtMode then do
    let dir = toDir lxsize v
    moveCursor dir 1 >> return Nothing
  else do
    let dir = toDir lxsize v
        tpos = bpos sb `shift` dir
    -- We always see actors from our own faction.
    tgt <- getsState $ posToActor tpos arena
    case tgt of
      Just target -> do
        tb <- getsState $ getActorBody target
        if bfaction tb == bfaction sb && not (bproj tb) then do
          -- Select adjacent actor by bumping into him. Takes no time.
          success <- selectLeader target
          assert (success `blame` (leader, target, tb)) skip
          return Nothing
        else fmap Just $ moveLeader dir
      _ -> fmap Just $ moveLeader dir

runHuman :: MonadClientUI m => VectorXY -> WriterT Slideshow m (Maybe CmdSer)
runHuman v = do
  tgtMode <- getsClient stgtMode
  (_, Level{lxsize}) <- viewedLevel
  if isJust tgtMode then
    let dir = toDir lxsize v
    in moveCursor dir 10 >> return Nothing
  else
    let dir = toDir lxsize v
    in fmap Just $ runLeader dir

projectHuman :: (MonadActionAbort m, MonadClientUI m)
             => MU.Part -> MU.Part -> [Char]
             -> WriterT Slideshow m (Maybe CmdSer)
projectHuman verb object syms = do
  tgtLoc <- targetToPos
  if isNothing tgtLoc then retargetLeader >> return Nothing
  else fmap Just $ projectLeader verb object syms

tgtFloorHuman :: MonadClientUI m => WriterT Slideshow m (Maybe CmdSer)
tgtFloorHuman = do
  arena <- getArenaUI
  (tgtFloorLeader $ TgtExplicit arena) >> return Nothing

tgtEnemyHuman :: MonadClientUI m => WriterT Slideshow m (Maybe CmdSer)
tgtEnemyHuman = do
  arena <- getArenaUI
  (tgtEnemyLeader $ TgtExplicit arena) >> return Nothing