-- | Determining the strongest item wrt some property.
-- No operation in this module involves the state or any of our custom monads.
module Game.LambdaHack.Common.ItemStrongest
  ( -- * Strongest items
    strengthOnSmash, strengthToThrow, strengthEqpSlot, strengthFromEqpSlot
  , strongestSlotNoFilter, strongestSlot, sumSlotNoFilter, sumSkills
    -- * Assorted
  , totalRange, computeTrajectory, itemTrajectory
  , unknownPrecious, permittedRanged, unknownMelee
  ) where

import Control.Applicative
import Control.Exception.Assert.Sugar
import qualified Control.Monad.State as St
import qualified Data.EnumMap.Strict as EM
import Data.List
import Data.Maybe
import qualified Data.Ord as Ord
import Data.Text (Text)

import qualified Game.LambdaHack.Common.Ability as Ability
import qualified Game.LambdaHack.Common.Dice as Dice
import Game.LambdaHack.Common.Effect
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Content.ItemKind

dice999 :: Dice.Dice -> Int
dice999 d = fromMaybe 999 $ Dice.reduceDice d

strengthAspect :: (Aspect Int -> [b]) -> ItemFull -> [b]
strengthAspect f itemFull =
  case itemDisco itemFull of
    Just ItemDisco{itemAE=Just ItemAspectEffect{jaspects}} ->
      concatMap f jaspects
    Just ItemDisco{itemKind=ItemKind{iaspects}} ->
      -- Approximation. For some effects lower values are better,
      -- so we can't put 999 here (and for summation, this is wrong).
      let trav x = St.evalState (aspectTrav x (return . round . Dice.meanDice))
                                ()
      in concatMap f $ map trav iaspects
    Nothing -> []

strengthAspectMaybe :: Show b => (Aspect Int -> [b]) -> ItemFull -> Maybe b
strengthAspectMaybe f itemFull =
  case strengthAspect f itemFull of
    [] -> Nothing
    [x] -> Just x
    xs -> assert `failure` (xs, itemFull)

strengthEffect999 :: (Effect Int -> [b]) -> ItemFull -> [b]
strengthEffect999 f itemFull =
  case itemDisco itemFull of
    Just ItemDisco{itemAE=Just ItemAspectEffect{jeffects}} ->
      concatMap f jeffects
    Just ItemDisco{itemKind=ItemKind{ieffects}} ->
      -- Default for unknown power is 999 to encourage experimenting.
      let trav x = St.evalState (effectTrav x (return . dice999)) ()
      in concatMap f $ map trav ieffects
    Nothing -> []

strengthFeature :: (Feature -> [b]) -> Item -> [b]
strengthFeature f item = concatMap f (jfeature item)

strengthMelee :: ItemFull -> Maybe Int
strengthMelee itemFull =
  let durable = Durable `elem` jfeature (itemBase itemFull)
      p (Hurt d) = [floor (Dice.meanDice d)]
      p (Burn k) = [k]
      p _ = []
      hasNoEffects = case itemDisco itemFull of
        Just ItemDisco{itemAE=Just ItemAspectEffect{jeffects}} ->
          null jeffects
        Just ItemDisco{itemKind=ItemKind{ieffects}} ->
          null ieffects
        Nothing -> True
  in if hasNoEffects
     then Nothing
     else Just $ sum (strengthEffect999 p itemFull)
                 + if durable then 100 else 0

-- Called only by the server, so 999 is OK.
strengthOnSmash :: ItemFull -> [Effect Int]
strengthOnSmash =
  let p (OnSmash eff) = [eff]
      p _ = []
  in strengthEffect999 p

