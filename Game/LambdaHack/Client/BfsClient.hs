{-# LANGUAGE CPP, TupleSections #-}
-- | Breadth first search and realted algorithms using the client monad.
module Game.LambdaHack.Client.BfsClient
  ( getCacheBfsAndPath, getCacheBfs, accessCacheBfs
  , unexploredDepth, closestUnknown, closestSuspect, closestSmell, furthestKnown
  , closestTriggers, closestItems, closestFoes
  ) where

import Control.Arrow ((&&&))
import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import qualified Data.EnumSet as ES
import Data.List
import Data.Maybe
import Data.Ord

import Game.LambdaHack.Client.Bfs
import Game.LambdaHack.Client.CommonClient
import Game.LambdaHack.Client.MonadClient
import Game.LambdaHack.Client.State
import qualified Game.LambdaHack.Common.Ability as Ability
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import qualified Game.LambdaHack.Common.PointArray as PointArray
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.State
import qualified Game.LambdaHack.Common.Tile as Tile
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.TileKind

-- | Get cached BFS data and path or, if not stored, generate,
-- store and return. Due to laziness, they are not calculated until needed.
getCacheBfsAndPath :: forall m. MonadClient m
                   => ActorId -> Point
                   -> m (PointArray.Array BfsDistance, Maybe [Point])
getCacheBfsAndPath aid target = do
  seps <- getsClient seps
  let pathAndStore :: PointArray.Array BfsDistance
                   -> m (PointArray.Array BfsDistance, Maybe [Point])
      pathAndStore bfs = do
        computePath <- computePathBFS aid
        let mpath = computePath target seps bfs
        modifyClient $ \cli ->
          cli {sbfsD = EM.insert aid (bfs, target, seps, mpath) (sbfsD cli)}
        return (bfs, mpath)
  mbfs <- getsClient $ EM.lookup aid . sbfsD
  case mbfs of
    Just (bfs, targetOld, sepsOld, mpath) | targetOld == target
                                            && sepsOld == seps ->
      return (bfs, mpath)
    Just (bfs, _, _, _) -> pathAndStore bfs
    Nothing -> do
      bfs <- computeBFS aid
      pathAndStore bfs

getCacheBfs :: MonadClient m => ActorId -> m (PointArray.Array BfsDistance)
{-# INLINE getCacheBfs #-}
getCacheBfs aid = do
  mbfs <- getsClient $ EM.lookup aid . sbfsD
  case mbfs of
    Just (bfs, _, _, _) -> return bfs
    Nothing -> fmap fst $ getCacheBfsAndPath aid (Point 0 0)

computeBFS :: MonadClient m => ActorId -> m (PointArray.Array BfsDistance)
computeBFS = computeAnythingBFS $ \isEnterable passUnknown aid -> do
  b <- getsState $ getActorBody aid
  Level{lxsize, lysize} <- getLevel $ blid b
  let origin = bpos b
      vInitial = PointArray.replicateA lxsize lysize apartBfs
  -- Here we don't want '$!', because we want the BFS data lazy.
  return ${-keep it!-} fillBfs isEnterable passUnknown origin vInitial

computePathBFS :: MonadClient m
               => ActorId
               -> m (Point -> Int -> PointArray.Array BfsDistance
                     -> Maybe [Point])
computePathBFS = computeAnythingBFS $ \isEnterable passUnknown aid -> do
  b <- getsState $ getActorBody aid
  let origin = bpos b
  -- Here we don't want '$!', because we want the BFS data lazy.
  return ${-keep it!-} findPathBfs isEnterable passUnknown origin

computeAnythingBFS :: MonadClient m
                   => ((Point -> Point -> MoveLegal)
                       -> (Point -> Point -> Bool)
                       -> ActorId
                       -> m a)
                   -> ActorId
                   -> m a
computeAnythingBFS fAnything aid = do
  cops@Kind.COps{cotile=cotile@Kind.Ops{ouniqGroup}} <- getsState scops
  b <- getsState $ getActorBody aid
  -- We assume the actor eventually becomes a leader (or has the same
  -- set of abilities as the leader, anyway). Otherwise we'd have
  -- to reset BFS after leader changes, but it would still lead to
  -- wasted movement if, e.g., non-leaders move but only leaders open doors
  -- and leader change is very rare.
  actorSk <- maxActorSkillsClient aid
  lvl <- getLevel $ blid b
  -- We treat doors as an open tile and don't add an extra step for opening
  -- the doors, because other actors open and use them, too,
  -- so it's amortized. We treat unknown tiles specially.
  let unknownId = ouniqGroup "unknown space"
      chAccess = checkAccess cops lvl
      canOpenDoors = EM.findWithDefault 0 Ability.AbAlter actorSk > 0
      chDoorAccess = if canOpenDoors then [checkDoorAccess cops lvl] else []
      conditions = catMaybes $ chAccess : chDoorAccess
      -- Legality of move from a known tile, assuming doors freely openable.
      isEnterable :: Point -> Point -> MoveLegal
      isEnterable spos tpos =
        let st = lvl `at` spos
            tt = lvl `at` tpos
            allOK = all (\f -> f spos tpos) conditions
        in if tt == unknownId
           then if not (Tile.isSuspect cotile st) && allOK
                then MoveToUnknown
                else MoveBlocked
           else if Tile.isPassable cotile tt
                   && not (Tile.isChangeable cotile st)  -- takes time to change
                   && allOK
                then MoveToOpen
                else MoveBlocked
      -- Legality of move from an unknown tile, assuming unknown are open.
      passUnknown :: Point -> Point -> Bool
      passUnknown = case chAccess of  -- spos is unknown, so not a door
        Nothing -> \_ tpos -> let tt = lvl `at` tpos
                              in tt == unknownId
        Just ch -> \spos tpos -> let tt = lvl `at` tpos
                                 in tt == unknownId
                                    && ch spos tpos
  fAnything isEnterable passUnknown aid

accessCacheBfs :: MonadClient m => ActorId -> Point -> m (Maybe Int)
{-# INLINE accessCacheBfs #-}
accessCacheBfs aid target = do
  bfs <- getCacheBfs aid
  return $! accessBfs bfs target

-- | Furthest (wrt paths) known position.
furthestKnown :: MonadClient m => ActorId -> m Point
furthestKnown aid = do
  bfs <- getCacheBfs aid
  getMaxIndex <- rndToAction $ oneOf [ PointArray.maxIndexA
                                     , PointArray.maxLastIndexA ]
  let furthestPos = getMaxIndex bfs
      dist = bfs PointArray.! furthestPos
  return $! if dist <= apartBfs
            then assert `failure` (aid, furthestPos, dist)
            else furthestPos

-- | Closest reachable unknown tile position, if any.
closestUnknown :: MonadClient m => ActorId -> m (Maybe Point)
closestUnknown aid = do
  bfs <- getCacheBfs aid
  getMinIndex <- rndToAction $ oneOf [ PointArray.minIndexA
                                     , PointArray.minLastIndexA ]
  let closestPos = getMinIndex bfs
      dist = bfs PointArray.! closestPos
  if dist >= apartBfs then do
    body <- getsState $ getActorBody aid
    lvl <- getLevel $ blid body
    when (lclear lvl == lseen lvl) $ do  -- explored fully, mark it once for all
      assert (lclear lvl >= lseen lvl) skip
      modifyClient $ \cli ->
        cli {sexplored = ES.insert (blid body) (sexplored cli)}
    return Nothing
  else return $ Just closestPos

-- TODO: this is costly, because target has to be changed every
-- turn when walking along trail. But inverting the sort and going
-- to the newest smell, while sometimes faster, may result in many
-- actors following the same trail, unless we wipe the trail as soon
-- as target is assigned (but then we don't know if we should keep the target
-- or not, because somebody already followed it). OTOH, trails are not
-- common and so if wiped they can't incur a large total cost.
-- TODO: remove targets where the smell is likely to get too old by the time
-- the actor gets there.
-- | Finds smells closest to the actor, except under the actor.
closestSmell :: MonadClient m => ActorId -> m [(Int, (Point, Tile.SmellTime))]
closestSmell aid = do
  body <- getsState $ getActorBody aid
  Level{lsmell, ltime} <- getLevel $ blid body
  let smells = filter ((> ltime) . snd) $ EM.assocs lsmell
  case smells of
    [] -> return []
    _ -> do
      bfs <- getCacheBfs aid
      let ts = mapMaybe (\x@(p, _) -> fmap (,x) (accessBfs bfs p)) smells
          ds = filter (\(d, _) -> d /= 0) ts  -- bpos of aid
      return $! sortBy (comparing (fst &&& absoluteTimeNegate . snd . snd)) ds

-- | Closest (wrt paths) suspect tile.
closestSuspect :: MonadClient m => ActorId -> m [Point]
closestSuspect aid = do
  Kind.COps{cotile} <- getsState scops
  body <- getsState $ getActorBody aid
  lvl <- getLevel $ blid body
  let f :: [Point] -> Point -> Kind.Id TileKind -> [Point]
      f acc p t = if Tile.isSuspect cotile t then p : acc else acc
      suspect = PointArray.ifoldlA f [] $ ltile lvl
  case suspect of
    [] -> do
      -- If the level has inaccessible open areas (at least from some stairs)
      -- here finally mark it explored, to enable transition to other levels.
      -- We should generally avoid such levels, because digging and/or trying
      -- to find other stairs leading to disconnected areas is not KISS
      -- so we don't do this in AI, so AI is at a disadvantage.
      modifyClient $ \cli ->
        cli {sexplored = ES.insert (blid body) (sexplored cli)}
      return []
    _ -> do
      bfs <- getCacheBfs aid
      let ds = mapMaybe (\p -> fmap (,p) (accessBfs bfs p)) suspect
      return $! map snd $ sortBy (comparing fst) ds

-- TODO: We assume linear dungeon in @unexploredD@,
-- because otherwise we'd need to calculate shortest paths in a graph, etc.
-- | Closest (wrt paths) triggerable open tiles.
-- The second argument can ever be true only if there's
-- no escape from the dungeon.
closestTriggers :: MonadClient m => Maybe Bool -> Bool -> ActorId -> m [Point]
closestTriggers onlyDir exploredToo aid = do
  Kind.COps{cotile} <- getsState scops
  body <- getsState $ getActorBody aid
  lvl <- getLevel $ blid body
  dungeon <- getsState sdungeon
  explored <- getsClient sexplored
  unexploredD <- unexploredDepth
  let allExplored = ES.size explored == EM.size dungeon
      unexUp = onlyDir /= Just False && unexploredD 1 (blid body)
      unexDown = onlyDir /= Just True && unexploredD (-1) (blid body)
      unexEffect (Effect.Ascend p) = if p > 0 then unexUp else unexDown
      unexEffect _ =
        -- Escape (or guard) only after exploring, for high score, etc.
        allExplored
      isTrigger
        | exploredToo = \t -> Tile.isWalkable cotile t
                              && not (null $ Tile.causeEffects cotile t)
        | otherwise = \t -> Tile.isWalkable cotile t
                            && any unexEffect (Tile.causeEffects cotile t)
      f :: [Point] -> Point -> Kind.Id TileKind -> [Point]
      f acc p t = if isTrigger t then p : acc else acc
  let triggersAll = PointArray.ifoldlA f [] $ ltile lvl
      -- Don't target stairs under the actor. Most of the time they
      -- are blocked and stay so, so we seek other stairs, if any.
      -- If no other stairs in this direction, let's wait here.
      triggers | length triggersAll > 1 = delete (bpos body) triggersAll
               | otherwise = triggersAll
  case triggers of
    [] -> return []
    _ -> do
      bfs <- getCacheBfs aid
      let ds = mapMaybe (\p -> fmap (,p) (accessBfs bfs p)) triggers
      return $! map snd $ sortBy (comparing fst) ds

unexploredDepth :: MonadClient m => m (Int -> LevelId -> Bool)
unexploredDepth = do
  dungeon <- getsState sdungeon
  explored <- getsClient sexplored
  let allExplored = ES.size explored == EM.size dungeon
      unexploredD p =
        let unex lid = allExplored && lescape (dungeon EM.! lid)
                       || ES.notMember lid explored
                       || unexploredD p lid
        in any unex . ascendInBranch dungeon p
  return unexploredD

-- | Closest (wrt paths) items and changeable tiles (e.g., item caches).
closestItems :: MonadClient m => ActorId -> m ([(Int, (Point, Maybe ItemBag))])
closestItems aid = do
  Kind.COps{cotile} <- getsState scops
  body <- getsState $ getActorBody aid
  lvl@Level{lfloor} <- getLevel $ blid body
  let items = EM.assocs lfloor
      f :: [Point] -> Point -> Kind.Id TileKind -> [Point]
      f acc p t = if Tile.isChangeable cotile t then p : acc else acc
      changeable = PointArray.ifoldlA f [] $ ltile lvl
  if null items && null changeable then return []
  else do
    bfs <- getCacheBfs aid
    let is = mapMaybe (\(p, bag) ->
                        fmap (, (p, Just bag)) (accessBfs bfs p)) items
        cs = mapMaybe (\p ->
                        fmap (, (p, Nothing)) (accessBfs bfs p)) changeable
    return $! sortBy (comparing fst) $ is ++ cs

-- | Closest (wrt paths) enemy actors.
closestFoes :: MonadClient m
            => [(ActorId, Actor)] -> ActorId -> m [(Int, (ActorId, Actor))]
closestFoes foes aid = do
  case foes of
    [] -> return []
    _ -> do
      bfs <- getCacheBfs aid
      let ds = mapMaybe (\x@(_, b) -> fmap (,x) (accessBfs bfs (bpos b))) foes
      return $! sortBy (comparing fst) ds
