{-# LANGUAGE DataKinds #-}
-- | Common client monad operations.
module Game.LambdaHack.Client.CommonClient
  ( getPerFid, aidTgtToPos, aidTgtAims, makeLine
  , partAidLeader, partActorLeader, partPronounLeader
  , actorAbilities, updateItemSlot, fullAssocsClient, itemToFullClient
  , pickWeaponClient, actorBlindClient
  ) where

import Control.Exception.Assert.Sugar
import qualified Data.EnumMap.Strict as EM
import qualified Data.IntMap.Strict as IM
import Data.List
import Data.Maybe
import Data.Text (Text)
import Data.Tuple
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Client.ItemSlot
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import Game.LambdaHack.Common.Ability
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemStrongest
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Perception
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.Request
import Game.LambdaHack.Common.State
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.FactionKind

-- | Get the current perception of a client.
getPerFid :: MonadClient m => LevelId -> m Perception
getPerFid lid = do
  fper <- getsClient sfper
  return $! fromMaybe (assert `failure` "no perception at given level"
                              `twith` (lid, fper))
                      $ EM.lookup lid fper

-- | The part of speech describing the actor or "you" if a leader
-- of the client's faction. The actor may be not present in the dungeon.
partActorLeader :: MonadClient m => ActorId -> Actor -> m MU.Part
partActorLeader aid b = do
  mleader <- getsClient _sleader
  return $! case mleader of
    Just leader | aid == leader -> "you"
    _ -> partActor b

-- | The part of speech with the actor's pronoun or "you" if a leader
-- of the client's faction. The actor may be not present in the dungeon.
partPronounLeader :: MonadClient m => ActorId -> Actor -> m MU.Part
partPronounLeader aid b = do
  mleader <- getsClient _sleader
  return $! case mleader of
    Just leader | aid == leader -> "you"
    _ -> partPronoun b

-- | The part of speech describing the actor (designated by actor id
-- and present in the dungeon) or a special name if a leader
-- of the observer's faction.
partAidLeader :: MonadClient m => ActorId -> m MU.Part
partAidLeader aid = do
  b <- getsState $ getActorBody aid
  partActorLeader aid b

-- | Calculate the position of an actor's target.
aidTgtToPos :: MonadClient m
            => ActorId -> LevelId -> Maybe Target -> m (Maybe Point)
aidTgtToPos aid lidV tgt =
  case tgt of
    Just (TEnemy a _) -> do
      body <- getsState $ getActorBody a
      return $! if blid body == lidV
                then Just (bpos body)
                else Nothing
    Just (TEnemyPos _ lid p _) ->
      return $! if lid == lidV then Just p else Nothing
    Just (TPoint lid p) ->
      return $! if lid == lidV then Just p else Nothing
    Just (TVector v) -> do
      b <- getsState $ getActorBody aid
      Level{lxsize, lysize} <- getLevel lidV
      let shifted = shiftBounded lxsize lysize (bpos b) v
      return $! if shifted == bpos b && v /= Vector 0 0
                then Nothing
                else Just shifted
    Nothing -> do
      scursor <- getsClient scursor
      aidTgtToPos aid lidV $ Just scursor

-- | Check whether one is permitted to aim at a target
-- (this is only checked for actors; positions let player
-- shoot at obstacles, e.g., to destroy them).
-- This assumes @aidTgtToPos@ does not return @Nothing@.
-- Returns a different @seps@, if needed to reach the target actor.
--
-- Note: Perception is not enough for the check,
-- because the target actor can be obscured by a glass wall
-- or be out of sight range, but in weapon range.
aidTgtAims :: MonadClient m
           => ActorId -> LevelId -> Maybe Target -> m (Either Text Int)
aidTgtAims aid lidV tgt = do
  oldEps <- getsClient seps
  case tgt of
    Just (TEnemy a _) -> do
      body <- getsState $ getActorBody a
      let pos = bpos body
      b <- getsState $ getActorBody aid
      if blid b == lidV then do
        mnewEps <- makeLine b pos oldEps
        case mnewEps of
          Just newEps -> return $ Right newEps
          Nothing -> return $ Left "aiming line to the opponent blocked"
      else return $ Left "target opponent not on this level"
    Just TEnemyPos{} -> return $ Left "target opponent not visible"
    Just TPoint{} -> return $ Right oldEps
    Just TVector{} -> return $ Right oldEps
    Nothing -> do
      scursor <- getsClient scursor
      aidTgtAims aid lidV $ Just scursor

-- | Counts the number of steps until the projectile would hit
-- an actor or obstacle. Starts searching with the given eps and returns
-- the first found eps for which the number reaches the distance between
-- actor and target position, or Nothing if none can be found.
makeLine :: MonadClient m => Actor -> Point -> Int -> m (Maybe Int)
makeLine body fpos epsOld = do
  cops@Kind.COps{cotile=Kind.Ops{ouniqGroup}} <- getsState scops
  lvl@Level{lxsize, lysize} <- getLevel (blid body)
  bs <- getsState $ filter (not . bproj)
                    . actorList (const True) (blid body)
  let unknownId = ouniqGroup "unknown space"
      dist = chessDist (bpos body) fpos
      calcScore eps = case bla lxsize lysize eps (bpos body) fpos of
        Just bl ->
          let blDist = take dist bl
              blZip = zip (bpos body : blDist) blDist
              noActor p = all ((/= p) . bpos) bs || p == fpos
              accessU = all noActor blDist
                        && all (uncurry $ accessibleUnknown cops lvl) blZip
              nUnknown = length $ filter ((== unknownId) . (lvl `at`)) blDist
          in if accessU then - nUnknown else minBound
        Nothing -> assert `failure` (body, fpos, epsOld)
      tryLines curEps (acc, _) | curEps >= epsOld + dist = acc
      tryLines curEps (acc, bestScore) =
        let curScore = calcScore curEps
            newAcc = if curScore > bestScore
                     then (Just curEps, curScore)
                     else (acc, bestScore)
        in tryLines (curEps + 1) newAcc
  return $! if dist <= 1
            then Nothing  -- ProjectBlockActor, ProjectAimOnself
            else tryLines epsOld (Nothing, minBound)

actorAbilities :: MonadClient m => ActorId -> Maybe ActorId -> m [Ability]
actorAbilities aid mleader = do
  Kind.COps{ coactor=Kind.Ops{okind}
           , cofaction=Kind.Ops{okind=fokind} } <- getsState scops
  body <- getsState $ getActorBody aid
  fact <- getsState $ (EM.! bfid body) . sfactionD
  let factionAbilities
        | Just aid == mleader = fAbilityLeader $ fokind $ gkind fact
        | otherwise = fAbilityOther $ fokind $ gkind fact
  return $! acanDo (okind $ bkind body) `intersect` factionAbilities

updateItemSlot :: MonadClient m => Maybe ActorId -> ItemId -> m ()
updateItemSlot maid iid = do
  slots@(letterSlots, numberSlots) <- getsClient sslots
  case ( lookup iid $ map swap $ EM.assocs letterSlots
       , lookup iid $ map swap $ IM.assocs numberSlots ) of
    (Nothing, Nothing) -> do
      side <- getsClient sside
      item <- getsState $ getItemBody iid
      lastSlot <- getsClient slastSlot
      mb <- maybe (return Nothing) (fmap Just . getsState . getActorBody) maid
      el <- getsState $ assignSlot item side mb slots lastSlot
      case el of
        Left l ->
          modifyClient $ \cli ->
            cli { sslots = (EM.insert l iid letterSlots, numberSlots)
                , slastSlot = max l (slastSlot cli) }
        Right l ->
          modifyClient $ \cli ->
            cli { sslots = (letterSlots, IM.insert l iid numberSlots) }
    _ -> return ()  -- slot already assigned a letter or a number

fullAssocsClient :: MonadClient m
                 => ActorId -> [CStore] -> m [(ItemId, ItemFull)]
fullAssocsClient aid cstores = do
  cops <- getsState scops
  disco <- getsClient sdisco
  discoAE <- getsClient sdiscoAE
  getsState $ fullAssocs cops disco discoAE aid cstores

itemToFullClient :: MonadClient m => m (ItemId -> KisOn -> ItemFull)
itemToFullClient = do
  cops <- getsState scops
  disco <- getsClient sdisco
  discoAE <- getsClient sdiscoAE
  s <- getState
  let itemToF iid = itemToFull cops disco discoAE iid (getItemBody iid s)
  return itemToF

-- Client has to choose the weapon based on its partial knowledge,
-- because if server chose it, it would leak item discovery information.
pickWeaponClient :: MonadClient m
                 => ActorId -> ActorId -> m (RequestTimed AbMelee)
pickWeaponClient source target = do
  cops <- getsState scops
  allAssocs <- fullAssocsClient source [CEqp, CBody]
  case strongestSword cops True allAssocs of
    [] -> assert `failure` (source, target, allAssocs)
    iis@((maxS, _) : _) -> do
      let maxIis = map snd $ takeWhile ((== maxS) . fst) iis
      -- TODO: pick the item according to the frequency of its kind.
      (iid, _) <- rndToAction $ oneOf maxIis
      return $! ReqMelee target iid

actorBlindClient :: MonadClient m => ActorId -> m Bool
actorBlindClient aid = do
  allAssocs <- fullAssocsClient aid [CEqp, CBody]
  let radius = case strongestSightRadius True allAssocs of
        [] -> 1  -- all actors feel adjacent positions (for easy exploration)
        (r, _) : _ -> r
  return $! radiusBlind radius
