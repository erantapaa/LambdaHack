{-# LANGUAGE ExistentialQuantification, GADTs, StandaloneDeriving, DataKinds, KindSignatures #-}
-- | Abstract syntax of server commands.
-- See
-- <https://github.com/LambdaHack/LambdaHack/wiki/Client-server-architecture>.
module Game.LambdaHack.Common.Request
  ( RequestAI(..), RequestUI(..), RequestTimed(..), RequestAnyAbility(..)
  , ReqFailure(..), showReqFailure, anyToUI
  ) where

import Data.Text (Text)

import Game.LambdaHack.Atomic
import Game.LambdaHack.Common.Actor
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Item
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Msg
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Vector
import Game.LambdaHack.Common.Ability
import Game.LambdaHack.Common.Faction
import Game.LambdaHack.Content.ModeKind

-- TODO: make remove second arg from ReqLeader; this requires a separate
-- channel for Ping, probably, and then client sends as many commands
-- as it wants at once
-- | Cclient-server requests sent by AI clients.
data RequestAI =
    forall a. ReqAITimed !(RequestTimed a)
  | ReqAILeader !ActorId !(Maybe Target) !RequestAI
  | ReqAIPong

deriving instance Show RequestAI

-- | Client-server requests sent by UI clients.
data RequestUI =
    forall a. ReqUITimed !(RequestTimed a)
  | ReqUILeader !ActorId !(Maybe Target) !RequestUI
  | ReqUIGameRestart !ActorId !GroupName !Int ![(Int, (Text, Text))]
  | ReqUIGameExit !ActorId !Int
  | ReqUIGameSave
  | ReqUITactic !Tactic
  | ReqUIAutomate
  | ReqUIPong [CmdAtomic]

deriving instance Show RequestUI

data RequestAnyAbility = forall a. RequestAnyAbility !(RequestTimed a)

deriving instance Show RequestAnyAbility

anyToUI :: RequestAnyAbility -> RequestUI
anyToUI (RequestAnyAbility cmd) = ReqUITimed cmd

-- | Client-server requests that take game time. Sent by both AI and UI clients.
data RequestTimed :: Ability -> * where
  ReqMove :: !Vector -> RequestTimed AbMove
  ReqMelee :: !ActorId -> !ItemId -> !CStore -> RequestTimed AbMelee
  ReqDisplace :: !ActorId -> RequestTimed AbDisplace
  ReqAlter :: !Point -> !(Maybe F.Feature) -> RequestTimed AbAlter
  ReqWait :: RequestTimed AbWait
  ReqMoveItem :: !ItemId -> !Int -> !CStore -> !CStore
              -> RequestTimed AbMoveItem
  ReqProject :: !Point -> !Int -> !ItemId -> !CStore -> RequestTimed AbProject
  ReqApply :: !ItemId -> !CStore -> RequestTimed AbApply
  ReqTrigger :: !(Maybe F.Feature) -> RequestTimed AbTrigger

deriving instance Show (RequestTimed a)

data ReqFailure =
    MoveNothing
  | MeleeSelf
  | MeleeDistant
  | DisplaceDistant
  | DisplaceAccess
  | DisplaceProjectiles
  | DisplaceDying
  | DisplaceBraced
  | DisplaceSupported
  | AlterDistant
  | AlterBlockActor
  | AlterBlockItem
  | AlterNothing
  | EqpOverfull
  | DurablePeriodicAbuse
  | ApplyBlind
  | ApplyOutOfReach
  | ItemNothing
  | ItemNotCalm
  | ProjectAimOnself
  | ProjectBlockTerrain
  | ProjectBlockActor
  | ProjectBlind
  | TriggerNothing
  | NoChangeDunLeader
  | NoChangeLvlLeader

showReqFailure :: ReqFailure -> Msg
showReqFailure reqFailure = case reqFailure of
  MoveNothing -> "wasting time on moving into obstacle"
  MeleeSelf -> "trying to melee oneself"
  MeleeDistant -> "trying to melee a distant foe"
  DisplaceDistant -> "trying to switch places with a distant actor"
  DisplaceAccess -> "switching places without access"
  DisplaceProjectiles -> "trying to switch places with multiple projectiles"
  DisplaceDying -> "trying to switch places with a dying foe"
  DisplaceBraced -> "trying to switch places with a braced foe"
  DisplaceSupported -> "trying to switch places with a supported foe"
  AlterDistant -> "trying to alter a distant tile"
  AlterBlockActor -> "blocked by an actor"
  AlterBlockItem -> "jammed by an item"
  AlterNothing -> "wasting time on altering nothing"
  EqpOverfull -> "cannot equip any more items"
  DurablePeriodicAbuse -> "cannot apply a durable periodic item"
  ApplyBlind -> "blind actors cannot read"
  ApplyOutOfReach -> "cannot apply an item out of reach"
  ItemNothing -> "wasting time on void item manipulation"
  ItemNotCalm -> "you are too alarmed to sort through the shared stash"
  ProjectAimOnself -> "cannot aim at oneself"
  ProjectBlockTerrain -> "aiming obstructed by terrain"
  ProjectBlockActor -> "aiming blocked by an actor"
  ProjectBlind -> "blind actors cannot aim"
  TriggerNothing -> "wasting time on triggering nothing"
  NoChangeDunLeader -> "no manual level change for your team"
  NoChangeLvlLeader -> "no manual leader change for your team"
