{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | Actors in the game: heroes, monsters, etc. No operation in this module
-- involves the 'State' or 'Action' type.
module Game.LambdaHack.Common.Actor
  ( -- * Actor identifiers and related operations
    ActorId, monsterGenChance, partActor, partPronoun
    -- * The@ Acto@r type
  , Actor(..), ResDelta(..)
  , deltaSerious, deltaMild, xM, minusM, minusTwoM, oneM
  , bspeed, actorTemplate, timeShiftFromSpeed, braced, waitedLastTurn
  , actorDying, actorNewBorn, hpTooLow, unoccupied
    -- * Assorted
  , ActorDict, smellTimeout, checkAdjacent
  , mapActorItems_, ppCStore, ppContainer
  ) where

import Control.Exception.Assert.Sugar
import Data.Binary
import qualified Data.EnumMap.Strict as EM
import Data.Int (Int64)
import Data.Ratio
import Data.Text (Text)
import qualified NLP.Miniutter.English as MU

import qualified Game.LambdaHack.Common.Color as Color
import qualified Game.LambdaHack.Common.Effect as Effect
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.ItemStrongest
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random
import Game.LambdaHack.Common.Time
import Game.LambdaHack.Common.Vector

-- | Actor properties that are changing throughout the game.
-- If they are dublets of properties from @ActorKind@,
-- they are usually modified temporarily, but tend to return
-- to the original value from @ActorKind@ over time. E.g., HP.
data Actor = Actor
  { -- The trunk of the actor's body (present also in @borgan@ or @beqp@)
    btrunk      :: !ItemId
    -- Presentation
  , bsymbol     :: !Char                 -- ^ individual map symbol
  , bname       :: !Text                 -- ^ individual name
  , bpronoun    :: !Text                 -- ^ individual pronoun
  , bcolor      :: !Color.Color          -- ^ individual map color
    -- Resources
  , btime       :: !Time                 -- ^ absolute time of next action
  , bhp         :: !Int64                -- ^ current hit points * 1M
  , bhpDelta    :: !ResDelta             -- ^ HP delta this turn * 1M
  , bcalm       :: !Int64                -- ^ current calm * 1M
  , bcalmDelta  :: !ResDelta             -- ^ calm delta this turn * 1M
    -- Location
  , bpos        :: !Point                -- ^ current position
  , boldpos     :: !Point                -- ^ previous position
  , blid        :: !LevelId              -- ^ current level
  , boldlid     :: !LevelId              -- ^ previous level
  , bfid        :: !FactionId            -- ^ faction the actor belongs to
  , boldfid     :: !FactionId            -- ^ previous faction of the actor
  , btrajectory :: !(Maybe ([Vector], Speed))  -- ^ trajectory the actor must
                                               --   travel and his travel speed
    -- Items
  , borgan      :: !ItemBag              -- ^ organs
  , beqp        :: !ItemBag              -- ^ personal equipment
  , binv        :: !ItemBag              -- ^ personal inventory
    -- Assorted
  , bwait       :: !Bool                 -- ^ is the actor waiting right now?
  , bproj       :: !Bool                 -- ^ is a projectile? (shorthand only,
                                         --   this can be deduced from bkind)
  }
  deriving (Show, Eq)

data ResDelta = ResDelta
  { resCurrentTurn  :: !Int64  -- ^ resource change this player turn
  , resPreviousTurn :: !Int64  -- ^ resource change last player turn
  }
  deriving (Show, Eq)

deltaSerious :: ResDelta -> Bool
deltaSerious ResDelta{..} = resCurrentTurn < minusM || resPreviousTurn < minusM

deltaMild :: ResDelta -> Bool
deltaMild ResDelta{..} = resCurrentTurn == minusM || resPreviousTurn == minusM

xM :: Int -> Int64
xM k = fromIntegral k * 1000000

minusM, minusTwoM, oneM :: Int64
minusM = xM (-1)
minusTwoM = xM (-2)
oneM = xM 1

-- | Chance that a new monster is generated. Currently depends on the
-- number of monsters already present, and on the level. In the future,
-- the strength of the character and the strength of the monsters present
-- could further influence the chance, and the chance could also affect
-- which monster is generated. How many and which monsters are generated
-- will also depend on the cave kind used to build the level.
monsterGenChance :: AbsDepth -> AbsDepth -> Int -> Int -> Rnd Bool
monsterGenChance (AbsDepth n) (AbsDepth depth) numMonsters actorCoeff =
  assert (depth > 0)
  -- Mimics @castDice@. On level 1, First 2 monsters appear fast.
  $ let scaledDepth = 5 * n `div` depth
    in chance $ 1%(fromIntegral
                   $ (10 * actorCoeff * (numMonsters - scaledDepth))
                     `max` actorCoeff)

-- | The part of speech describing the actor.
partActor :: Actor -> MU.Part
partActor b = MU.Text $ bname b

-- | The part of speech containing the actor pronoun.
partPronoun :: Actor -> MU.Part
partPronoun b = MU.Text $ bpronoun b

-- Actor operations

-- | A template for a new actor.
actorTemplate :: ItemId -> Char -> Text -> Text
              -> Color.Color -> Int64 -> Int64
              -> Point -> LevelId -> Time -> FactionId
              -> Actor
actorTemplate btrunk bsymbol bname bpronoun bcolor bhp bcalm
              bpos blid btime bfid =
  let btrajectory = Nothing
      boldpos = Point 0 0  -- make sure /= bpos, to tell it didn't switch level
      boldlid = blid
      beqp    = EM.empty
      binv    = EM.empty
      borgan  = EM.empty
      bwait   = False
      boldfid = bfid
      bhpDelta = ResDelta 0 0
      bcalmDelta = ResDelta 0 0
      bproj = False
  in Actor{..}

bspeed :: Actor -> [ItemFull] -> Speed
bspeed b activeItems =
  case btrajectory b of
    Nothing -> toSpeed $ max 1  -- avoid infinite wait
               $ sumSlotNoFilter Effect.EqpSlotAddSpeed activeItems
    Just (_, speed) -> speed

-- | Add time taken by a single step at the actor's current speed.
timeShiftFromSpeed :: Actor -> [ItemFull] -> Time -> Time
timeShiftFromSpeed b activeItems time =
  let speed = bspeed b activeItems
      delta = ticksPerMeter speed
  in timeShift time delta

-- | Whether an actor is braced for combat this clip.
braced :: Actor -> Bool
braced b = bwait b

-- | The actor waited last turn.
waitedLastTurn :: Actor -> Bool
waitedLastTurn b = bwait b

actorDying :: Actor -> Bool
actorDying b = if bproj b
               then bhp b < 0
                    || maybe True (null . fst) (btrajectory b)
               else bhp b <= 0

actorNewBorn :: Actor -> Bool
actorNewBorn b = boldpos b == Point 0 0
                 && not (waitedLastTurn b)
                 && not (btime b < timeTurn)

hpTooLow :: Actor -> [ItemFull] -> Bool
hpTooLow b activeItems =
  let maxHP = sumSlotNoFilter Effect.EqpSlotAddMaxHP activeItems
  in bhp b <= oneM || 5 * bhp b < xM maxHP

-- | Checks for the presence of actors in a position.
-- Does not check if the tile is walkable.
unoccupied :: [Actor] -> Point -> Bool
unoccupied actors pos = all (\b -> bpos b /= pos) actors

-- | How long until an actor's smell vanishes from a tile.
smellTimeout :: Delta Time
smellTimeout = timeDeltaScale (Delta timeTurn) 100

-- | All actors on the level, indexed by actor identifier.
type ActorDict = EM.EnumMap ActorId Actor

checkAdjacent :: Actor -> Actor -> Bool
checkAdjacent sb tb = blid sb == blid tb && adjacent (bpos sb) (bpos tb)

mapActorItems_ :: Monad m => (ItemId -> Int -> m a) -> Actor -> m ()
mapActorItems_ f Actor{binv, beqp, borgan} = do
  let is = EM.assocs beqp ++ EM.assocs binv ++ EM.assocs borgan
  mapM_ (uncurry f) is

ppCStore :: CStore -> Text
ppCStore CGround = "on the ground"
ppCStore COrgan = "among organs"
ppCStore CEqp = "in equipment"
ppCStore CInv = "in inventory"
ppCStore CSha = "in shared stash"

ppContainer :: Container -> Text
ppContainer CFloor{} = "nearby"
ppContainer (CActor _ cstore) = ppCStore cstore
ppContainer CTrunk{} = "in our possession"

instance Binary Actor where
  put Actor{..} = do
    put btrunk
    put bsymbol
    put bname
    put bpronoun
    put bcolor
    put bhp
    put bhpDelta
    put bcalm
    put bcalmDelta
    put btrajectory
    put bpos
    put boldpos
    put blid
    put boldlid
    put binv
    put beqp
    put borgan
    put btime
    put bwait
    put bfid
    put boldfid
    put bproj
  get = do
    btrunk <- get
    bsymbol <- get
    bname <- get
    bpronoun <- get
    bcolor <- get
    bhp <- get
    bhpDelta <- get
    bcalm <- get
    bcalmDelta <- get
    btrajectory <- get
    bpos <- get
    boldpos <- get
    blid <- get
    boldlid <- get
    binv <- get
    beqp <- get
    borgan <- get
    btime <- get
    bwait <- get
    bfid <- get
    boldfid <- get
    bproj <- get
    return $! Actor{..}

instance Binary ResDelta where
  put ResDelta{..} = do
    put resCurrentTurn
    put resPreviousTurn
  get = do
    resCurrentTurn <- get
    resPreviousTurn <- get
    return $! ResDelta{..}
