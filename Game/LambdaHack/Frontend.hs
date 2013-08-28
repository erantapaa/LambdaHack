{-# LANGUAGE OverloadedStrings #-}
-- | Display game data on the screen and receive user input
-- using one of the available raw frontends and derived  operations.
module Game.LambdaHack.Frontend
  ( -- * Re-exported part of the raw frontend
    frontendName
    -- * Derived operation
  , startupF, getConfirmGeneric
    -- * Connection channels
  , ChanFrontend, FrontReq(..), ConnMulti(..), connMulti, loopFrontend
  ) where

import Control.Concurrent
import Control.Concurrent.STM (TQueue, atomically, newTQueueIO)
import qualified Control.Concurrent.STM as STM
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.Maybe
import System.IO.Unsafe (unsafePerformIO)

import Game.LambdaHack.Client.Animation
import qualified Game.LambdaHack.Client.Key as K
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Frontend.Chosen
import Game.LambdaHack.Utils.Assert
import Game.LambdaHack.Utils.LQueue

type ChanFrontend = TQueue K.KM

type FromMulti = MVar (Int, FactionId -> ChanFrontend)

type ToMulti = TQueue (FactionId, FrontReq)

data FrontReq =
    FrontFrame {frontAc :: !AcFrame}
      -- ^ show a frame, if the fid acitve, or save it to the client's queue
  | FrontKey {frontKM :: ![K.KM], frontFr :: !SingleFrame}
      -- ^ flush frames, possibly show fadeout/fadein and ask for a keypress
  | FrontSlides {frontClear :: [K.KM], frontSlides :: [SingleFrame]}
      -- ^ show a whole slideshow without interleaving with other clients

type ReqMap = EM.EnumMap FactionId (LQueue AcFrame)

-- | Multiplex connection channels, for the case of a frontend shared
-- among clients. This is transparent to the clients themselves.
data ConnMulti = ConnMulti
  { fromMulti :: FromMulti
  , toMulti   :: ToMulti
  }

startupF :: String -> IO () -> IO ()
startupF s k = startup s $ \fs -> do
  void $ forkIO $ loopFrontend fs connMulti
  k

-- | Display a prompt, wait for any of the specified keys (for any key,
-- if the list is empty). Repeat if an unexpected key received.
promptGetKey :: FrontendSession -> [K.KM] -> SingleFrame -> IO K.KM
promptGetKey sess keys frame = do
  km <- promptGetAnyKey sess frame
  if null keys || km `elem` keys
    then return km
    else promptGetKey sess keys frame

-- TODO: avoid unsafePerformIO; but server state is a wrong idea, too
connMulti :: ConnMulti
{-# NOINLINE connMulti #-}
connMulti = unsafePerformIO $ do
  fromMulti <- newMVar undefined
  toMulti <- newTQueueIO
  return ConnMulti{..}

getKeyGeneric :: Monad m
              => ([K.KM] -> a -> m b)
              -> [K.KM] -> a -> m b
getKeyGeneric pGetKey clearKeys x = do
  let keys = [ K.KM {key=K.Space, modifier=K.NoModifier}
             , K.KM {key=K.Esc, modifier=K.NoModifier} ]
             ++ clearKeys
  pGetKey keys x

isConfirm :: [K.KM] -> K.KM -> Bool
isConfirm clearKeys km =
  km == K.KM {key=K.Space, modifier=K.NoModifier}
  || km `elem` clearKeys

-- | Augment a function that takes and retuerns kyes.
getConfirmGeneric :: Monad m
                  => ([K.KM] -> a -> m K.KM)
                  -> [K.KM] -> a -> m Bool
getConfirmGeneric pGetKey clearKeys x = do
  km <- getKeyGeneric pGetKey clearKeys x
  return $! isConfirm clearKeys km

flushFrames :: FrontendSession -> FactionId -> ReqMap -> IO ReqMap
flushFrames fs fid reqMap = do
  let queue = toListLQueue $ fromMaybe newLQueue $ EM.lookup fid reqMap
      reqMap2 = EM.delete fid reqMap
  mapM_ (displayAc fs) queue
  return reqMap2

displayAc :: FrontendSession -> AcFrame -> IO ()
displayAc fs (AcConfirm fr) = void $ getConfirmGeneric (promptGetKey fs) [] fr
displayAc fs (AcRunning fr) = display fs True (Just fr)
displayAc fs (AcNormal fr) = display fs False (Just fr)
displayAc fs AcDelay = display fs False Nothing

getSingleFrame :: AcFrame -> Maybe (Bool, SingleFrame)
getSingleFrame (AcConfirm fr) = Just (False, fr)
getSingleFrame (AcRunning fr) = Just (True, fr)
getSingleFrame (AcNormal fr) = Just (False, fr)
getSingleFrame AcDelay = Nothing

toSingles :: FactionId -> ReqMap -> [(Bool, SingleFrame)]
toSingles fid reqMap =
  let queue = toListLQueue $ fromMaybe newLQueue $ EM.lookup fid reqMap
  in mapMaybe getSingleFrame queue

fadeF :: FrontendSession -> Bool -> FactionId -> SingleFrame -> IO ()
fadeF fs out side frame = do
  let topRight = True
      lxsize = xsizeSingleFrame frame
      lysize = ysizeSingleFrame frame
      msg = "Player" <+> showT (fromEnum side) <> ", get ready!"
  animMap <- rndToIO $ fadeout out topRight lxsize lysize
  let sfTop = truncateMsg lxsize msg
      basicFrame = frame {sfTop}
      animFrs = renderAnim lxsize lysize basicFrame animMap
      frs | out = animFrs
            -- Empty frame to mark the fade-in end,
            -- to trim only to here if SPACE pressed.
          | otherwise = animFrs ++ [Nothing]
  mapM_ (display fs False) frs

insertFr :: FactionId -> AcFrame -> ReqMap -> ReqMap
insertFr fid fr reqMap =
  let queue = fromMaybe newLQueue $ EM.lookup fid reqMap
  in EM.insert fid (writeLQueue queue fr) reqMap

-- TODO: save or display all at game save
-- Read UI requests from clients and send them to the frontend,
-- separated by fadeout/fadein frame sequences, if needed.
-- There may be many UI clients, but this function is only ever
-- executed on one thread, so the frontend receives requests
-- in a sequential way, without any random interleaving.
loopFrontend :: FrontendSession -> ConnMulti -> IO ()
loopFrontend fs ConnMulti{..} = loop Nothing EM.empty
 where
  writeKM :: FactionId -> K.KM -> IO ()
  writeKM fid km = do
    fM <- takeMVar fromMulti
    let chanFrontend = snd fM fid
    atomically $ STM.writeTQueue chanFrontend km
    putMVar fromMulti fM

  flushFade :: SingleFrame -> Maybe (FactionId, SingleFrame)
            -> ReqMap -> FactionId
            -> IO ReqMap
  flushFade frontFr oldFidFrame reqMap fid = do
    if Just fid == fmap fst oldFidFrame then
      return reqMap
    else do
      (nH, _) <- readMVar fromMulti
      reqMap2 <- case oldFidFrame of
        Nothing -> return reqMap
        Just (oldFid, oldFrame) -> do
          reqMap2 <- flushFrames fs oldFid reqMap
          let singles = toSingles oldFid reqMap  -- not @reqMap2@!
              (_, lastFrame) = fromMaybe (undefined, oldFrame)
                               $ listToMaybe $ reverse singles
              (running, _) = fromMaybe (False, undefined)
                             $ listToMaybe singles
          unless (running || nH < 2) $ fadeF fs True fid lastFrame
          return reqMap2
      let singles = toSingles fid reqMap2
          (running, firstFrame) = fromMaybe (False, frontFr)
                                  $ listToMaybe singles
      unless (running || nH < 2) $ fadeF fs False fid firstFrame
      flushFrames fs fid reqMap2

  loop :: Maybe (FactionId, SingleFrame) -> ReqMap -> IO ()
  loop oldFidFrame reqMap = do
    (fid, efr) <- atomically $ STM.readTQueue toMulti
    case efr of
      FrontFrame{..} | Just (oldFid, oldFrame) <- oldFidFrame
                     , fid == oldFid -> do
        displayAc fs frontAc
        let frame = maybe oldFrame snd $ getSingleFrame frontAc
        loop (Just (fid, frame)) reqMap
      FrontFrame{..} -> do
        let reqMap2 = insertFr fid frontAc reqMap
        loop oldFidFrame reqMap2
      FrontKey{..} -> do
        reqMap2 <- flushFade frontFr oldFidFrame reqMap fid
        km <- promptGetKey fs frontKM frontFr
        writeKM fid km
        loop (Just (fid, frontFr)) reqMap2
      FrontSlides{frontSlides = []} -> return ()
      FrontSlides{frontSlides = frontSlides@(fr1 : _), ..} -> do
        reqMap2 <- flushFade fr1 oldFidFrame reqMap fid
        let writeSpace =
              writeKM fid $ K.KM {key=K.Space, modifier=K.NoModifier}
            go frs = do
              case frs of
                [] -> assert `failure` fid
                [x] -> do
                  display fs False (Just x)
                  writeSpace
                  return x
                x : xs -> do
                  km <- getKeyGeneric (promptGetKey fs) frontClear x
                  if isConfirm frontClear km
                    then go xs
                    else do
                      writeKM fid km
                      return x
        frLast <- go frontSlides
        loop (Just (fid, frLast)) reqMap2