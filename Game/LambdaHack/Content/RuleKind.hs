-- | The type of game rule sets and assorted game data.
module Game.LambdaHack.Content.RuleKind
  ( RuleKind(..), validateRuleKind
  ) where

import Data.Text (Text)
import Data.Version

import Game.LambdaHack.Common.Misc
import Game.LambdaHack.Common.Point

-- TODO: very few rules are configurable yet, extend as needed.
-- TODO: in the future, in @raccessible@ check flying for chasms,
-- swimming for water, etc.
-- TODO: tweak other code to allow games with only cardinal direction moves

-- | The type of game rule sets and assorted game data.
--
-- For now the rules are immutable througout the game, so there is
-- no type @Rule@ to hold any changing parameters, just @RuleKind@
-- for the fixed set.
-- However, in the future, if the rules can get changed during gameplay
-- based on data mining of player behaviour, we may add such a type
-- and then @RuleKind@ will become just a starting template, analogously
-- as for the other content.
--
-- The @raccessible@ field hold extra conditions that have to be met
-- for a tile to be accessible, on top of being an open tile
-- (or openable, in some contexts). The @raccessibleDoor@ field
-- contains yet additional conditions concerning tiles that are doors,
-- whether open or closed.
-- Precondition: the two positions are next to each other.
-- We assume the predicate is symmetric.
data RuleKind = RuleKind
  { rsymbol          :: !Char     -- ^ a symbol
  , rname            :: !Text     -- ^ short description
  , rfreq            :: !Freqs    -- ^ frequency within groups
  , raccessible      :: Maybe (Point -> Point -> Bool)
  , raccessibleDoor  :: Maybe (Point -> Point -> Bool)
  , rtitle           :: !Text     -- ^ the title of the game
  , rpathsDataFile   :: FilePath -> IO FilePath  -- ^ the path to data files
  , rpathsVersion    :: !Version  -- ^ the version of the game
  , ritemMelee       :: ![Char]   -- ^ symbols of melee weapons
  , ritemRanged      :: ![Char]   -- ^ symbols of ranged weapons and missiles
  , ritemProject     :: ![Char]   -- ^ symbols of items AI can project
  , rcfgRulesDefault :: !String   -- ^ the default game rules config file
  , rcfgUIDefault    :: !String   -- ^ the default UI settings config file
  , rmainMenuArt     :: !Text     -- ^ the ASCII art for the Main Menu
  }

-- | A dummy instance of the 'Show' class, to satisfy general requirments
-- about content. We won't have many rule sets and they contain functions,
-- so defining a proper instance is not practical.
instance Show RuleKind where
  show _ = "The game ruleset specification."

-- | Validates the ASCII art format (TODO).
validateRuleKind :: [RuleKind] -> [RuleKind]
validateRuleKind _ = []
