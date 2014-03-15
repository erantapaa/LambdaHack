-- | Handle effects (most often caused by requests sent by clients).
module Game.LambdaHack.Server.HandleEffectServer
  ( itemEffect, effectSem
  ) where

import Control.Exception.Assert.Sugar
import Control.Monad
import qualified Data.EnumMap.Strict as EM
import Data.Key (mapWithKeyM_)
import Data.Maybe
import Data.Ratio ((%))
import Data.Text (Text)
import qualified NLP.Miniutter.English as MU

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.MonadStateRead
import Game.LambdaHack.Common.Actor
import Game.LambdaHack.Common.ActorState
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Common.Item
import qualified Game.LambdaHack.Common.Kind as Kind
import Game.LambdaHack.Common.Level
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.State
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Content.ActorKind
import Game.LambdaHack.Content.FactionKind
import Game.LambdaHack.Server.CommonServer
import Game.LambdaHack.Server.MonadServer
import Game.LambdaHack.Server.PeriodicServer
import Game.LambdaHack.Server.State
import Game.LambdaHack.Utils.Frequency

-- + Semantics of effects

-- TODO: when h2h items have ItemId, replace Item with ItemId
-- | The source actor affects the target actor, with a given item.
-- If the event is seen, the item may get identified. This function
-- is mutually recursive with @effect@ and so it's a part of @Effect@
-- semantics.
itemEffect :: (MonadAtomic m, MonadServer m)
           => ActorId -> ActorId -> Maybe ItemId -> Item
           -> m ()
itemEffect source target miid item = do
  discoS <- getsServer sdisco
  let ik = fromJust $ jkind discoS item
      ef = jeffect item
  b <- effectSem ef source target
  -- The effect is interesting so the item gets identified, if seen
  -- (the item is in source actor's posession, so his position is given,
  -- note that the actor may be moved by the effect; the item is destroyed,
  -- if ever, after the discovery happens).
  postb <- getsState $ getActorBody source
  let atomic iid = execUpdAtomic $ UpdDiscover (blid postb) (bpos postb) iid ik
  when b $ maybe skip atomic miid

-- | The source actor affects the target actor, with a given effect and power.
-- Both actors are on the current level and can be the same actor.
-- The boolean result indicates if the effect was spectacular enough
-- for the actors to identify it (and the item that caused it, if any).
effectSem :: (MonadAtomic m, MonadServer m)
          => Effect.Effect Int -> ActorId -> ActorId
          -> m Bool
effectSem effect source target = case effect of
  Effect.NoEffect -> effectNoEffect target
  Effect.Heal p -> effectHeal p target
  Effect.Hurt nDm p -> effectWound nDm p source target
  Effect.Mindprobe _ -> effectMindprobe target
  Effect.Dominate | source /= target -> effectDominate source target
  Effect.Dominate -> effectSem (Effect.Mindprobe undefined) source target
  Effect.CallFriend p -> effectCallFriend p source target
  Effect.Summon p -> effectSummon p target
  Effect.CreateItem p -> effectCreateItem p target
  Effect.ApplyPerfume -> effectApplyPerfume source target
  Effect.Regeneration p -> effectSem (Effect.Heal p) source target
  Effect.Searching p -> effectSearching p source
  Effect.Ascend p -> effectAscend p target
  Effect.Escape{} -> effectEscape target

-- + Individual semantic functions for effects

-- ** NoEffect

effectNoEffect :: MonadAtomic m => ActorId -> m Bool
effectNoEffect target = do
  execSfxAtomic $ SfxEffect target Effect.NoEffect
  return False

-- ** Heal

effectHeal :: MonadAtomic m
           => Int -> ActorId -> m Bool
effectHeal power target = do
  Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  tm <- getsState $ getActorBody target
  let bhpMax = maxDice (ahp $ okind $ bkind tm)
  if power > 0 && bhp tm >= bhpMax
    then do
      execSfxAtomic $ SfxEffect target Effect.NoEffect
      return False
    else do
      let deltaHP = min power (bhpMax - bhp tm)
      execUpdAtomic $ UpdHealActor target deltaHP
      execSfxAtomic $ SfxEffect target $ Effect.Heal deltaHP
      return True

-- ** Wound

