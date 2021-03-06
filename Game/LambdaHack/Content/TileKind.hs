-- | The type of kinds of terrain tiles.
module Game.LambdaHack.Content.TileKind
  ( TileKind(..), validateSingleTileKind, validateAllTileKind, actionFeatures
  ) where

import Control.Exception.Assert.Sugar
import Data.Hashable (hash)
import qualified Data.IntSet as IS
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Text (Text)

import Game.LambdaHack.Common.Color
import qualified Game.LambdaHack.Common.Feature as F
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Msg

-- | The type of kinds of terrain tiles. See @Tile.hs@ for explanation
-- of the absence of a corresponding type @Tile@ that would hold
-- particular concrete tiles in the dungeon.
data TileKind = TileKind
  { tsymbol  :: !Char         -- ^ map symbol
  , tname    :: !Text         -- ^ short description
  , tfreq    :: !Freqs        -- ^ frequency within groups
  , tcolor   :: !Color        -- ^ map color
  , tcolor2  :: !Color        -- ^ map color when not in FOV
  , tfeature :: ![F.Feature]  -- ^ properties
  }
  deriving Show  -- No Eq and Ord to make extending it logically sound

-- TODO: (spans multiple contents) check that all posible solid place
-- fences have hidden counterparts.
-- | Validate a single tile kind.
validateSingleTileKind :: TileKind -> [Text]
validateSingleTileKind TileKind{..} =
  [ "suspect tile is walkable" | F.Walkable `elem` tfeature
                                 && F.Suspect `elem` tfeature ]

-- TODO: verify that OpenTo, CloseTo and ChangeTo are assigned as specified.
-- | Validate all tile kinds.
--
-- If tiles look the same on the map, the description and the substantial
-- features should be the same, too. Otherwise, the player has to inspect
-- manually all the tiles of that kind, or even experiment with them,
-- to see if any is special. This would be tedious. Note that iiles may freely
-- differ wrt dungeon generation, AI preferences, etc.
validateAllTileKind :: [TileKind] -> [Text]
validateAllTileKind lt =
  let listVis f = map (\kt -> ( ( tsymbol kt
                                  , F.Suspect `elem` tfeature kt
                                  , f kt
                                  )
                                , [kt] ) ) lt
      mapVis :: (TileKind -> Color) -> M.Map (Char, Bool, Color) [TileKind]
      mapVis f = M.fromListWith (++) $ listVis f
      namesUnequal [] = assert `failure` "no TileKind content" `twith` lt
      namesUnequal (hd : tl) =
        -- Catch if at least one is different.
        any (/= tname hd) (map tname tl)
        -- TODO: calculate actionFeatures only once for each tile kind
        || any (/= actionFeatures True hd) (map (actionFeatures True) tl)
      confusions f = filter namesUnequal $ M.elems $ mapVis f
  in case confusions tcolor ++ confusions tcolor2 of
    [] -> []
    cfs -> ["tile confusions detected:" <+> tshow cfs]

-- | Features of tiles that differentiate them substantially from one another.
-- By tile content validation condition, this means the player
-- can tell such tile apart, and only looking at the map, not tile name.
-- So if running uses this function, it won't stop at places that the player
-- can't himself tell from other places, and so running does not confer
-- any advantages, except UI convenience. Hashes are accurate enough
-- for our purpose, given that we use arbitrary heuristics anyway.
actionFeatures :: Bool -> TileKind -> IS.IntSet
actionFeatures markSuspect t =
  let f feat = case feat of
        F.Cause{} -> Just feat
        F.OpenTo{} -> Just $ F.OpenTo ""  -- if needed, remove prefix/suffix
        F.CloseTo{} -> Just $ F.CloseTo ""
        F.ChangeTo{} -> Just $ F.ChangeTo ""
        F.Walkable -> Just feat
        F.Clear -> Just feat
        F.Suspect -> if markSuspect then Just feat else Nothing
        F.Aura{} -> Just feat
        F.Impenetrable -> Just feat
        F.Trail -> Just feat  -- doesn't affect tile behaviour, but important
        F.HideAs{} -> Nothing
        F.RevealAs{} -> Nothing
        F.Dark -> Nothing  -- not important any longer, after FOV computed
        F.OftenItem -> Nothing
        F.OftenActor -> Nothing
        F.NoItem -> Nothing
        F.NoActor -> Nothing
  in IS.fromList $ map hash $ mapMaybe f $ tfeature t
