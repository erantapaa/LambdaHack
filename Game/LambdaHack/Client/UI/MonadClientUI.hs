{-# LANGUAGE RankNTypes #-}
-- | Client monad for interacting with a human through UI.
module Game.LambdaHack.Client.UI.MonadClientUI
  ( -- * Client UI monad
    MonadClientUI( getsSession  -- exposed only to be implemented, not used
                 , liftIO  -- exposed only to be implemented, not used
                 )
  , SessionUI(..)
    -- * Display and key input
  , ColorMode(..)
  , promptGetKey, getKeyOverlayCommand, getInitConfirms
  , displayFrame, displayDelay, displayFrames, displayActorStart, drawOverlay
    -- * Assorted primitives
  , stopPlayBack, stopRunning, askConfig, askBinding
  , syncFrames, tryTakeMVarSescMVar, scoreToSlideshow
  , getLeaderUI, getArenaUI, viewedLevel
  , targetDescLeader, targetDescCursor
  , leaderTgtToPos, leaderTgtAims, cursorToPos
  ) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import qualified NLP.Miniutter.English as MU
import System.Time

import Game.LambdaHack.Client.BfsClient
import Game.LambdaHack.Client.CommonClient
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.MonadClient hiding (liftIO)
import Game.LambdaHack.Client.State
import Game.LambdaHack.Client.UI.Animation
import Game.LambdaHack.Client.UI.Config
import Game.LambdaHack.Client.UI.DrawClient
import Game.LambdaHack.Client.UI.Frontend as Frontend
import Game.LambdaHack.Client.UI.KeyBindings
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import qualified Game.LambdaHack.Common.HighScore as HighScore
import Game.LambdaHack.Common.ItemDescription
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State
import Game.LambdaHack.Content.ModeKind

-- | The information that is constant across a client playing session,
-- including many consecutive games in a single session,
-- but is completely disregarded and reset when a new playing session starts.
-- Auxiliary AI and computer player clients have no @sfs@ nor @sbinding@.
data SessionUI = SessionUI
  { schanF   :: !ChanFrontend       -- ^ connection with the frontend
  , sbinding :: !Binding            -- ^ binding of keys to commands
  , sescMVar :: !(Maybe (MVar ()))
  , sconfig  :: !Config
  }

class MonadClient m => MonadClientUI m where
  getsSession  :: (SessionUI -> a) -> m a
  liftIO       :: IO a -> m a

-- | Read a keystroke received from the frontend.
readConnFrontend :: MonadClientUI m => m K.KM
readConnFrontend = do
  ChanFrontend{responseF} <- getsSession schanF
  liftIO $ atomically $ readTQueue responseF

-- | Write a UI request to the frontend.
writeConnFrontend :: MonadClientUI m => FrontReq -> m ()
writeConnFrontend efr = do
  ChanFrontend{requestF} <- getsSession schanF
  liftIO $ atomically $ writeTQueue requestF efr

promptGetKey :: MonadClientUI m => [K.KM] -> SingleFrame -> m K.KM
promptGetKey frontKM frontFr = do
  escPressed <- tryTakeMVarSescMVar  -- this also clears the ESC-pressed  marker
  lastPlayOld <- getsClient slastPlay
  km <- case lastPlayOld of
    km : kms | not escPressed && (null frontKM || km `elem` frontKM) -> do
      displayFrame True $ Just frontFr
      -- Sync frames so that ESC doesn't skip frames.
      syncFrames
      modifyClient $ \cli -> cli {slastPlay = kms}
      return km
    _ -> do
      unless (null lastPlayOld) stopPlayBack  -- we can't continue playback
      writeConnFrontend FrontKey{..}
      readConnFrontend
  (seqCurrent, seqPrevious, k) <- getsClient slastRecord
  let slastRecord = (km : seqCurrent, seqPrevious, k)
  modifyClient $ \cli -> cli {slastRecord}
  return km

-- | Display an overlay and wait for a human player command.
getKeyOverlayCommand :: MonadClientUI m => Bool -> Overlay -> m K.KM
getKeyOverlayCommand onBlank overlay = do
  frame <- drawOverlay onBlank ColorFull overlay
  promptGetKey [] frame

-- | Display a slideshow, awaiting confirmation for each slide except the last.
getInitConfirms :: MonadClientUI m
                => ColorMode -> [K.KM] -> Slideshow -> m Bool
getInitConfirms dm frontClear slides = do
  let (onBlank, ovs) = slideshow slides
  frontSlides <- drawOverlays onBlank dm ovs
  -- The first two cases are optimizations:
  case frontSlides of
    [] -> return True
    [x] -> do
      displayFrame False $ Just x
      return True
    _ -> do
      writeConnFrontend FrontSlides{..}
      km <- readConnFrontend
      -- Don't clear ESC marker here, because the wait for confirms may
      -- block a ping and the ping would not see the ESC.
      return $! km /= K.escKM

displayFrame :: MonadClientUI m => Bool -> Maybe SingleFrame -> m ()
displayFrame isRunning mf = do
  let frame = case mf of
        Nothing -> FrontDelay
        Just fr | isRunning -> FrontRunningFrame fr
        Just fr -> FrontNormalFrame fr
  writeConnFrontend frame

displayDelay :: MonadClientUI m =>  m ()
displayDelay = writeConnFrontend FrontDelay

-- | Push frames or delays to the frame queue.
displayFrames :: MonadClientUI m => Frames -> m ()
displayFrames = mapM_ (displayFrame False)

-- | Push frames or delays to the frame queue. Additionally set @sdisplayed@.
-- because animations not always happen after @SfxActorStart@ on the leader's
-- level (e.g., death can lead to leader change to another level mid-turn,
-- and there could be melee and animations on that level at the same moment).
displayActorStart :: MonadClientUI m => Actor -> Frames -> m ()
displayActorStart b frs = do
  mapM_ (displayFrame False) frs
  let ageDisp displayed = EM.insert (blid b) (btime b) displayed
  modifyClient $ \cli -> cli {sdisplayed = ageDisp $ sdisplayed cli}

-- | Draw the current level with the overlay on top.
drawOverlay :: MonadClientUI m => Bool -> ColorMode -> Overlay -> m SingleFrame
drawOverlay sfBlank@True _ sfTop = do
  let sfLevel = []
      sfBottom = []
  return $! SingleFrame {..}
drawOverlay sfBlank@False dm sfTop = do
  lid <- viewedLevel
  mleader <- getsClient _sleader
  tgtPos <- leaderTgtToPos
  cursorPos <- cursorToPos
  let anyPos = fromMaybe (Point 0 0) cursorPos
      pathFromLeader leader = fmap Just $ getCacheBfsAndPath leader anyPos
  bfsmpath <- maybe (return Nothing) pathFromLeader mleader
  tgtDesc <- maybe (return ("------", Nothing)) targetDescLeader mleader
  cursorDesc <- targetDescCursor
  draw sfBlank dm lid cursorPos tgtPos bfsmpath cursorDesc tgtDesc sfTop

drawOverlays :: MonadClientUI m
             => Bool -> ColorMode -> [Overlay] -> m [SingleFrame]
drawOverlays _ _ [] = return []
drawOverlays sfBlank dm (topFirst : rest) = do
  fistFrame <- drawOverlay sfBlank dm topFirst
  let f topNext = fistFrame {sfTop = topNext}
  return $! fistFrame : map f rest  -- keep @rest@ lazy for responsiveness

stopPlayBack :: MonadClientUI m => m ()
stopPlayBack = do
  modifyClient $ \cli -> cli
    { slastPlay = []
    , slastRecord = let (seqCurrent, seqPrevious, _) = slastRecord cli
                    in (seqCurrent, seqPrevious, 0)
    , swaitTimes = - swaitTimes cli
    }
  stopRunning

stopRunning :: MonadClientUI m => m ()
stopRunning = do
  srunning <- getsClient srunning
  case srunning of
    Nothing -> return ()
    Just RunParams{runLeader} -> do
      -- Switch to the original leader, from before the run start,
      -- unless dead or unless the faction never runs with multiple
      -- (but could have the leader changed automatically meanwhile).
      side <- getsClient sside
      fact <- getsState $ (EM.! side) . sfactionD
      arena <- getArenaUI
      s <- getState
      when (memActor runLeader arena s && not (noRunWithMulti fact)) $
        modifyClient $ updateLeader runLeader s
      modifyClient (\cli -> cli { srunning = Nothing })

askConfig :: MonadClientUI m => m Config
askConfig = getsSession sconfig

-- | Get the key binding.
askBinding :: MonadClientUI m => m Binding
askBinding = getsSession sbinding

-- | Sync frames display with the frontend.
syncFrames :: MonadClientUI m => m ()
syncFrames = do
  -- Hack.
  writeConnFrontend FrontSlides{frontClear=[], frontSlides=[]}
  km <- readConnFrontend
  assert (km == K.spaceKM) skip

tryTakeMVarSescMVar :: MonadClientUI m => m Bool
tryTakeMVarSescMVar = do
  mescMVar <- getsSession sescMVar
  case mescMVar of
    Nothing -> return False
    Just escMVar -> do
      mUnit <- liftIO $ tryTakeMVar escMVar
      return $ isJust mUnit

scoreToSlideshow :: MonadClientUI m => Int -> Status -> m Slideshow
scoreToSlideshow total status = do
  fid <- getsClient sside
  fact <- getsState $ (EM.! fid) . sfactionD
  -- TODO: Re-read the table in case it's changed by a concurrent game.
  -- TODO: we should do this, and make sure we do that after server
  -- saved the updated score table, and not register, but read from it.
  -- Otherwise the score is not accurate, e.g., the number of victims.
  table <- getsState shigh
  time <- getsState stime
  date <- liftIO getClockTime
  scurDifficulty <- getsClient scurDifficulty
  factionD <- getsState sfactionD
  loots <- factionLoots fid
  let showScore (ntable, pos) = HighScore.highSlideshow ntable pos
      diff | not $ fhasUI $ gplayer fact = difficultyDefault
           | otherwise = scurDifficulty
      theirVic (fi, fa) | isAtWar fact fi
                          && not (isHorrorFact fa) = Just $ gvictims fa
                        | otherwise = Nothing
      theirVictims = EM.unionsWith (+) $ mapMaybe theirVic $ EM.assocs factionD
      ourVic (fi, fa) | isAllied fact fi || fi == fid = Just $ gvictims fa
                      | otherwise = Nothing
      ourVictims = EM.unionsWith (+) $ mapMaybe ourVic $ EM.assocs factionD
      (worthMentioning, rScore) =
        HighScore.register table total time status date diff
                           (fname $ gplayer fact)
                           ourVictims theirVictims loots
  return $! if worthMentioning then showScore rScore else mempty

getLeaderUI :: MonadClientUI m => m ActorId
getLeaderUI = do
  cli <- getClient
  case _sleader cli of
    Nothing -> assert `failure` "leader expected but not found" `twith` cli
    Just leader -> return leader

getArenaUI :: MonadClientUI m => m LevelId
getArenaUI = do
  mleader <- getsClient _sleader
  case mleader of
    Just leader -> getsState $ blid . getActorBody leader
    Nothing -> do
      side <- getsClient sside
      fact <- getsState $ (EM.! side) . sfactionD
      case gquit fact of
        Just Status{stDepth} -> return $! toEnum stDepth
        Nothing -> do
          dungeon <- getsState sdungeon
          let (minD, maxD) =
                case (EM.minViewWithKey dungeon, EM.maxViewWithKey dungeon) of
                  (Just ((s, _), _), Just ((e, _), _)) -> (s, e)
                  _ -> assert `failure` "empty dungeon" `twith` dungeon
          return $! max minD $ min maxD $ toEnum $ fentryLevel $ gplayer fact

viewedLevel :: MonadClientUI m => m LevelId
viewedLevel = do
  arena <- getArenaUI
  stgtMode <- getsClient stgtMode
  return $! maybe arena tgtLevelId stgtMode

targetDesc :: MonadClientUI m => Maybe Target -> m (Text, Maybe Text)
targetDesc target = do
  lidV <- viewedLevel
  mleader <- getsClient _sleader
  case target of
    Just (TEnemy aid _) -> do
      side <- getsClient sside
      b <- getsState $ getActorBody aid
      maxHP <- sumOrganEqpClient Effect.EqpSlotAddMaxHP aid
      let percentage = 100 * bhp b `div` xM (max 5 maxHP)
          stars | percentage < 20  = "[_____]"
                | percentage < 40  = "[*____]"
                | percentage < 60  = "[**___]"
                | percentage < 80  = "[***__]"
                | percentage < 100 = "[****_]"
                | otherwise        = "[*****]"
          hpIndicator = if bfid b == side then Nothing else Just stars
      return (bname b, hpIndicator)
    Just (TEnemyPos _ lid p _) -> do
      let hotText = if lid == lidV
                    then "hot spot" <+> (T.pack . show) p
                    else "a hot spot on level" <+> tshow (abs $ fromEnum lid)
      return (hotText, Nothing)
    Just (TPoint lid p) -> do
      pointedText <-
        if lid == lidV
        then do
          lvl <- getLevel lid
          case EM.assocs $ lvl `atI` p of
            [] -> return $! "exact spot" <+> (T.pack . show) p
            [(iid, k)] -> do
              itemToF <- itemToFullClient
              let (name, stats) = partItem CGround (itemToF iid k)
              return $! makePhrase $ if k == 1
                                     then [name, stats]  -- "a sword" too wordy
                                     else [MU.CarWs k name, stats]
            _ -> return $! "many items at" <+> (T.pack . show) p
        else return $! "an exact spot on level" <+> tshow (abs $ fromEnum lid)
      return (pointedText, Nothing)
    Just TVector{} ->
      case mleader of
        Nothing -> return ("a relative shift", Nothing)
        Just aid -> do
          tgtPos <- aidTgtToPos aid lidV target
          let invalidMsg = "an invalid relative shift"
              validMsg p = "shift to" <+> (T.pack . show) p
          return (maybe invalidMsg validMsg tgtPos, Nothing)
    Nothing -> return ("cursor location", Nothing)

targetDescLeader :: MonadClientUI m => ActorId -> m (Text, Maybe Text)
targetDescLeader leader = do
  tgt <- getsClient $ getTarget leader
  targetDesc tgt

targetDescCursor :: MonadClientUI m => m (Text, Maybe Text)
targetDescCursor = do
  scursor <- getsClient scursor
  targetDesc $ Just scursor

leaderTgtToPos :: MonadClientUI m => m (Maybe Point)
leaderTgtToPos = do
  lidV <- viewedLevel
  mleader <- getsClient _sleader
  case mleader of
    Nothing -> return Nothing
    Just aid -> do
      tgt <- getsClient $ getTarget aid
      aidTgtToPos aid lidV tgt

leaderTgtAims :: MonadClientUI m => m (Either Text Int)
leaderTgtAims = do
  lidV <- viewedLevel
  mleader <- getsClient _sleader
  case mleader of
    Nothing -> return $ Left "no leader to target with"
    Just aid -> do
      tgt <- getsClient $ getTarget aid
      aidTgtAims aid lidV tgt

cursorToPos :: MonadClientUI m => m (Maybe Point)
cursorToPos = do
  lidV <- viewedLevel
  mleader <- getsClient _sleader
  scursor <- getsClient scursor
  case mleader of
    Nothing -> return Nothing
    Just aid -> aidTgtToPos aid lidV $ Just scursor
