{-# LANGUAGE OverloadedStrings, RankNTypes #-}
-- | Game action monads and basic building blocks for human and computer
-- player actions. Has no access to the the main action type.
-- Does not export the @liftIO@ operation nor a few other implementation
-- details.
module Game.LambdaHack.Client.Action
  ( -- * Action monads
    MonadClientRO( getClient, getsClient )
  , MonadClient( putClient, modifyClient )
  , MonadClientUI
  , MonadClientChan
  , executorCli, exeFrontend, frontendName
    -- * Abort exception handlers
  , tryWithSlide
    -- * Accessors to the game session Reader and the Perception Reader(-like)
  , askBinding, askPerception
    -- * History and report
  , msgAdd, recordHistory
    -- * Key input
  , getKeyCommand, getKeyOverlayCommand, getManyConfirms
    -- * Display and key input
  , displayFramesPush, displayMore, displayYesNo, displayChoiceUI
    -- * Generate slideshows
  , promptToSlideshow, overlayToSlideshow
    -- * Draw frames
  , drawOverlay
    -- * Turn init operations
  , rememberLevel, displayPush
    -- * Assorted primitives
  , clientGameSave, clientDisconnect, restoreGame
  , readChanFromSer, writeChanToSer
  ) where

import Control.Concurrent
import Control.Monad
import Control.Monad.Writer.Strict (WriterT, lift, tell)
import Data.Dynamic
import qualified Data.EnumMap.Strict as EM
import qualified Data.Map as M
import Data.Maybe
import qualified Data.EnumSet as ES

import Game.LambdaHack.Action
import Game.LambdaHack.Actor
import Game.LambdaHack.Client.Action.ActionClass
import Game.LambdaHack.Client.Action.ActionType (executorCli)
import Game.LambdaHack.Client.Action.ConfigIO
import Game.LambdaHack.Client.Action.Frontend (frontendName, startup)
import qualified Game.LambdaHack.Client.Action.Frontend as Frontend
import qualified Game.LambdaHack.Client.Action.Save as Save
import Game.LambdaHack.Client.Animation (Frames, SingleFrame)
import Game.LambdaHack.Client.Binding
import Game.LambdaHack.Client.Config
import Game.LambdaHack.Client.Draw
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Client.State
import Game.LambdaHack.CmdCli
import Game.LambdaHack.Content.RuleKind
import Game.LambdaHack.Faction
import qualified Game.LambdaHack.Kind as Kind
import Game.LambdaHack.Level
import Game.LambdaHack.Msg
import Game.LambdaHack.Perception
import Game.LambdaHack.State
import qualified Game.LambdaHack.Tile as Tile
import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Point

displayFrame :: MonadClientUI m => Bool -> Maybe SingleFrame -> m ()
displayFrame isRunning mf = do
  fs <- askFrontendSession
  faction <- getsState sfaction
  case filter isHumanFact $ EM.elems faction of
    _ : _ : _ ->
      -- More than one human player; don't mix the output
      modifyClient $ \cli -> cli {sframe = (mf, isRunning) : sframe cli}
    _ ->
      -- At most one human player, display everything at once.
      liftIO $ Frontend.displayFrame fs isRunning mf

flushFrames :: MonadClientUI m => m ()
flushFrames = do
  fs <- askFrontendSession
  sframe <- getsClient sframe
  liftIO $ mapM_ (\(mf, b) -> Frontend.displayFrame fs b mf) $ reverse sframe
  modifyClient $ \cli -> cli {sframe = []}

nextEvent :: MonadClientUI m => Maybe Bool -> m K.KM
nextEvent mb = do
  fs <- askFrontendSession
  flushFrames
  liftIO $ Frontend.nextEvent fs mb

promptGetKey :: MonadClientUI m => [K.KM] -> SingleFrame -> m K.KM
promptGetKey keys frame = do
  fs <- askFrontendSession
  flushFrames
  liftIO $ Frontend.promptGetKey fs keys frame

-- | Set the current exception handler. Apart of executing it,
-- draw and pass along a slide with the abort message (even if message empty).
tryWithSlide :: MonadClient m
             => m a -> WriterT Slideshow m a -> WriterT Slideshow m a
tryWithSlide exc h =
  let excMsg msg = do
        msgReset ""
        slides <- promptToSlideshow msg
        tell slides
        lift exc
  in tryWith excMsg h

-- | Get the frontend session.
askFrontendSession :: MonadClientUI m => m Frontend.FrontendSession
askFrontendSession = getsSession sfs

-- | Get the key binding.
askBinding :: MonadClientUI m => m Binding
askBinding = getsSession sbinding

-- | Add a message to the current report.
msgAdd :: MonadClient m => Msg -> m ()
msgAdd msg = modifyClient $ \d -> d {sreport = addMsg (sreport d) msg}

-- | Wipe out and set a new value for the current report.
msgReset :: MonadClient m => Msg -> m ()
msgReset msg = modifyClient $ \d -> d {sreport = singletonReport msg}

-- | Store current report in the history and reset report.
recordHistory :: MonadClient m => m ()
recordHistory = do
  StateClient{sreport, shistory} <- getClient
  unless (nullReport sreport) $ do
    ConfigUI{configHistoryMax} <- getsClient sconfigUI
    msgReset ""
    let nhistory = takeHistory configHistoryMax $! addReport sreport shistory
    modifyClient $ \cli -> cli {shistory = nhistory}

-- | Get the current perception of a client.
askPerception :: MonadClientRO m => m Perception
askPerception = do
  stgtMode <- getsClient stgtMode
  arena <- getsState sarena
  let lid = maybe arena tgtLevelId stgtMode
  factionPers <- getsClient sper
  return $! fromMaybe (assert `failure` lid) $ M.lookup lid factionPers

-- | Wait for a human player command.
getKeyCommand :: MonadClientUI m => Maybe Bool -> m K.KM
getKeyCommand doPush = do
  keyb <- askBinding
  (nc, modifier) <- nextEvent doPush
  return $! case modifier of
    K.NoModifier -> (fromMaybe nc $ M.lookup nc $ kmacro keyb, modifier)
    _ -> (nc, modifier)

-- | Display an overlay and wait for a human player command.
getKeyOverlayCommand :: MonadClientUI m => Overlay -> m K.KM
getKeyOverlayCommand overlay = do
  frame <- drawOverlay ColorFull overlay
  keyb <- askBinding
  (nc, modifier) <- promptGetKey [] frame
  return $! case modifier of
    K.NoModifier -> (fromMaybe nc $ M.lookup nc $ kmacro keyb, modifier)
    _ -> (nc, modifier)

-- | Ignore unexpected kestrokes until a SPACE or ESC is pressed.
getConfirm :: MonadClientUI m => [K.KM] -> SingleFrame -> m Bool
getConfirm clearKeys frame = do
  let keys = [(K.Space, K.NoModifier), (K.Esc, K.NoModifier)] ++ clearKeys
  km <- promptGetKey keys frame
  case km of
    (K.Space, K.NoModifier) -> return True
    _ | km `elem` clearKeys -> return True
    _ -> return False

-- | Display a slideshow, awaiting confirmation for each slide.
getManyConfirms :: MonadClientUI m => [K.KM] -> Slideshow -> m Bool
getManyConfirms clearKeys slides =
  case runSlideshow slides of
    [] -> return True
    x : xs -> do
      frame <- drawOverlay ColorFull x
      b <- getConfirm clearKeys frame
      if b
        then getManyConfirms clearKeys (toSlideshow xs)
        else return False

-- | Push frames or frame's worth of delay to the frame queue.
displayFramesPush :: MonadClientUI m => Frames -> m ()
displayFramesPush frames = mapM_ (displayFrame False) frames

-- | A yes-no confirmation.
getYesNo :: MonadClientUI m => SingleFrame -> m Bool
getYesNo frame = do
  let keys = [ (K.Char 'y', K.NoModifier)
             , (K.Char 'n', K.NoModifier)
             , (K.Esc, K.NoModifier)
             ]
  (k, _) <- promptGetKey keys frame
  case k of
    K.Char 'y' -> return True
    _          -> return False

-- | Display a msg with a @more@ prompt. Return value indicates if the player
-- tried to cancel/escape.
displayMore :: MonadClientUI m => ColorMode -> Msg -> m Bool
displayMore dm prompt = do
  sli <- promptToSlideshow $ prompt <+> moreMsg
  frame <- drawOverlay dm $ head $ runSlideshow sli
  getConfirm [] frame

-- | Print a yes/no question and return the player's answer. Use black
-- and white colours to turn player's attention to the choice.
displayYesNo :: MonadClientUI m => Msg -> m Bool
displayYesNo prompt = do
  sli <- promptToSlideshow $ prompt <+> yesnoMsg
  frame <- drawOverlay ColorBW $ head $ runSlideshow sli
  getYesNo frame

-- TODO: generalize getManyConfirms and displayChoiceUI to a single op
-- | Print a prompt and an overlay and wait for a player keypress.
-- If many overlays, scroll screenfuls with SPACE. Do not wrap screenfuls
-- (in some menus @?@ cycles views, so the user can restart from the top).
displayChoiceUI :: MonadClientUI m => Msg -> Overlay -> [K.KM] -> m K.KM
displayChoiceUI prompt ov keys = do
  slides <- fmap runSlideshow $ overlayToSlideshow (prompt <> ", ESC]") ov
  let legalKeys = (K.Space, K.NoModifier) : (K.Esc, K.NoModifier) : keys
      loop [] = neverMind True
      loop (x : xs) = do
        frame <- drawOverlay ColorFull x
        (key, modifier) <- promptGetKey legalKeys frame
        case key of
          K.Esc -> neverMind True
          K.Space -> loop xs
          _ -> return (key, modifier)
  loop slides

-- | The prompt is shown after the current message, but not added to history.
-- This is useful, e.g., in targeting mode, not to spam history.
promptToSlideshow :: MonadClientRO m => Msg -> m Slideshow
promptToSlideshow prompt = overlayToSlideshow prompt []

-- | The prompt is shown after the current message at the top of each slide.
-- Together they may take more than one line. The prompt is not added
-- to history. The portions of overlay that fit on the the rest
-- of the screen are displayed below. As many slides as needed are shown.
overlayToSlideshow :: MonadClientRO m => Msg -> Overlay -> m Slideshow
overlayToSlideshow prompt overlay = do
  lysize <- getsState (lysize . getArena)  -- TODO: screen length or viewLevel
  sreport <- getsClient sreport
  let msg = splitReport (addMsg sreport prompt)
  return $! splitOverlay lysize msg overlay

-- | Draw the current level with the overlay on top.
drawOverlay :: MonadClientRO m => ColorMode -> Overlay -> m SingleFrame
drawOverlay dm over = do
  cops <- getsState scops
  per <- askPerception
  cli <- getClient
  loc <- getState
  return $! draw dm cops per cli loc over

-- -- | Draw the current level using server data, for debugging.
-- drawOverlayDebug :: MonadServerRO m
--                  => ColorMode -> Overlay -> m SingleFrame
-- drawOverlayDebug dm over = do
--   cops <- getsState scops
--   per <- askPerception
--   cli <- getClient
--   glo <- getState
--   return $! draw dm cops per cli glo over

-- | Push the frame depicting the current level to the frame queue.
-- Only one screenful of the report is shown, the rest is ignored.
displayPush :: MonadClientUI m => m ()
displayPush = do
  sls <- promptToSlideshow ""
  let slide = head $ runSlideshow sls
--  DebugModeCli{somniscient} <- getsClient sdebugCli
  frame <- drawOverlay ColorFull slide
--  frame <- if somniscient
--           then drawOverlayDebug ColorFull slide
--           else drawOverlay ColorFull slide
  -- Visually speed up (by remving all empty frames) the show of the sequence
  -- of the move frames if the player is running.
  srunning <- getsClient srunning
  displayFrame (isJust srunning) $ Just frame

-- | Update faction memory at the given set of positions.
rememberLevel :: Kind.COps -> ES.EnumSet Point -> Level -> Level -> Level
rememberLevel Kind.COps{cotile=cotile@Kind.Ops{ouniqGroup}} visible lvl clvl =
  -- TODO: handle invisible actors, but then change also broadcastPosCli, etc.
  let nactor = EM.filter (\m -> bpos m `ES.member` visible) (lactor lvl)
      ninv   = EM.filterWithKey (\p _ -> p `EM.member` nactor) (linv lvl)
      alt Nothing   _ = Nothing
      alt (Just []) _ = assert `failure` lvl
      alt x         _ = x
      rememberItem p m = EM.alter (alt $ EM.lookup p $ litem lvl) p m
      vis = ES.toList visible
      rememberTile = [(pos, lvl `at` pos) | pos <- vis]
      unknownId = ouniqGroup "unknown space"
      eSeen (pos, tk) = clvl `at` pos == unknownId
                        && Tile.isExplorable cotile tk
      extraSeen = length $ filter eSeen rememberTile
  in clvl { lactor = nactor
          , linv = ninv
          , litem = foldr rememberItem (litem clvl) vis
          , ltile = ltile clvl Kind.// rememberTile
  -- TODO: update enemy smell probably only around a sniffing party member
          , lsmell = lsmell lvl
          , lseen = lseen clvl + extraSeen
          , ltime = ltime lvl
  -- TODO: let factions that spawn see hidden features and open all hidden
  -- doors (they built and hid them). Hide the Hidden feature in ltile.
  -- Wait with all that until the semantics of (repeated) searching
  -- is changed.
          , lsecret = EM.empty
          }

saveName :: FactionId -> Bool -> String
saveName side isAI = show (fromEnum side)
                     ++ if isAI then ".ai.sav" else ".human.sav"

clientGameSave :: MonadClient m => Bool -> Bool -> m ()
clientGameSave toBkp isAI = do
  s <- getState
  cli <- getClient
  configUI <- getsClient sconfigUI
  side <- getsState sside
  liftIO $ Save.saveGameCli (saveName side isAI) toBkp configUI s cli

clientDisconnect :: MonadClient m => Bool -> m ()
clientDisconnect isAI = do
--  flushFrames  -- this would force MonadClientUI
  modifyState $ updateQuit $ const $ Just False
  clientGameSave False isAI

restoreGame :: MonadClient m
            => Bool
            -> m (Either (State, StateClient, Msg) Msg)
restoreGame isAI = do
  Kind.COps{corule} <- getsState scops
  configUI <- getsClient sconfigUI
  let pathsDataFile = rpathsDataFile $ Kind.stdRuleset corule
      title = rtitle $ Kind.stdRuleset corule
  side <- getsState sside
  let sName = saveName side isAI
  liftIO $ Save.restoreGameCli sName configUI pathsDataFile title

readChanFromSer :: MonadClientChan m => m (Either CmdCli CmdUI)
readChanFromSer = do
  toClient <- getsChan toClient
  liftIO $ readChan toClient

writeChanToSer :: MonadClientChan m => Dynamic -> m ()
writeChanToSer cmd = do
  toServer <- getsChan toServer
  liftIO $ writeChan toServer cmd

-- | Wire together game content, the main loop of game clients,
-- the main game loop assigned to this frontend (possibly containing
-- the server loop, if the whole game runs in one process),
-- UI config and the definitions of game commands.
exeFrontend :: Kind.COps
            -> (Bool -> SessionUI -> State -> StateClient -> ConnCli -> IO ())
            -> ((FactionId -> ConnCli -> Bool -> IO ()) -> a)
            -> (a -> IO ())
            -> IO ()
exeFrontend cops@Kind.COps{corule} executorC connectClients loopFrontend = do
  -- UI config reloaded at each client start.
  sconfigUI <- mkConfigUI corule
  let !sbinding = stdBinding sconfigUI  -- evaluate to check for errors
      font = configFont sconfigUI
  defHist <- defHistory
  let cli = defStateClient defHist sconfigUI
      exe sfs fid chanCli hasUI =
        executorC hasUI SessionUI{..} (defStateLocal cops fid) cli chanCli
  startup font $ \sfs -> loopFrontend (connectClients (exe sfs))