strengthPeriodic :: ItemFull -> Maybe Int
strengthPeriodic =
  let p (Periodic k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddMaxHP :: ItemFull -> Maybe Int
strengthAddMaxHP =
  let p (AddMaxHP k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddMaxCalm :: ItemFull -> Maybe Int
strengthAddMaxCalm =
  let p (AddMaxCalm k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddSpeed :: ItemFull -> Maybe Int
strengthAddSpeed =
  let p (AddSpeed k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddSkills :: ItemFull -> Maybe Ability.Skills
strengthAddSkills =
  let p (AddSkills a) = [a]
      p _ = []
  in strengthAspectMaybe p

strengthAddHurtMelee :: ItemFull -> Maybe Int
strengthAddHurtMelee =
  let p (AddHurtMelee k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddHurtRanged :: ItemFull -> Maybe Int
strengthAddHurtRanged =
  let p (AddHurtRanged k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddArmorMelee :: ItemFull -> Maybe Int
strengthAddArmorMelee =
  let p (AddArmorMelee k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddArmorRanged :: ItemFull -> Maybe Int
strengthAddArmorRanged =
  let p (AddArmorRanged k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddSight :: ItemFull -> Maybe Int
strengthAddSight =
  let p (AddSight k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddSmell :: ItemFull -> Maybe Int
strengthAddSmell =
  let p (AddSmell k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthAddLight :: ItemFull -> Maybe Int
strengthAddLight =
  let p (AddLight k) = [k]
      p _ = []
  in strengthAspectMaybe p

strengthEqpSlot :: Item -> Maybe (EqpSlot, Text)
strengthEqpSlot item =
  let p (EqpSlot eqpSlot t) = [(eqpSlot, t)]
      p _ = []
  in case strengthFeature p item of
    [] -> Nothing
    [x] -> Just x
    xs -> assert `failure` (xs, item)

strengthToThrow :: Item -> ThrowMod
strengthToThrow item =
  let p (ToThrow tmod) = [tmod]
      p _ = []
  in case strengthFeature p item of
    [] -> ThrowMod 100 100
    [x] -> x
    xs -> assert `failure` (xs, item)

computeTrajectory :: Int -> Int -> Int -> [Point] -> ([Vector], (Speed, Int))
computeTrajectory weight throwVelocity throwLinger path =
  let speed = speedFromWeight weight throwVelocity
      trange = rangeFromSpeedAndLinger speed throwLinger
      btrajectory = take trange $ pathToTrajectory path
  in (btrajectory, (speed, trange))

itemTrajectory :: Item -> [Point] -> ([Vector], (Speed, Int))
itemTrajectory item path =
  let ThrowMod{..} = strengthToThrow item
  in computeTrajectory (jweight item) throwVelocity throwLinger path

totalRange :: Item -> Int
totalRange item = snd $ snd $ itemTrajectory item []

-- TODO: when all below are aspects, define with
-- (EqpSlotAddMaxHP, AddMaxHP k) -> [k]
strengthFromEqpSlot :: EqpSlot -> ItemFull -> Maybe Int
strengthFromEqpSlot eqpSlot =
  case eqpSlot of
    EqpSlotPeriodic -> strengthPeriodic  -- a very crude approximation
    EqpSlotAddMaxHP -> strengthAddMaxHP
    EqpSlotAddMaxCalm -> strengthAddMaxCalm
    EqpSlotAddSpeed -> strengthAddSpeed
    EqpSlotAddSkills -> \itemFull -> sum . EM.elems <$> strengthAddSkills itemFull
    EqpSlotAddHurtMelee -> strengthAddHurtMelee
    EqpSlotAddHurtRanged -> strengthAddHurtRanged
    EqpSlotAddArmorMelee -> strengthAddArmorMelee
    EqpSlotAddArmorRanged -> strengthAddArmorRanged
    EqpSlotAddSight -> strengthAddSight
    EqpSlotAddSmell -> strengthAddSmell
    EqpSlotAddLight -> strengthAddLight
    EqpSlotWeapon -> strengthMelee

strongestSlotNoFilter :: EqpSlot -> [(ItemId, ItemFull)]
                      -> [(Int, (ItemId, ItemFull))]
strongestSlotNoFilter eqpSlot is =
  let f = strengthFromEqpSlot eqpSlot
      g (iid, itemFull) = (\v -> (v, (iid, itemFull))) <$> (f itemFull)
  in sortBy (flip $ Ord.comparing fst) $ mapMaybe g is

strongestSlot :: EqpSlot -> [(ItemId, ItemFull)]
              -> [(Int, (ItemId, ItemFull))]
strongestSlot eqpSlot is =
  let f (_, itemFull) = case strengthEqpSlot $ itemBase itemFull of
        Just (eqpSlot2, _) | eqpSlot2 == eqpSlot -> True
        _ -> False
      slotIs = filter f is
  in strongestSlotNoFilter eqpSlot slotIs

sumSlotNoFilter :: EqpSlot -> [ItemFull] -> Int
sumSlotNoFilter eqpSlot is = assert (eqpSlot /= EqpSlotWeapon) $  -- no 999
  let f = strengthFromEqpSlot eqpSlot
      g itemFull = (* itemK itemFull) <$> f itemFull
  in sum $ mapMaybe g is

sumSkills :: [ItemFull] -> Ability.Skills
sumSkills is =
  let g itemFull = (Ability.scaleSkills (itemK itemFull))
                   <$> strengthAddSkills itemFull
  in foldr Ability.addSkills Ability.zeroSkills $ mapMaybe g is

unknownPrecious :: ItemFull -> Bool
unknownPrecious itemFull =
  Durable `notElem` jfeature (itemBase itemFull)  -- if durable, no risk
  && case itemDisco itemFull of
    Just ItemDisco{itemAE=Just _} -> False
    _ -> Precious `elem` jfeature (itemBase itemFull)

permittedRanged :: ItemFull -> Maybe Int -> Bool
permittedRanged itemFull _ =
  let hasEffects = case itemDisco itemFull of
        Just ItemDisco{itemAE=Just ItemAspectEffect{jeffects=[]}} -> False
        Just ItemDisco{itemAE=Nothing, itemKind=ItemKind{ieffects=[]}} -> False
        _ -> True
  in hasEffects
     && not (unknownPrecious itemFull)
     && case strengthEqpSlot (itemBase itemFull) of
          Just (EqpSlotAddLight, _) -> True
          Just _ -> False
          Nothing -> True

unknownAspect :: (Aspect Dice.Dice -> [Dice.Dice]) -> ItemFull -> Bool
unknownAspect f itemFull =
  case itemDisco itemFull of
    Just ItemDisco{itemAE=Nothing, itemKind=ItemKind{iaspects}} ->
      let unknown x = Dice.minDice x /= Dice.maxDice x
      in or $ concatMap (map unknown . f) iaspects
    _ -> False

unknownMelee :: [ItemFull] -> Bool
unknownMelee =
  let p (AddHurtMelee k) = [k]
      p _ = []
      f itemFull b = b || unknownAspect p itemFull
  in foldr f False
