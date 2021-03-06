-- | The monad for writing to the game state and related operations.
module Game.LambdaHack.Atomic.MonadStateWrite
  ( MonadStateWrite(..)
  , updateLevel, updateActor, updateFaction
  , insertItemContainer, insertItemActor, deleteItemContainer, deleteItemActor
  , updatePrio, updateFloor, updateTile, updateSmell
  ) where

import Control.Exception.Assert.Sugar
import qualified Data.EnumMap.Strict as EM

import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.State

class MonadStateRead m => MonadStateWrite m where
  modifyState :: (State -> State) -> m ()
  putState    :: State -> m ()

-- | Update the actor time priority queue.
updatePrio :: (ActorPrio -> ActorPrio) -> Level -> Level
updatePrio f lvl = lvl {lprio = f (lprio lvl)}

-- | Update the items on the ground map.
updateFloor :: (ItemFloor -> ItemFloor) -> Level -> Level
updateFloor f lvl = lvl {lfloor = f (lfloor lvl)}

-- | Update the tile map.
updateTile :: (TileMap -> TileMap) -> Level -> Level
updateTile f lvl = lvl {ltile = f (ltile lvl)}

-- | Update the smell map.
updateSmell :: (SmellMap -> SmellMap) -> Level -> Level
updateSmell f lvl = lvl {lsmell = f (lsmell lvl)}

-- | Update a given level data within state.
updateLevel :: MonadStateWrite m => LevelId -> (Level -> Level) -> m ()
updateLevel lid f = modifyState $ updateDungeon $ EM.adjust f lid

updateActor :: MonadStateWrite m => ActorId -> (Actor -> Actor) -> m ()
updateActor aid f = do
  let alt Nothing = assert `failure` "no body to update" `twith` aid
      alt (Just b) = Just $ f b
  modifyState $ updateActorD $ EM.alter alt aid

updateFaction :: MonadStateWrite m => FactionId -> (Faction -> Faction) -> m ()
updateFaction fid f = do
  let alt Nothing = assert `failure` "no faction to update" `twith` fid
      alt (Just fact) = Just $ f fact
  modifyState $ updateFactionD $ EM.alter alt fid

insertItemContainer :: MonadStateWrite m
                    => ItemId -> Int -> Container -> m ()
insertItemContainer iid k c = case c of
  CFloor lid pos -> insertItemFloor iid k lid pos
  CActor aid store -> insertItemActor iid k aid store
  CTrunk{} -> return ()

insertItemFloor :: MonadStateWrite m
                => ItemId -> Int -> LevelId -> Point -> m ()
insertItemFloor iid k lid pos =
  let bag = EM.singleton iid k
      mergeBag = EM.insertWith (EM.unionWith (+)) pos bag
  in updateLevel lid $ updateFloor mergeBag

insertItemActor :: MonadStateWrite m
                => ItemId -> Int -> ActorId -> CStore -> m ()
insertItemActor iid k aid cstore = case cstore of
  CGround -> do
    b <- getsState $ getActorBody aid
    insertItemFloor iid k (blid b) (bpos b)
  COrgan -> insertItemBody iid k aid
  CEqp -> insertItemEqp iid k aid
  CInv -> insertItemInv iid k aid
  CSha -> do
    b <- getsState $ getActorBody aid
    insertItemSha iid k (bfid b)

insertItemBody :: MonadStateWrite m
               => ItemId -> Int -> ActorId -> m ()
insertItemBody iid k aid = do
  let bag = EM.singleton iid k
      upd = EM.unionWith (+) bag
  updateActor aid $ \b -> b {borgan = upd (borgan b)}

insertItemEqp :: MonadStateWrite m
              => ItemId -> Int -> ActorId -> m ()
insertItemEqp iid k aid = do
  let bag = EM.singleton iid k
      upd = EM.unionWith (+) bag
  updateActor aid $ \b -> b {beqp = upd (beqp b)}

insertItemInv :: MonadStateWrite m
              => ItemId -> Int -> ActorId -> m ()
insertItemInv iid k aid = do
  let bag = EM.singleton iid k
      upd = EM.unionWith (+) bag
  updateActor aid $ \b -> b {binv = upd (binv b)}

insertItemSha :: MonadStateWrite m
               => ItemId -> Int -> FactionId -> m ()
insertItemSha iid k fid = do
  let bag = EM.singleton iid k
      upd = EM.unionWith (+) bag
  updateFaction fid $ \fact -> fact {gsha = upd (gsha fact)}

deleteItemContainer :: MonadStateWrite m
                    => ItemId -> Int -> Container -> m ()
deleteItemContainer iid k c = case c of
  CFloor lid pos -> deleteItemFloor iid k lid pos
  CActor aid store -> deleteItemActor iid k aid store
  CTrunk{} -> return ()

deleteItemFloor :: MonadStateWrite m
                => ItemId -> Int -> LevelId -> Point -> m ()
deleteItemFloor iid k lid pos =
  let rmFromFloor (Just bag) =
        let nbag = rmFromBag k iid bag
        in if EM.null nbag then Nothing else Just nbag
      rmFromFloor Nothing = assert `failure` "item already removed"
                                   `twith` (iid, k, lid, pos)
  in updateLevel lid $ updateFloor $ EM.alter rmFromFloor pos

deleteItemActor :: MonadStateWrite m
                => ItemId -> Int -> ActorId -> CStore -> m ()
deleteItemActor iid k aid cstore = case cstore of
  CGround -> do
    b <- getsState $ getActorBody aid
    deleteItemFloor iid k (blid b) (bpos b)
  COrgan -> deleteItemBody iid k aid
  CEqp -> deleteItemEqp iid k aid
  CInv -> deleteItemInv iid k aid
  CSha -> do
    b <- getsState $ getActorBody aid
    deleteItemSha iid k (bfid b)

deleteItemBody :: MonadStateWrite m => ItemId -> Int -> ActorId -> m ()
deleteItemBody iid k aid = do
  updateActor aid $ \b -> b {borgan = rmFromBag k iid (borgan b) }

deleteItemEqp :: MonadStateWrite m => ItemId -> Int -> ActorId -> m ()
deleteItemEqp iid k aid = do
  updateActor aid $ \b -> b {beqp = rmFromBag k iid (beqp b)}

deleteItemInv :: MonadStateWrite m => ItemId -> Int -> ActorId -> m ()
deleteItemInv iid k aid = do
  updateActor aid $ \b -> b {binv = rmFromBag k iid (binv b)}

deleteItemSha :: MonadStateWrite m => ItemId -> Int -> FactionId -> m ()
deleteItemSha iid k fid = do
  updateFaction fid $ \fact -> fact {gsha = rmFromBag k iid (gsha fact)}

rmFromBag :: Int -> ItemId -> ItemBag -> ItemBag
rmFromBag k iid bag =
  let rfb Nothing = assert `failure` "rm from empty slot" `twith` (k, iid, bag)
      rfb (Just n) =
        case compare n k of
          LT -> assert `failure` "rm more than there is"
                       `twith` (n, k, iid, bag)
          EQ -> Nothing
          GT -> Just (n - k)
  in EM.alter rfb iid bag
