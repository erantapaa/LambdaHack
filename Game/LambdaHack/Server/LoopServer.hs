{-# LANGUAGE GADTs #-}
-- | The main loop of the server, processing human and computer player
-- moves turn by turn.
module Game.LambdaHack.Server.LoopServer (loopSer) where

import Control.Arrow ((&&&))
import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.Key (mapWithKeyM_)
import Data.List
import Data.Maybe
import qualified Data.Ord as Ord

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.ClientOptions
import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.Response
import Game.LambdaHack.Common.State
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.ModeKind
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Server.EndServer
import Game.LambdaHack.Server.Fov
import Game.LambdaHack.Server.HandleEffectServer
import Game.LambdaHack.Server.HandleRequestServer
import Game.LambdaHack.Server.ItemServer
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.PeriodicServer
import Game.LambdaHack.Server.ProtocolServer
import Game.LambdaHack.Server.StartServer
import Game.LambdaHack.Server.State

-- | Start a game session. Loop, communicating with clients.
loopSer :: (MonadAtomic m, MonadServerReadRequest m)
        => DebugModeSer
        -> (FactionId -> ChanServer ResponseUI RequestUI -> IO ())
        -> (FactionId -> ChanServer ResponseAI RequestAI -> IO ())
        -> Kind.COps
        -> m ()
loopSer sdebug executorUI executorAI !cops = do
  -- Recover states and launch clients.
  let updConn = updateConn executorUI executorAI
  restored <- tryRestore cops sdebug
  case restored of
    Just (sRaw, ser) | not $ snewGameSer sdebug -> do  -- run a restored game
      -- First, set the previous cops, to send consistent info to clients.
      let setPreviousCops = const cops
      execUpdAtomic $ UpdResumeServer $ updateCOps setPreviousCops sRaw
      putServer ser
      sdebugNxt <- initDebug cops sdebug
      modifyServer $ \ser2 -> ser2 {sdebugNxt}
      applyDebug
      updConn
      initPer
      pers <- getsServer sper
      broadcastUpdAtomic $ \fid -> UpdResume fid (pers EM.! fid)
      -- Second, set the current cops and reinit perception.
      let setCurrentCops = const (speedupCOps (sallClear sdebugNxt) cops)
      -- @sRaw@ is correct here, because none of the above changes State.
      execUpdAtomic $ UpdResumeServer $ updateCOps setCurrentCops sRaw
      -- We dump RNG seeds here, in case the game wasn't run
      -- with --dumpInitRngs previously and we need to seeds.
      when (sdumpInitRngs sdebug) $ dumpRngs
    _ -> do  -- Starting the first new game for this savefile.
      -- Set up commandline debug mode
      let mrandom = case restored of
            Just (_, ser) -> Just $ srandom ser
            Nothing -> Nothing
      s <- gameReset cops sdebug mrandom
      sdebugNxt <- initDebug cops sdebug
      let debugBarRngs = sdebugNxt {sdungeonRng = Nothing, smainRng = Nothing}
      modifyServer $ \ser -> ser { sdebugNxt = debugBarRngs
                                 , sdebugSer = debugBarRngs }
      let speedup = speedupCOps (sallClear sdebugNxt)
      execUpdAtomic $ UpdRestartServer $ updateCOps speedup s
      updConn
      initPer
      reinitGame
      writeSaveAll False
  resetSessionStart
  -- Start a clip (a part of a turn for which one or more frames
  -- will be generated). Do whatever has to be done
  -- every fixed number of time units, e.g., monster generation.
  -- Run the leader and other actors moves. Eventually advance the time
  -- and repeat.
  let loop = do
        let factionArena fact = do
              case gleader fact of
               -- Even spawners and horrors need an active arena
               -- for their leader, or they start clogging stairs.
               Just (leader, _) -> do
                  b <- getsState $ getActorBody leader
                  return $ Just $ blid b
               Nothing -> return Nothing
        factionD <- getsState sfactionD
        marenas <- mapM factionArena $ EM.elems factionD
        let arenas = ES.toList $ ES.fromList $ catMaybes marenas
        assert (not $ null arenas) skip  -- game over not caught earlier
        mapM_ handleActors arenas
        quit <- getsServer squit
        if quit then do
          -- In case of game save+exit or restart, don't age levels (endClip)
          -- since possibly not all actors have moved yet.
          modifyServer $ \ser -> ser {squit = False}
          endOrLoop loop (restartGame updConn loop) gameExit (writeSaveAll True)
        else do
          continue <- endClip arenas
          when continue loop
  loop

endClip :: (MonadAtomic m, MonadServer m, MonadServerReadRequest m)
        => [LevelId] -> m Bool
endClip arenas = do
  Kind.COps{corule} <- getsState scops
  let stdRuleset = Kind.stdRuleset corule
      writeSaveClips = rwriteSaveClips stdRuleset
      leadLevelClips = rleadLevelClips stdRuleset
      ageProcessed lid processed =
        EM.insertWith absoluteTimeAdd lid timeClip processed
      ageServer lid ser = ser {sprocessed = ageProcessed lid $ sprocessed ser}
  mapM_ (modifyServer . ageServer) arenas
  execUpdAtomic $ UpdAgeGame (Delta timeClip) arenas
  -- Perform periodic dungeon maintenance.
  time <- getsState stime
  let clipN = time `timeFit` timeClip
      clipInTurn = let r = timeTurn `timeFit` timeClip
                   in assert (r > 2) r
      clipMod = clipN `mod` clipInTurn
  when (clipN `mod` writeSaveClips == 0) $ do
    modifyServer $ \ser -> ser {swriteSave = False}
    writeSaveAll False
  when (clipN `mod` leadLevelClips == 0) leadLevelFlip
  -- Add monsters each turn, not each clip.
  -- Do this on only one of the arenas to prevent micromanagement,
  -- e.g., spreading leaders across levels to bump monster generation.
  if clipMod == 1 then do
    arena <- rndToAction $ oneOf arenas
    activatePeriodicLevel arena
    spawnMonster arena
    stopAfter <- getsServer $ sstopAfter . sdebugSer
    case stopAfter of
      Nothing -> return True
      Just stopA -> do
        exit <- elapsedSessionTimeGT stopA
        if exit then do
          tellAllClipPS
          gameExit
          return False  -- don't re-enter the game loop
        else return True
  else return True

-- | Trigger periodic items for all actors on the given level.
-- This is done each game turn, not player turn, not to overpower
-- fast actors (assuming the effects are positive).
activatePeriodicLevel :: (MonadAtomic m, MonadServer m) => LevelId -> m ()
activatePeriodicLevel lid = do
  time <- getsState $ getLocalTime lid
  let turnN = time `timeFit` timeTurn
      activatePeriodicItem aid (iid, itemFull) = do
        case strengthFromEqpSlot Effect.EqpSlotPeriodic itemFull of
          Nothing -> return ()
          Just n -> when (turnN `mod` (100 `div` n) == 0) $
                      void $ itemEffect aid aid iid itemFull False True
            -- periodic activation doesn't destroy items, even non-Durable
      activatePeriodicActor aid = do
        allItems <- fullAssocsServer aid [COrgan, CEqp]
        mapM_ (activatePeriodicItem aid) allItems
  allActors <- getsState $ actorRegularAssocs (const True) lid
  mapM_ (\(aid, _) -> activatePeriodicActor aid) allActors

-- | Perform moves for individual actors, as long as there are actors
-- with the next move time less or equal to the end of current cut-off.
handleActors :: (MonadAtomic m, MonadServerReadRequest m)
             => LevelId -> m ()
handleActors lid = do
  -- The end of this clip, inclusive. This is used exclusively
  -- to decide which actors to process this time. Transparent to clients.
  timeCutOff <- getsServer $ EM.findWithDefault timeClip lid . sprocessed
  Level{lprio} <- getLevel lid
  quit <- getsServer squit
  factionD <- getsState sfactionD
  s <- getState
  let -- Actors of the same faction move together.
      -- TODO: insert wrt the order, instead of sorting
      isLeader (aid, b) = Just aid /= fmap fst (gleader (factionD EM.! bfid b))
      order = Ord.comparing $
        ((>= 0) . bhp . snd) &&& bfid . snd &&& isLeader &&& bsymbol . snd
      (atime, as) = EM.findMin lprio
      ams = map (\a -> (a, getActorBody a s)) as
      mnext | EM.null lprio = Nothing  -- no actor alive, wait until it spawns
            | otherwise = if atime > timeCutOff
                          then Nothing  -- no actor is ready for another move
                          else Just $ minimumBy order ams
      startActor aid = execSfxAtomic $ SfxActorStart aid
  case mnext of
    _ | quit -> return ()
    Nothing -> return ()
    Just (aid, b) | maybe False (null .fst) (btrajectory b) && bproj b -> do
      -- A projectile drops to the ground due to obstacles or range.
      assert (bproj b) skip
      startActor aid
      dieSer aid b False
      handleActors lid
    Just (aid, b) | bhp b < 0 && bproj b -> do
      -- A projectile hits an actor. The carried item is destroyed.
      -- TODO: perhaps don't destroy if no effect (NoEffect),
      -- to help testing items. But OTOH, we want most items to have
      -- some effect, even silly, for flavour. Anyway, if the silly
      -- effect identifies an item, the hit is not wasted, so this makes sense.
      startActor aid
      dieSer aid b True
      handleActors lid
    Just (aid, b) | bhp b <= 0 && not (bproj b) -> do
      -- An actor dies. Items drop to the ground
      -- and possibly a new leader is elected.
      startActor aid
      dieSer aid b False
      handleActors lid
    Just (aid, body) -> do
      startActor aid
      let side = bfid body
          fact = factionD EM.! side
          mleader = gleader fact
          aidIsLeader = fmap fst mleader == Just aid
          mainUIactor = fhasUI (gplayer fact)
                        && (aidIsLeader
                            || fleaderMode (gplayer fact) == LeaderNull)
      queryUI <-
        if mainUIactor then do
          let underAI = isAIFact fact
          if underAI then do
            -- If UI client for the faction completely under AI control,
            -- ping often to sync frames and to catch ESC,
            -- which switches off Ai control.
            sendPingUI side
            fact2 <- getsState $ (EM.! side) . sfactionD
            let underAI2 = isAIFact fact2
            return $! not underAI2
          else return True
        else return False
      let setBWait hasWait aidNew = do
            bPre <- getsState $ getActorBody aidNew
            when (hasWait /= bwait bPre) $
              execUpdAtomic $ UpdWaitActor aidNew hasWait
      if isJust $ btrajectory body then do
        timed <- setTrajectory aid
        when timed $ advanceTime aid
      else if queryUI then do
        cmdS <- sendQueryUI side aid
        -- TODO: check that the command is legal first, report and reject,
        -- but do not crash (currently server asserts things and crashes)
        aidNew <- handleRequestUI side cmdS
        let hasWait (ReqUITimed ReqWait{}) = True
            hasWait (ReqUILeader _ _ cmd) = hasWait cmd
            hasWait _ = False
        maybe skip (setBWait (hasWait cmdS)) aidNew
        -- Advance time once, after the leader switched perhaps many times.
        -- TODO: this is correct only when all heroes have the same
        -- speed and can't switch leaders by, e.g., aiming a wand
        -- of domination. We need to generalize by displaying
        -- "(next move in .3s [RET]" when switching leaders.
        -- RET waits .3s and gives back control,
        -- Any other key does the .3s wait and the action from the key
        -- at once.
        maybe skip advanceTime aidNew
      else do
        -- Clear messages in the UI client (if any), if the actor
        -- is a leader (which happens when a UI client is fully
        -- computer-controlled) or if faction is leaderless.
        -- We could record history more often, to avoid long reports,
        -- but we'd have to add -more- prompts.
        when mainUIactor $ execUpdAtomic $ UpdRecordHistory side
        cmdS <- sendQueryAI side aid
        aidNew <- handleRequestAI side aid cmdS
        let hasWait (ReqAITimed ReqWait{}) = True
            hasWait (ReqAILeader _ _ cmd) = hasWait cmd
            hasWait _ = False
        setBWait (hasWait cmdS) aidNew
        -- AI always takes time and so doesn't loop.
        advanceTime aidNew
      handleActors lid

gameExit :: (MonadAtomic m, MonadServerReadRequest m) => m ()
gameExit = do
  -- Kill all clients, including those that did not take part
  -- in the current game.
  -- Clients exit not now, but after they print all ending screens.
  -- debugPrint "Server kills clients"
  killAllClients
  -- Verify that the saved perception is equal to future reconstructed.
  persAccumulated <- getsServer sper
  fovMode <- getsServer $ sfovMode . sdebugSer
  ser <- getServer
  pers <- getsState $ \s -> dungeonPerception (fromMaybe Digital fovMode) s ser
  assert (persAccumulated == pers `blame` "wrong accumulated perception"
                                  `twith` (persAccumulated, pers)) skip

restartGame :: (MonadAtomic m, MonadServerReadRequest m)
            => m () -> m () -> m ()
restartGame updConn loop = do
  tellGameClipPS
  cops <- getsState scops
  sdebugNxt <- getsServer sdebugNxt
  srandom <- getsServer srandom
  s <- gameReset cops sdebugNxt $ Just srandom
  let debugBarRngs = sdebugNxt {sdungeonRng = Nothing, smainRng = Nothing}
  modifyServer $ \ser -> ser { sdebugNxt = debugBarRngs
                             , sdebugSer = debugBarRngs }
  execUpdAtomic $ UpdRestartServer s
  updConn
  initPer
  reinitGame
  writeSaveAll False
  loop

-- TODO: This can be improved by adding a timeout
-- and by asking clients to prepare
-- a save (in this way checking they have permissions, enough space, etc.)
-- and when all report back, asking them to commit the save.
-- | Save game on server and all clients. Clients are pinged first,
-- which greatly reduced the chance of saves being out of sync.
writeSaveAll :: (MonadAtomic m, MonadServerReadRequest m) => Bool -> m ()
writeSaveAll uiRequested = do
  bench <- getsServer $ sbenchmark . sdebugCli . sdebugSer
  when (uiRequested || not bench) $ do
    factionD <- getsState sfactionD
    let ping fid _ = do
          sendPingAI fid
          when (fhasUI $ gplayer $ factionD EM.! fid) $ sendPingUI fid
    mapWithKeyM_ ping factionD
    execUpdAtomic UpdWriteSave
    saveServer

-- TODO: move somewhere?
-- | Manage trajectory of a projectile.
--
-- Colliding with a wall or actor doesn't take time, because
-- the projectile does not move (the move is blocked).
-- Not advancing time forces dead projectiles to be destroyed ASAP.
-- Otherwise, with some timings, it can stay on the game map dead,
-- blocking path of human-controlled actors and alarming the hapless human.
setTrajectory :: (MonadAtomic m, MonadServer m) => ActorId -> m Bool
setTrajectory aid = do
  cops <- getsState scops
  b <- getsState $ getActorBody aid
  lvl <- getLevel $ blid b
  let clearTrajectory speed = do
        -- Lose HP due to bumping into an obstacle.
        execUpdAtomic $ UpdRefillHP aid minusM
        execUpdAtomic $ UpdTrajectory aid
                                      (btrajectory b)
                                      (Just ([], speed))
        return $ not $ bproj b  -- projectiles must vanish soon
  case btrajectory b of
    Just ((d : lv), speed) ->
      if not $ accessibleDir cops lvl (bpos b) d
      then clearTrajectory speed
      else do
        when (bproj b && null lv) $ do
          let toColor = Color.BrBlack
          when (bcolor b /= toColor) $
            execUpdAtomic $ UpdColorActor aid (bcolor b) toColor
        reqMove aid d  -- hit clears trajectory of non-projectiles
        b2 <- getsState $ getActorBody aid
        if actorDying b2 then return $ not $ bproj b  -- don't clear trajectory
        else do
          unless (maybe False (null . fst) (btrajectory b2)) $
            execUpdAtomic $ UpdTrajectory aid
                                          (btrajectory b2)
                                          (Just (lv, speed))
          return True
    Just ([], _) -> do  -- non-projectile actor stops flying
      assert (not $ bproj b) skip
      execUpdAtomic $ UpdTrajectory aid (btrajectory b) Nothing
      return False
    _ -> assert `failure` "Nothing trajectory" `twith` (aid, b)