effectWound :: (MonadAtomic m, MonadServer m)
            => RollDice -> Int -> ActorId -> ActorId
            -> m Bool
effectWound nDm power source target = do
  Kind.COps{coactor=Kind.Ops{okind}} <- getsState scops
  n <- rndToAction $ castDice nDm
  let deltaHP = - (n + power)
  if deltaHP >= 0
    then do
      execSfxAtomic $ SfxEffect target Effect.NoEffect
      return False
    else do
      -- Damage the target.
      execUpdAtomic $ UpdHealActor target deltaHP
      tb <- getsState $ getActorBody target
      let calmMax = maxDice $ acalm $ okind $ bkind tb
          calmCur = bcalm tb
          deltaCalm = calmMax `div` 2 - calmCur
      when (deltaCalm < 0) $ execUpdAtomic $ UpdCalmActor target deltaCalm
      execSfxAtomic $ SfxEffect target $
        if source == target
        then Effect.Heal deltaHP
        else Effect.Hurt nDm deltaHP{-hack-}
      return True

-- ** Mindprobe

effectMindprobe :: MonadAtomic m
                => ActorId -> m Bool
effectMindprobe target = do
  tb <- getsState $ getActorBody target
  let lid = blid tb
  fact <- getsState $ (EM.! bfid tb) . sfactionD
  lb <- getsState $ actorNotProjList (isAtWar fact) lid
  let nEnemy = length lb
  if nEnemy == 0 || bproj tb then do
    execSfxAtomic $ SfxEffect target Effect.NoEffect
    return False
  else do
    execSfxAtomic $ SfxEffect target $ Effect.Mindprobe nEnemy
    return True

-- ** Dominate

effectDominate :: (MonadAtomic m, MonadServer m)
               => ActorId -> ActorId -> m Bool
effectDominate source target = do
  sb <- getsState (getActorBody source)
  tb <- getsState (getActorBody target)
  if bfid tb == bfid sb || bproj tb then do  -- TODO: drop the projectile?
    execSfxAtomic $ SfxEffect target Effect.NoEffect
    return False
  else do
    -- Announce domination before the actor changes sides.
    execSfxAtomic $ SfxEffect target Effect.Dominate
    -- TODO: Perhaps insert a turn of delay here to allow countermeasures.
    electLeader (bfid tb) (blid tb) target
    deduceKilled tb
    ais <- getsState $ getCarriedAssocs tb
    execUpdAtomic $ UpdLoseActor target tb ais
    -- TODO: if domination stays permanent (undecided yet), perhaps increase
    -- kill count here or record original factions and increase count only
    -- when the recreated actor really dies.
    let bNew = tb {bfid = bfid sb}
    execUpdAtomic $ UpdCreateActor target bNew ais
    leaderOld <- getsState $ gleader . (EM.! bfid sb) . sfactionD
    -- Halve the speed as a side-effect of domination.
    let speed = bspeed bNew
        delta = speedScale (1%2) speed
    when (delta > speedZero) $
      execUpdAtomic $ UpdHasteActor target (speedNegate delta)
    execUpdAtomic $ UpdLeadFaction (bfid sb) leaderOld (Just target)
    return True

-- ** SummonFriend

effectCallFriend :: (MonadAtomic m, MonadServer m)
                   => Int -> ActorId -> ActorId
                   -> m Bool
effectCallFriend power source target = assert (power > 0) $ do
  -- Obvious effect, nothing announced.
  Kind.COps{cotile} <- getsState scops
  sm <- getsState (getActorBody source)
  tm <- getsState (getActorBody target)
  ps <- getsState $ nearbyFreePoints cotile (const True) (bpos tm) (blid tm)
  summonFriends (bfid sm) (take power ps) (blid tm)
  return True

summonFriends :: (MonadAtomic m, MonadServer m)
              => FactionId -> [Point] -> LevelId
              -> m ()
summonFriends bfid ps lid = do
  Kind.COps{ coactor=coactor@Kind.Ops{opick}
           , cofaction=Kind.Ops{okind} } <- getsState scops
  time <- getsState $ getLocalTime lid
  factionD <- getsState sfactionD
  let fact = okind $ gkind $ factionD EM.! bfid
  forM_ ps $ \p -> do
    let summonName = fname fact
    mk <- rndToAction $ fmap (fromMaybe $ assert `failure` summonName)
                        $ opick summonName (const True)
    if mk == heroKindId coactor
      then addHero bfid p lid [] Nothing time
      else addMonster mk bfid p lid time
  -- No leader election needed, bebause an alive actor of the same faction
  -- causes the effect, so there is already a leader.

