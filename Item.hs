module Item where

import Data.Binary
import Data.Set as S
import Data.List as L
import Data.Maybe
import Control.Monad

import Display
import Geometry
import Random

data Item = Item
             { itype   :: ItemType,   
               iletter :: Maybe Char }  -- inventory identifier
  deriving Show

data ItemType =
   Ring
 | Scroll
 | Potion
 | Wand
 | Amulet
 | Gem
 | Gold
 deriving Show

instance Binary Item where
  put (Item itype iletter) = put itype >> put iletter
  get = liftM2 Item get get

instance Binary ItemType where
  put Ring   = putWord8 0
  put Scroll = putWord8 1
  put Potion = putWord8 2
  put Wand   = putWord8 3
  put Amulet = putWord8 4
  put Gem    = putWord8 5
  put Gold   = putWord8 6
  get = do
          tag <- getWord8
          case tag of
            0 -> return Ring
            1 -> return Scroll
            2 -> return Potion
            3 -> return Wand
            4 -> return Amulet
            5 -> return Gem
            6 -> return Gold

itemFrequency :: Frequency ItemType
itemFrequency =
  Frequency
  [
    (10, Gold),
    (3, Gem),
    (2, Ring),
    (4, Scroll),
    (2, Wand),
    (1, Amulet),
    (4, Potion)
  ]

-- | Generate an item.
newItem :: Frequency ItemType -> Rnd Item
newItem ftp =
  do
    tp <- frequency ftp
    return (Item tp Nothing)

-- | Assigns a letter to an item, for inclusion
-- in the inventory of the player. Takes a starting
-- letter.
assignLetter :: Char -> [Item] -> Maybe Char
assignLetter c is =
    listToMaybe (L.filter (\x -> not (x `member` current)) candidates)
  where
    current    = S.fromList (concatMap (maybeToList . iletter) is)
    allLetters = ['a'..'z'] ++ ['A'..'Z']
    candidates = take (length allLetters) (drop (fromJust (L.findIndex (==c) allLetters)) (cycle allLetters))

viewItem :: ItemType -> (Char, Attr -> Attr)
viewItem Ring   = ('=', id)
viewItem Scroll = ('?', id)
viewItem Potion = ('!', id)
viewItem Wand   = ('/', id)
viewItem Gold   = ('$', setFG yellow)
viewItem Gem    = ('*', setFG red)
viewItem _      = ('~', id)

objectItem :: ItemType -> String
objectItem Ring   = "a ring"
objectItem Scroll = "a scroll"
objectItem Potion = "a potion"
objectItem Wand   = "a wand"
objectItem Amulet = "an amulet"
objectItem Gem    = "a gem"
objectItem Gold   = "some gold"
