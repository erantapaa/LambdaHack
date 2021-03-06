-- | The type of cave layout kinds.
module Game.LambdaHack.Content.CaveKind
  ( CaveKind(..), validateSingleCaveKind, validateAllCaveKind
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import qualified Game.LambdaHack.Common.Dice as Dice
import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Point
import Game.LambdaHack.Common.Random

-- | Parameters for the generation of dungeon levels.
data CaveKind = CaveKind
  { csymbol         :: !Char         -- ^ a symbol
  , cname           :: !Text         -- ^ short description
  , cfreq           :: !Freqs        -- ^ frequency within groups
  , cxsize          :: !X            -- ^ X size of the whole cave
  , cysize          :: !Y            -- ^ Y size of the whole cave
  , cgrid           :: !Dice.DiceXY  -- ^ the dimensions of the grid of places
  , cminPlaceSize   :: !Dice.DiceXY  -- ^ minimal size of places
  , cmaxPlaceSize   :: !Dice.DiceXY  -- ^ maximal size of places
  , cdarkChance     :: !Dice.Dice    -- ^ the chance a place is dark
  , cnightChance    :: !Dice.Dice    -- ^ the chance the cave is dark
  , cauxConnects    :: !Rational     -- ^ a proportion of extra connections
  , cmaxVoid        :: !Rational     -- ^ at most this proportion of rooms void
  , cminStairDist   :: !Int          -- ^ minimal distance between stairs
  , cdoorChance     :: !Chance       -- ^ the chance of a door in an opening
  , copenChance     :: !Chance       -- ^ if there's a door, is it open?
  , chidden         :: !Int          -- ^ if not open, hidden one in n times
  , cactorCoeff     :: !Int          -- ^ the lower, the more monsters spawn
  , cactorFreq      :: !Freqs        -- ^ actor groups to consider
  , citemNum        :: !Dice.Dice    -- ^ the number of items in the cave
  , citemFreq       :: !Freqs        -- ^ item groups to consider
  , cplaceFreq      :: !Freqs        -- ^ place groups to consider
  , cpassable       :: !Bool         -- ^ are passable default tiles permitted
  , cdefTile        :: !GroupName    -- ^ the default cave tile
  , cdarkCorTile    :: !GroupName    -- ^ the dark cave corridor tile
  , clitCorTile     :: !GroupName    -- ^ the lit cave corridor tile
  , cfillerTile     :: !GroupName    -- ^ the filler wall
  , couterFenceTile :: !GroupName    -- ^ the outer fence wall
  , clegendDarkTile :: !GroupName    -- ^ the dark place plan legend
  , clegendLitTile  :: !GroupName    -- ^ the lit place plan legend
  }
  deriving Show  -- No Eq and Ord to make extending it logically sound

-- | Catch caves with not enough space for all the places. Check the size
-- of the cave descriptions to make sure they fit on screen. Etc.
validateSingleCaveKind :: CaveKind -> [Text]
validateSingleCaveKind CaveKind{..} =
  let (maxGridX, maxGridY) = Dice.maxDiceXY cgrid
      (minMinSizeX, minMinSizeY) = Dice.minDiceXY cminPlaceSize
      (maxMinSizeX, maxMinSizeY) = Dice.maxDiceXY cminPlaceSize
      (minMaxSizeX, minMaxSizeY) = Dice.minDiceXY cmaxPlaceSize
      -- If there is at most one room, we need extra borders for a passage,
      -- but if there may be more rooms, we have that space, anyway,
      -- because multiple rooms take more space than borders.
      xborder = if maxGridX == 1 || couterFenceTile /= "basic outer fence"
                then 2
                else 0
      yborder = if maxGridY == 1 || couterFenceTile /= "basic outer fence"
                then 2
                else 0
  in [ "cname longer than 25" | T.length cname > 25 ]
     ++ [ "cxsize < 7" | cxsize < 7 ]
     ++ [ "cysize < 7" | cysize < 7 ]
     ++ [ "minMinSizeX < 1" | minMinSizeX < 1 ]
     ++ [ "minMinSizeY < 1" | minMinSizeY < 1 ]
     ++ [ "minMaxSizeX < maxMinSizeX" | minMaxSizeX < maxMinSizeX ]
     ++ [ "minMaxSizeY < maxMinSizeY" | minMaxSizeY < maxMinSizeY ]
     ++ [ "cxsize too small"
        | maxGridX * (maxMinSizeX + 1) + xborder >= cxsize ]
     ++ [ "cysize too small"
        | maxGridY * (maxMinSizeY + 1) + yborder >= cysize ]

-- | Validate all cave kinds.
-- Note that names don't have to be unique: we can have several variants
-- of a cave with a given name.
validateAllCaveKind :: [CaveKind] -> [Text]
validateAllCaveKind lk =
  if any (\k -> maybe False (> 0) $ lookup "campaign random" $ cfreq k) lk
  then []
  else ["no cave defined for \"campaign random\""]