-- ** SpawnMonster

effectSummon :: (MonadAtomic m, MonadServer m)
             => Int -> ActorId -> m Bool
effectSummon power target = assert (power > 0) $ do
  -- Obvious effect, nothing announced.
  Kind.COps{cotile} <- getsState scops
  tm <- getsState (getActorBody target)
  ps <- getsState $ nearbyFreePoints cotile (const True) (bpos tm) (blid tm)
  time <- getsState $ getLocalTime (blid tm)
  mfid <- pickFaction "summon" (const True)
  case mfid of
    Nothing -> return False  -- no faction summons
    Just fid -> do
      spawnMonsters (take power ps) (blid tm) time fid
      return True

-- | Roll a faction based on faction kind frequency key.
pickFaction :: MonadServer m
            => Text
            -> ((FactionId, Faction) -> Bool)
            -> m (Maybe FactionId)
pickFaction freqChoice ffilter = do
  Kind.COps{cofaction=Kind.Ops{okind}} <- getsState scops
  factionD <- getsState sfactionD
  let f (fid, fact) = let kind = okind (gkind fact)
                          g n = (n, fid)
                      in fmap g $ lookup freqChoice $ ffreq kind
      flist = mapMaybe f $ filter ffilter $ EM.assocs factionD
      freq = toFreq ("pickFaction" <+> freqChoice) flist
  if nullFreq freq then return Nothing
  else fmap Just $ rndToAction $ frequency freq

-- ** CreateItem

effectCreateItem :: (MonadAtomic m, MonadServer m)
                 => Int -> ActorId -> m Bool
effectCreateItem power target = assert (power > 0) $ do
  -- Obvious effect, nothing announced.
  tm <- getsState $ getActorBody target
  void $ createItems power (bpos tm) (blid tm)
  return True

-- ** ApplyPerfume

effectApplyPerfume :: MonadAtomic m
                   => ActorId -> ActorId -> m Bool
effectApplyPerfume source target =
  if source == target
  then do
    execSfxAtomic $ SfxEffect target Effect.NoEffect
    return False
  else do
    tm <- getsState $ getActorBody target
    Level{lsmell} <- getLevel $ blid tm
    let f p fromSm =
          execUpdAtomic $ UpdAlterSmell (blid tm) p (Just fromSm) Nothing
    mapWithKeyM_ f lsmell
    execSfxAtomic $ SfxEffect target Effect.ApplyPerfume
    return True

-- ** Regeneration

-- ** Searching

-- TODO or to remove.
effectSearching :: MonadAtomic m => Int -> ActorId -> m Bool
effectSearching power source = do
  execSfxAtomic $ SfxEffect source $ Effect.Searching power
  return True

-- ** Ascend

effectAscend :: MonadAtomic m => Int -> ActorId -> m Bool
effectAscend power target = do
  mfail <- effLvlGoUp target power
  case mfail of
    Nothing -> do
      execSfxAtomic $ SfxEffect target $ Effect.Ascend power
      return True
    Just failMsg -> do
      b <- getsState $ getActorBody target
      execSfxAtomic $ SfxMsgFid (bfid b) failMsg
      return False

effLvlGoUp :: MonadAtomic m => ActorId -> Int -> m (Maybe Msg)
effLvlGoUp aid k = do
  b1 <- getsState $ getActorBody aid
  ais1 <- getsState $ getCarriedAssocs b1
  let lid1 = blid b1
      pos1 = bpos b1
  (lid2, pos2) <- getsState $ whereTo lid1 pos1 k . sdungeon
  if lid2 == lid1 && pos2 == pos1 then
    return $ Just "The effect fizzles: no more levels in this direction."
  else if bproj b1 then
    assert `failure` "projectiles can't exit levels" `twith` (aid, k, b1)
  else do
    let switch1 = switchLevels1 ((aid, b1), ais1)
        switch2 = do
          -- Move the actor to where the inhabitant was, if any.
          switchLevels2 lid2 pos2 ((aid, b1), ais1)
          -- Verify only one non-projectile actor on every tile.
          !_ <- getsState $ posToActors pos1 lid1  -- assertion is inside
          !_ <- getsState $ posToActors pos2 lid2  -- assertion is inside
          return Nothing
    -- The actor is added to the new level, but there can be other actors
    -- at his new position.
    inhabitants <- getsState $ posToActors pos2 lid2
    case inhabitants of
      [] -> do
        switch1
        switch2
      ((_, b2), _) : _ -> do
        -- Alert about the switch.
        let subjects = map (partActor . snd . fst) inhabitants
            subject = MU.WWandW subjects
            verb = "be pushed to another level"
            msg2 = makeSentence [MU.SubjectVerbSg subject verb]
        -- Only tell one player, even if many actors, because then
        -- they are projectiles, so not too important.
        execSfxAtomic $ SfxMsgFid (bfid b2) msg2
        -- Move the actor out of the way.
        switch1
        -- Move the inhabitant out of the way.
        mapM_ switchLevels1 inhabitants
        -- Move the inhabitant to where the actor was.
        mapM_ (switchLevels2 lid1 pos1) inhabitants
        switch2

switchLevels1 :: MonadAtomic m => ((ActorId, Actor), [(ItemId, Item)]) -> m ()
switchLevels1 ((aid, bOld), ais) = do
  let side = bfid bOld
  mleader <- getsState $ gleader . (EM.! side) . sfactionD
  -- Prevent leader pointing to a non-existing actor.
  when (not (bproj bOld) && isJust mleader) $
    -- Trouble, if the actors are of the same faction.
    execUpdAtomic $ UpdLeadFaction side mleader Nothing
  -- Remove the actor from the old level.
  -- Onlookers see somebody disappear suddenly.
  -- @DestroyActorA@ is too loud, so use @LoseActorA@ instead.
  execUpdAtomic $ UpdLoseActor aid bOld ais

switchLevels2 :: MonadAtomic m
              => LevelId -> Point -> ((ActorId, Actor), [(ItemId, Item)])
              -> m ()
switchLevels2 lidNew posNew ((aid, bOld), ais) = do
  let lidOld = blid bOld
      side = bfid bOld
  assert (lidNew /= lidOld `blame` "stairs looped" `twith` lidNew) skip
  -- Sync the actor time with the level time.
  timeOld <- getsState $ getLocalTime lidOld
  timeLastVisited <- getsState $ getLocalTime lidNew
  -- This time calculation may cause a double move of a foe of the same
  -- speed, but this is OK --- the foe didn't have a chance to move
  -- before, because the arena went inactive, so he moves now one more time.
  let delta = timeAdd (btime bOld) (timeNegate timeOld)
      bNew = bOld { blid = lidNew
                  , btime = timeAdd timeLastVisited delta
                  , bpos = posNew
                  , boldpos = posNew  -- new level, new direction
                  , boldlid = lidOld }  -- record old level
  mleader <- getsState $ gleader . (EM.! side) . sfactionD
  -- Materialize the actor at the new location.
  -- Onlookers see somebody appear suddenly. The actor himself
  -- sees new surroundings and has to reset his perception.
  execUpdAtomic $ UpdCreateActor aid bNew ais
  -- Changing levels is so important, that the leader changes.
  -- This also helps the actor clear the staircase and so avoid
  -- being pushed back to the level he came from by another actor.
  when (not (bproj bOld) && isNothing mleader) $
    -- Trouble, if the actors are of the same faction.
    execUpdAtomic $ UpdLeadFaction side Nothing (Just aid)

-- ** Escape

-- | The faction leaves the dungeon.
effectEscape :: (MonadAtomic m, MonadServer m) => ActorId -> m Bool
effectEscape aid = do
  -- Obvious effect, nothing announced.
  cops <- getsState scops
  b <- getsState $ getActorBody aid
  let fid = bfid b
  fact <- getsState $ (EM.! fid) . sfactionD
  if not (isHeroFact cops fact) || bproj b then
    return False
  else do
    deduceQuits b $ Status Escape (fromEnum $ blid b) ""
    return True